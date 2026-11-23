import AppKit
import CoreFoundation
import QuartzCore

private let home = FileManager.default.homeDirectoryForCurrentUser
private let environment = ProcessInfo.processInfo.environment
private let installRoot = environment["MAC_RICING_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? home.appending(path: ".local/share/mac-ricing/current")
private let rift = environment["MAC_RICING_RIFT_CLI"].map { URL(fileURLWithPath: $0) }
    ?? ["/opt/homebrew/bin/rift-cli", "/usr/local/bin/rift-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    ?? installRoot.appending(path: "bin/rift-cli")
private let request = installRoot.appending(path: "bin/workspace-request")
private let metrics = installRoot.appending(path: "bin/metrics.sh")
private let eventPrefix = "io.github.macricing.neon-workspace-bar"
private let playbackPreference = "PlaybackSpectrumEnabled"

private struct Workspace: Decodable {
    struct Window: Decodable {
        struct Bounds: Decodable {
            struct Origin: Decodable { let x: CGFloat; let y: CGFloat }
            struct Size: Decodable { let width: CGFloat; let height: CGFloat }
            let origin: Origin
            let size: Size

            var rect: CGRect {
                CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
            }
        }

        let isFocused: Bool
        let isFloating: Bool?
        let bundleId: String?
        let appName: String?
        let windowServerId: UInt32?
        let frame: Bounds?
    }

    let index: Int
    let isActive: Bool
    let isFocused: Bool
    let windowCount: Int
    let displayUuid: String?
    let windows: [Window]
}

private struct LayoutSnapshot: Decodable {
    struct Node: Decodable {
        let nodeType: String
        let frame: Workspace.Window.Bounds
        let isFullscreen: Bool
        let children: [Node]

        private var hasVisibleWindow: Bool {
            (nodeType == "window" && !frame.rect.isEmpty) || children.contains { $0.hasVisibleWindow }
        }

        var hasFullscreen: Bool {
            (isFullscreen && hasVisibleWindow) || children.contains { $0.hasFullscreen }
        }
    }

    let workspaceId: Int
    let isActiveWorkspace: Bool
    let containerTree: Node
}

private func output(_ executable: URL, _ arguments: [String]) -> Data? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment.merging(["RIFT_BS_NAME": "io.github.macricing.rift.ipc"]) { configured, _ in configured }
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

private func workspaceSnapshot() -> [Workspace]? {
    guard let data = output(rift, ["query", "workspaces"]) else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode([Workspace].self, from: data)
}

private func layoutSnapshots(for displays: [String]) -> [String: LayoutSnapshot] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    var result: [String: LayoutSnapshot] = [:]
    for display in displays {
        if let data = output(rift, ["query", "layout", "--display", display]),
           let layout = try? decoder.decode(LayoutSnapshot.self, from: data), layout.isActiveWorkspace {
            result[display] = layout
        }
    }
    return result
}

private func resizeMode() -> Bool? {
    guard let data = output(rift, ["query", "binding-mode"]),
          let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
        return nil
    }
    let dictionary = parsed as? [String: String]
    let mode = parsed as? String ?? dictionary?["mode"] ?? dictionary?["binding_mode"]
    return mode.map { $0 == "resize" }
}

private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(ignoresClicks: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        ignoresMouseEvents = ignoresClicks
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        appearance = NSAppearance(named: .darkAqua)
    }
}

private final class DisplayBar {
    let foreground = BarPanel(ignoresClicks: false)
    let background = BarPanel(ignoresClicks: true)
    let framePanel = BarPanel(ignoresClicks: true)
    let content = BarContent(frame: .zero)
    private let workspaceFrame = WorkspaceFrame(frame: .zero)
    private var displayBounds = CGRect.zero
    private var tiles: [NativeWindowCorners.Tile] = []
    private var isFullscreen = false

    init() {
        foreground.title = "Neon Workspace Bar Controls"
        foreground.contentView = content
        background.title = "Neon Workspace Bar Footer"
        background.setAccessibilityElement(false)
        background.contentView = GlassSurface(frame: .zero)
        framePanel.title = "Neon Workspace Frame"
        framePanel.setAccessibilityElement(false)
        framePanel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        framePanel.contentView = workspaceFrame
    }

    func place(on screen: NSScreen, displayID: CGDirectDisplayID) {
        let frame = screen.frame
        displayBounds = CGDisplayBounds(displayID)
        let footer = NSRect(x: frame.minX, y: frame.minY, width: frame.width,
                            height: WorkspaceChrome.footerHeight)
        framePanel.setFrame(frame, display: true)
        background.setFrame(footer, display: true)
        foreground.setFrame(footer, display: true)
        if !isFullscreen { showChrome() }
        updateCorners()
    }

    func updatePresentation(windows: [Workspace.Window], tiledFullscreen: Bool) {
        let floatingFullscreen = windows.contains { window in
            guard window.isFloating == true, window.isFocused, let frame = window.frame?.rect else { return false }
            return frame.insetBy(dx: -1, dy: -1).contains(displayBounds)
        }
        let fullscreen = tiledFullscreen || floatingFullscreen
        if isFullscreen != fullscreen {
            isFullscreen = fullscreen
            if fullscreen {
                foreground.orderOut(nil)
                background.orderOut(nil)
                framePanel.orderOut(nil)
            } else {
                showChrome()
            }
        }
        tiles = windows.compactMap { window in
            guard window.isFloating != true, let id = window.windowServerId,
                  let frame = window.frame?.rect else { return nil }
            return NativeWindowCorners.Tile(id: id, frame: frame)
        }
        updateCorners()
    }

    func updateCorners() {
        guard !isFullscreen else { return }
        workspaceFrame.cornerRadii = NativeWindowCorners.opening(for: tiles, display: displayBounds)
    }

    private func showChrome() {
        framePanel.orderFrontRegardless()
        background.orderFrontRegardless()
        foreground.order(.above, relativeTo: background.windowNumber)
    }

    func close() {
        foreground.close()
        background.close()
        framePanel.close()
    }
}

private final class NeonWorkspaceBar: NSObject, NSApplicationDelegate {
    private let workspaceQueue = DispatchQueue(label: "neon-workspace-state", qos: .userInteractive)
    private let metricsQueue = DispatchQueue(label: "neon-workspace-metrics", qos: .utility)
    private let playback = PlaybackSpectrum()
    private var displays: [String: DisplayBar] = [:]
    private var timer: Timer?
    private var cornerTimer: Timer?
    private var snapshot: [Workspace] = []
    private var layouts: [String: LayoutSnapshot] = [:]
    private var icons: [String: NSImage] = [:]
    private var fetching = false
    private var refreshRequested = false
    private var modeRequested = false
    private var layoutRequested = false
    private var resizing = false
    private var playbackEnabled = false
    private var fetchingMetrics = false
    private var status = ""
    private let clock = DateFormatter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        clock.locale = .autoupdatingCurrent
        clock.dateFormat = "EEE d MMM  HH:mm"
        let notifications = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for suffix in ["refresh", "mode", "layout"] {
            CFNotificationCenterAddObserver(notifications, observer, { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let bar = Unmanaged<NeonWorkspaceBar>.fromOpaque(observer).takeUnretainedValue()
                let event = name.rawValue as String
                DispatchQueue.main.async {
                    bar.refresh(includeMode: event.hasSuffix(".mode"), includeLayout: event.hasSuffix(".layout"))
                }
            }, "\(eventPrefix).\(suffix)" as CFString, nil, .deliverImmediately)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(spaceChanged),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(woke),
                              name: NSWorkspace.didWakeNotification, object: nil)

        playback.onLevels = { [weak self] levels in
            guard let self, self.playbackEnabled else { return }
            for bar in self.displays.values { bar.content.updateSpectrum(levels) }
        }
        playback.onFailure = { [weak self] message in
            NSLog("Playback visualization: %@", message)
            self?.setPlaybackEnabled(false)
        }
        screensChanged()
        refresh(includeMode: true, includeLayout: true)
        sampleMetrics()
        if UserDefaults.standard.bool(forKey: playbackPreference) {
            setPlaybackEnabled(true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.sampleMetrics()
            // Reconcile after Rift's login/restart if its first event arrived early.
            self?.refresh(includeMode: true, includeLayout: true)
        }
        cornerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for bar in self.displays.values { bar.updateCorners() }
        }
        cornerTimer?.tolerance = 0.2
    }

    func applicationWillTerminate(_ notification: Notification) {
        playback.stop()
        timer?.invalidate()
        cornerTimer?.invalidate()
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    @objc private func screensChanged() {
        var available: Set<String> = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let id = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let uuid = CFUUIDCreateString(nil, id) as String? else { continue }
            available.insert(uuid)
            let bar = displays[uuid] ?? DisplayBar()
            bar.content.onSelect = { index in
                let process = Process()
                process.executableURL = request
                process.arguments = [String(index)]
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
            bar.content.audioEnabled = playbackEnabled
            bar.content.onActivateAudio = { [weak self] in
                guard let self else { return }
                self.setPlaybackEnabled(!self.playbackEnabled)
            }
            bar.place(on: screen, displayID: number.uint32Value)
            displays[uuid] = bar
        }
        for id in Set(displays.keys).subtracting(available) {
            displays.removeValue(forKey: id)?.close()
        }
        render()
        renderStatus()
    }

    @objc private func spaceChanged() { refresh(includeLayout: true) }

    @objc private func woke() {
        screensChanged()
        refresh(includeMode: true, includeLayout: true)
        sampleMetrics()
    }

    private func refresh(includeMode: Bool = false, includeLayout: Bool = false) {
        refreshRequested = true
        modeRequested = modeRequested || includeMode
        layoutRequested = layoutRequested || includeLayout
        guard !fetching else { return }
        let readMode = modeRequested
        let readLayout = layoutRequested
        let displayIDs = Array(displays.keys)
        refreshRequested = false
        modeRequested = false
        layoutRequested = false
        fetching = true
        workspaceQueue.async { [weak self] in
            let data = workspaceSnapshot()
            let layouts = readLayout ? layoutSnapshots(for: displayIDs) : nil
            let mode = readMode ? resizeMode() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if let data { self.snapshot = data }
                if let layouts { self.layouts = layouts }
                if let mode { self.resizing = mode }
                self.render()
                if self.refreshRequested { self.refresh() }
            }
        }
    }

    private func appIcon(for bundle: String, name: String?) -> NSImage? {
        if let cached = icons[bundle] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.accessibilityDescription = name
        icons[bundle] = icon
        return icon
    }

    private func render() {
        let occupied = Set(snapshot.filter { $0.windowCount > 0 }.map(\.index))
        for (uuid, bar) in displays {
            let local = snapshot.filter { $0.displayUuid?.caseInsensitiveCompare(uuid) == .orderedSame }
            let candidates = displays.count == 1 ? snapshot : local
            let selected = candidates.first { $0.isFocused } ?? candidates.first { $0.isActive }
            let windows = selected?.windows ?? []
            let ordered = windows.filter(\.isFocused) + windows.filter { !$0.isFocused }
            var shown: Set<String> = []
            let appIcons = ordered.compactMap { window -> NSImage? in
                guard let bundle = window.bundleId, shown.insert(bundle).inserted else { return nil }
                return appIcon(for: bundle, name: window.appName)
            }
            bar.content.update(active: selected?.index, occupied: occupied, appIcons: appIcons,
                               resize: resizing && selected?.isFocused == true)
            let layout = layouts[uuid]
            bar.updatePresentation(windows: windows, tiledFullscreen:
                selected?.index == layout?.workspaceId && layout?.containerTree.hasFullscreen == true)
        }
    }

    private func setPlaybackEnabled(_ enabled: Bool) {
        playbackEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: playbackPreference)
        for bar in displays.values {
            bar.content.audioEnabled = enabled
            if !enabled { bar.content.updateSpectrum([]) }
        }
        if enabled {
            playback.start()
        } else {
            playback.stop()
        }
    }

    private func sampleMetrics() {
        renderStatus()
        guard !fetchingMetrics else { return }
        fetchingMetrics = true
        metricsQueue.async { [weak self] in
            let text = output(metrics, []).flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingMetrics = false
                if let text { self.status = text }
                self.renderStatus()
            }
        }
    }

    private func renderStatus() {
        let timestamp = clock.string(from: Date())
        for bar in displays.values {
            bar.content.updateStatus(metrics: status, clock: timestamp)
        }
    }
}

let app = NSApplication.shared
private let delegate = NeonWorkspaceBar()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
