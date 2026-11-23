import Accelerate
import CoreAudio
import Foundation
import Synchronization

/// Call start and stop on the main thread. Only smoothed band levels reach the view.
final class PlaybackSpectrum {
    var onLevels: (([Float]) -> Void)?
    var onFailure: ((String) -> Void)?

    private let deviceQueue = DispatchQueue(label: "neon-playback-tap", qos: .userInitiated)
    private let capture = PlaybackCapture()
    private var generation = 0
    private var requested = false
    private var timer: Timer?
    private var analysis: PlaybackBands?
    private var levels = [Float](repeating: 0, count: PlaybackBands.bandCount)
    private var lastInput: TimeInterval = 0

    func start() {
        guard !requested else { return }
        requested = true
        generation += 1
        let attempt = generation
        deviceQueue.async { [weak self, capture] in
            let result = Result { try capture.start() }
            DispatchQueue.main.async {
                guard let self, self.requested, self.generation == attempt else { return }
                switch result {
                case let .success(stream):
                    guard let analysis = PlaybackBands(sampleRate: stream.sampleRate) else {
                        self.stop()
                        self.onFailure?("The spectrum analyzer could not start.")
                        return
                    }
                    self.analysis = analysis
                    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                        self?.read(stream.mailbox)
                    }
                    timer.tolerance = 0.003
                    self.timer = timer
                    RunLoop.main.add(timer, forMode: .common)
                case let .failure(error):
                    self.requested = false
                    self.onFailure?(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        generation += 1
        requested = false
        timer?.invalidate()
        timer = nil
        analysis = nil
        lastInput = 0
        levels = [Float](repeating: 0, count: PlaybackBands.bandCount)
        deviceQueue.async { [capture] in capture.stop() }
        onLevels?([])
    }

    deinit {
        timer?.invalidate()
        deviceQueue.async { [capture] in capture.stop() }
    }

    private func read(_ mailbox: SampleMailbox) {
        guard let analysis else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let incoming = analysis.receive(from: mailbox)
        if incoming != nil { lastInput = time }
        guard incoming != nil || time - lastInput > 0.10 else { return }

        var changed = false
        for index in levels.indices {
            let target = incoming?[index] ?? 0
            let previous = levels[index]
            let smoothed = previous + (target - previous) * (target > previous ? 0.77 : 0.30)
            levels[index] = smoothed < 0.008 ? 0 : smoothed
            changed = changed || abs(levels[index] - previous) >= 0.002
        }
        if changed { onLevels?(levels) }
    }
}

private final class PlaybackCapture: @unchecked Sendable {
    private var tap: ProcessTap?

    // All calls are serialized on the device queue.
    func start() throws -> (mailbox: SampleMailbox, sampleRate: Double) {
        let newTap = try ProcessTap()
        tap = newTap
        return (newTap.mailbox, newTap.sampleRate)
    }

    func stop() { tap = nil }
}

private struct AudioSetupError: LocalizedError {
    let stage: String
    let status: OSStatus

    var errorDescription: String? {
        let message = "Could not start the playback meter (\(stage), \(status))."
        if stage == "start playback input" {
            return message + " Check Screen & System Audio Recording in System Settings → Privacy & Security."
        }
        return message
    }
}

private func checkAudio(_ status: OSStatus, _ stage: String) throws {
    guard status == noErr else { throw AudioSetupError(stage: stage, status: status) }
}

private final class ProcessTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    let mailbox = SampleMailbox()
    private(set) var sampleRate: Double = 0

    init() throws {
        do {
            try open()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func open() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Neon Workspace Bar Playback"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try checkAudio(AudioHardwareCreateProcessTap(description, &tap), "create tap")

        var address = property(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        try checkAudio(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "tap format")
        guard format.mSampleRate.isFinite, format.mSampleRate >= 8_000,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 32,
              format.mBytesPerFrame == MemoryLayout<Float>.stride else {
            throw AudioSetupError(stage: "unsupported tap format", status: kAudioDeviceUnsupportedFormatError)
        }
        sampleRate = format.mSampleRate

        address = property(kAudioTapPropertyUID)
        var retainedUID: Unmanaged<CFString>?
        size = UInt32(MemoryLayout.size(ofValue: retainedUID))
        try checkAudio(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &retainedUID), "tap identifier")
        guard let uid = retainedUID?.takeRetainedValue() else {
            throw AudioSetupError(stage: "missing tap identifier", status: kAudioHardwareBadObjectError)
        }
        // This aggregate contains only the playback tap. It has no physical input or output device.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Neon Workspace Bar Playback",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]
            ]
        ]
        try checkAudio(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "create aggregate")
        try waitForDevice()

        let context = Unmanaged.passUnretained(mailbox).toOpaque()
        try checkAudio(AudioDeviceCreateIOProcID(aggregate, { _, _, input, _, _, _, context in
            if let context {
                Unmanaged<SampleMailbox>.fromOpaque(context).takeUnretainedValue().append(input)
            }
            return noErr
        }, context, &ioProc), "prepare playback input")
        guard let ioProc else {
            throw AudioSetupError(stage: "missing playback input", status: kAudioHardwareBadObjectError)
        }
        try checkAudio(AudioDeviceStart(aggregate, ioProc), "start playback input")
        running = true
    }

    private func waitForDevice() throws {
        var address = property(kAudioDevicePropertyDeviceIsAlive)
        for _ in 0..<60 {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: alive))
            let result = AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &alive)
            if result == noErr, alive != 0 { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw AudioSetupError(stage: "playback device unavailable", status: kAudioHardwareNotReadyError)
    }

    private func close() {
        if let ioProc {
            if running { AudioDeviceStop(aggregate, ioProc) }
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
            self.ioProc = nil
            running = false
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = kAudioObjectUnknown
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = kAudioObjectUnknown
        }
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

/// Bounded handoff from the HAL to the analyzer. The real-time callback neither locks nor allocates.
private final class SampleMailbox: @unchecked Sendable {
    private enum Slot: UInt8 {
        case empty, writing, ready, reading
    }

    private let slot = Atomic<UInt8>(Slot.empty.rawValue)
    private let next = UnsafeMutablePointer<Float>.allocate(capacity: PlaybackBands.frameCount)
    private let current = UnsafeMutablePointer<Float>.allocate(capacity: PlaybackBands.frameCount)
    private var filled = 0

    init() {
        next.initialize(repeating: 0, count: PlaybackBands.frameCount)
        current.initialize(repeating: 0, count: PlaybackBands.frameCount)
    }

    deinit {
        next.deallocate()
        current.deallocate()
    }

    func append(_ input: UnsafePointer<AudioBufferList>) {
        guard input.pointee.mNumberBuffers == 1 else { return }
        let buffer = input.pointee.mBuffers
        guard buffer.mNumberChannels == 1, let data = buffer.mData else { return }
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
        let samples = data.assumingMemoryBound(to: Float.self)

        var offset = 0
        while offset < frames {
            let copied = min(frames - offset, PlaybackBands.frameCount - filled)
            next.advanced(by: filled).update(from: samples.advanced(by: offset), count: copied)
            offset += copied
            filled += copied
            if filled == PlaybackBands.frameCount {
                publish()
                filled = 0
            }
        }
    }

    private func publish() {
        let previous = slot.load(ordering: .relaxed)
        guard previous == Slot.empty.rawValue || previous == Slot.ready.rawValue,
              slot.compareExchange(expected: previous, desired: Slot.writing.rawValue,
                                   ordering: .acquiring).exchanged else { return }
        current.update(from: next, count: PlaybackBands.frameCount)
        slot.store(Slot.ready.rawValue, ordering: .releasing)
    }

    func read(into samples: inout [Float]) -> Bool {
        guard samples.count == PlaybackBands.frameCount,
              slot.compareExchange(expected: Slot.ready.rawValue, desired: Slot.reading.rawValue,
                                   ordering: .acquiring).exchanged else { return false }
        samples.withUnsafeMutableBufferPointer {
            $0.baseAddress?.update(from: current, count: PlaybackBands.frameCount)
        }
        slot.store(Slot.empty.rawValue, ordering: .releasing)
        return true
    }
}

/// Hann-windowed FFT with logarithmically spaced frequency ranges.
final class PlaybackBands {
    static let frameCount = 2048
    private static let edges: [Double] = [42, 85, 130, 200, 305, 465, 710, 1_085, 1_660, 2_540, 3_900, 6_000, 9_250, 19_000]
    static let bandCount = edges.count - 1
    private let log2Size: vDSP_Length = 11
    private let setup: FFTSetup
    private let window: [Float]
    private let bins: [Range<Int>]
    private var samples = [Float](repeating: 0, count: frameCount)
    private var real = [Float](repeating: 0, count: frameCount)
    private var imaginary = [Float](repeating: 0, count: frameCount)

    init?(sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0,
              let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        let count = Self.frameCount
        window = (0..<count).map { 0.5 - 0.5 * cos(Float.pi * 2 * Float($0) / Float(count)) }
        let step = sampleRate / Double(count)
        let edges = Self.edges.map { max(1, min(count / 2, Int(ceil($0 / step)))) }
        bins = zip(edges, edges.dropFirst()).map { $0..<$1 }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    fileprivate func receive(from mailbox: SampleMailbox) -> [Float]? {
        guard mailbox.read(into: &samples) else { return nil }
        return analyze(samples)
    }

    func analyze(_ samples: [Float]) -> [Float] {
        guard samples.count == Self.frameCount else { return [] }
        let count = vDSP_Length(Self.frameCount)
        vDSP_vmul(samples, 1, window, 1, &real, 1, count)
        vDSP_vclr(&imaginary, 1, count)
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var signal = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zip(setup, &signal, 1, log2Size, FFTDirection(kFFTDirection_Forward))
            }
        }
        let normalization = 4 / Float(count)
        return bins.map { range in
            var highest: Float = 0
            for bin in range {
                highest = max(highest, real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            }
            let amplitude = sqrt(highest) * normalization
            guard amplitude.isFinite, amplitude > 0.0005 else { return 0 }
            return min(1, max(0, (20 * log10(amplitude) + 63) / 54))
        }
    }
}
