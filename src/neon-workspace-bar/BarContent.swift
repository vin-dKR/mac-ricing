import AppKit
import QuartzCore

final class BarContent: NSView {
    var onSelect: ((Int) -> Void)?
    var onActivateAudio: (() -> Void)?
    var audioEnabled = false {
        didSet {
            spectrum.setEnabled(audioEnabled)
            let title = audioEnabled ? "Disable playback visualizer" : "Enable playback visualizer"
            audioButton.setAccessibilityLabel(title)
            audioButton.setAccessibilityValue(audioEnabled ? "On" : "Off")
            audioButton.toolTip = audioEnabled ? "Stop the playback visualizer" : "Allow system audio for the visualizer"
        }
    }

    private let centerY: CGFloat = 16
    private let edgePadding: CGFloat = 16
    private let slotWidth: CGFloat = 23
    private let logoWidth: CGFloat = 13
    private let logoGap: CGFloat = 12
    private let separatorWidth: CGFloat = 19
    private let iconWidth: CGFloat = 16
    private let iconStep: CGFloat = 21
    private let spectrumWidth: CGFloat = 58
    private let spectrumGap: CGFloat = 13
    private let statusGap: CGFloat = 16
    private let statusDividerGap: CGFloat = 13
    private let resizeWidth: CGFloat = 44
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let populated = NSColor(srgbRed: 0.84, green: 0.80, blue: 0.92, alpha: 1)
    private let selected = NSColor(srgbRed: 0.99, green: 0.96, blue: 1, alpha: 1)

    private var buttons: [NSButton] = []
    private var pills: [WorkspaceGlow] = []
    private var visibleSlots: [Int] = []
    private var currentSlot: Int?
    private var hasShownState = false
    private var appViews: [NSImageView] = []
    private let logo = NSTextField(labelWithString: "")
    private let resizeLabel = NSTextField(labelWithString: "Resize")
    private let divider = NSView()
    private let spectrum = PlaybackSpectrumView(frame: .zero)
    private let audioButton = NSButton()
    private let metricsLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private let statusDivider = NSView()
    private let clockDivider = NSView()
    private var metricsWidth: CGFloat = 0
    private var clockWidth: CGFloat = 0
    private var resizing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for index in 0..<10 {
            let glow = WorkspaceGlow()
            glow.isHidden = true
            pills.append(glow)
            addSubview(glow)

            let title = String(index + 1)
            let button = NSButton(title: title, target: self, action: #selector(selectWorkspace(_:)))
            button.tag = index
            button.setButtonType(.momentaryChange)
            button.isBordered = false
            button.focusRingType = .none
            button.font = numberFont
            button.alignment = .center
            button.isHidden = true
            button.setAccessibilityLabel("Workspace \(title)")
            button.setAccessibilityHelp("Switch to workspace \(title)")
            setLabel(button, color: populated)
            buttons.append(button)
            addSubview(button)
        }

        logo.font = .systemFont(ofSize: 14, weight: .medium)
        logo.textColor = populated
        logo.alignment = .center
        logo.setAccessibilityElement(false)
        addSubview(logo)

        resizeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        resizeLabel.textColor = populated
        resizeLabel.alignment = .center
        resizeLabel.isHidden = true
        addSubview(resizeLabel)

        for rule in [divider, statusDivider, clockDivider] {
            rule.wantsLayer = true
            rule.layer?.backgroundColor = NSColor(srgbRed: 0.76, green: 0.67, blue: 0.90, alpha: 0.30).cgColor
            rule.isHidden = true
            addSubview(rule)
        }

        audioButton.setButtonType(.momentaryChange)
        audioButton.title = ""

        audioButton.isBordered = false
        audioButton.focusRingType = .none
        audioButton.target = self
        audioButton.action = #selector(activateAudio)
        audioButton.setAccessibilityLabel("Enable playback visualizer")
        audioButton.setAccessibilityValue("Off")
        audioButton.toolTip = "Allow system audio for the visualizer"
        addSubview(audioButton)

        spectrum.setAccessibilityElement(false)
        addSubview(spectrum)
        configureStatus(metricsLabel, fontSize: 10.5, color: populated.withAlphaComponent(0.88))
        configureStatus(clockLabel, fontSize: 11, color: populated)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) as? NSButton
    }

    func update(active: Int?, occupied: Set<Int>, appIcons: [NSImage], resize: Bool) {
        let validActive = active.flatMap { buttons.indices.contains($0) ? $0 : nil }
        var slots = occupied.filter { buttons.indices.contains($0) }
        if let validActive { slots.insert(validActive) }
        let visible = slots.sorted()
        if !hasShownState || currentSlot != validActive || visibleSlots != visible {
            let animate = hasShownState && window?.isVisible == true
            for (index, button) in buttons.enumerated() {
                let isActive = validActive == index
                let hidden = !slots.contains(index)
                button.isHidden = hidden
                pills[index].isHidden = hidden
                setLabel(button, color: isActive ? selected : populated)
                button.setAccessibilityValue(isActive ? "Selected" : "Occupied")
                pills[index].setActive(isActive, animated: animate && !hidden)
            }
            visibleSlots = visible
            currentSlot = validActive
            hasShownState = true
            needsLayout = true
        }
        setIcons(validActive == nil ? [] : appIcons)
        if resizing != resize {
            resizing = resize
            needsLayout = true
        }
    }

    func updateSpectrum(_ levels: [Float]) {
        spectrum.update(levels)
    }

    func updateStatus(metrics: String, clock: String) {
        guard metricsLabel.stringValue != metrics || clockLabel.stringValue != clock else { return }
        metricsLabel.stringValue = metrics
        clockLabel.stringValue = clock
        metricsWidth = measuredWidth(metricsLabel)
        clockWidth = measuredWidth(clockLabel)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = min(edgePadding, max(8, bounds.width * 0.14))
        let workspaces = CGFloat(visibleSlots.count)
        let fixedWidth = 2 * inset + logoWidth + logoGap + spectrumGap + spectrumWidth
        let iconSpace = appViews.isEmpty ? 0 : separatorWidth + CGFloat(appViews.count) * iconStep
        let reserveForClock = max(0, bounds.width - fixedWidth - workspaces * 18)
        let visibleClock = statusWidth(metrics: 0, clock: clockWidth) <= reserveForClock ? clockWidth : 0
        let reserveForMetrics = max(0, bounds.width - fixedWidth - workspaces * slotWidth - iconSpace)
        let visibleMetrics = statusWidth(metrics: metricsWidth, clock: visibleClock) <= reserveForMetrics
            ? metricsWidth : 0
        let rightStatus = statusWidth(metrics: visibleMetrics, clock: visibleClock)
        let resizeFits = resizing && bounds.width >= fixedWidth + workspaces * 18 + rightStatus + resizeWidth
        let available = max(0, bounds.width - fixedWidth - rightStatus - (resizeFits ? resizeWidth : 0))
        let spacing = workspaces > 0 ? min(slotWidth, available / workspaces) : slotWidth
        let roomForIcons = max(0, available - workspaces * spacing - separatorWidth)
        let iconCount = min(appViews.count, Int(roomForIcons / iconStep))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        logo.frame = NSRect(x: inset, y: centerY - 9, width: logoWidth, height: 18)
        var x = inset + logoWidth + logoGap
        for index in visibleSlots {
            buttons[index].frame = NSRect(x: x, y: centerY - 12, width: spacing, height: 24)
            pills[index].frame = NSRect(x: x + 1.5, y: centerY - 10, width: max(0, spacing - 3), height: 20)
            x += spacing
        }

        divider.isHidden = iconCount == 0
        if iconCount > 0 {
            divider.frame = NSRect(x: x + 6, y: centerY - 5, width: 1, height: 10)
            x += separatorWidth
        }
        for (index, view) in appViews.enumerated() {
            view.isHidden = index >= iconCount
            if !view.isHidden {
                view.frame = NSRect(x: x, y: centerY - iconWidth / 2, width: iconWidth, height: iconWidth)
                x += iconStep
            }
        }

        resizeLabel.isHidden = !resizeFits
        if resizeFits {
            resizeLabel.frame = NSRect(x: x + 4, y: centerY - 7, width: resizeWidth - 8, height: 14)
        }

        let spectrumX = max(0, bounds.width - inset - spectrumWidth - rightStatus)
        audioButton.frame = NSRect(x: spectrumX - 2, y: centerY - 12, width: spectrumWidth + 4, height: 24)
        spectrum.frame = NSRect(x: spectrumX, y: centerY - 10, width: spectrumWidth, height: 20)
        layoutStatus(after: spectrum.frame.maxX, metrics: visibleMetrics, clock: visibleClock)
        CATransaction.commit()
    }

    private func configureStatus(_ label: NSTextField, fontSize: CGFloat, color: NSColor) {
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        label.isHidden = true
        addSubview(label)
    }

    private func measuredWidth(_ label: NSTextField) -> CGFloat {
        guard !label.stringValue.isEmpty, let font = label.font else { return 0 }
        let size = (label.stringValue as NSString).size(withAttributes: [.font: font])
        return ceil(size.width) + 6
    }

    private func statusWidth(metrics: CGFloat, clock: CGFloat) -> CGFloat {
        guard metrics > 0 || clock > 0 else { return 0 }
        return statusGap + metrics + clock + (metrics > 0 && clock > 0 ? statusDividerGap : 0)
    }

    private func layoutStatus(after end: CGFloat, metrics: CGFloat, clock: CGFloat) {
        statusDivider.isHidden = metrics == 0 && clock == 0
        statusDivider.frame = NSRect(x: end + 7, y: centerY - 5, width: 1, height: 10)
        var x = end + statusGap
        metricsLabel.isHidden = metrics == 0
        metricsLabel.frame = NSRect(x: x, y: centerY - 8, width: metrics, height: 16)
        x += metrics
        clockDivider.isHidden = metrics == 0 || clock == 0
        if !clockDivider.isHidden {
            clockDivider.frame = NSRect(x: x + 5, y: centerY - 5, width: 1, height: 10)
            x += statusDividerGap
        }
        clockLabel.isHidden = clock == 0
        clockLabel.frame = NSRect(x: x, y: centerY - 8, width: clock, height: 16)
    }

    private func setIcons(_ icons: [NSImage]) {
        let countChanged = icons.count != appViews.count
        while appViews.count > icons.count {
            appViews.removeLast().removeFromSuperview()
        }
        while appViews.count < icons.count {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            addSubview(view)
            appViews.append(view)
        }
        for (view, icon) in zip(appViews, icons) {
            if view.image !== icon {
                view.image = icon
                view.toolTip = icon.accessibilityDescription
            }
        }
        if countChanged { needsLayout = true }
    }

    private func setLabel(_ button: NSButton, color: NSColor) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        button.attributedTitle = NSAttributedString(string: String(button.tag + 1),
                                                   attributes: [.font: numberFont, .foregroundColor: color,
                                                                .paragraphStyle: centered])
    }

    @objc private func selectWorkspace(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    @objc private func activateAudio() {
        onActivateAudio?()
    }
}

private final class PlaybackSpectrumView: NSView {
    private static let binCount = 24
    private var levels = [Float](repeating: 0, count: binCount)
    private var targets = [Float](repeating: 0, count: binCount)
    private var timer: Timer?
    private var enabled = false
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled {
            targets = [Float](repeating: 0, count: Self.binCount)
            levels = targets
            timer?.invalidate()
            timer = nil
        }
        needsDisplay = true
    }

    func update(_ values: [Float]) {
        guard enabled else { return }
        for index in targets.indices {
            guard !values.isEmpty else {
                targets[index] = 0
                continue
            }
            let position = Float(index) * Float(values.count - 1) / Float(targets.count - 1)
            let lower = Int(position)
            let upper = min(values.count - 1, lower + 1)
            let weight = position - Float(lower)
            let level = values[lower] * (1 - weight) + values[upper] * weight
            targets[index] = level.isFinite ? min(max(level, 0), 1) : 0
        }
        guard timer == nil, zip(levels, targets).contains(where: { abs($0 - $1) > 0.003 }) else { return }
        let animation = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.step()
        }
        timer = animation
        RunLoop.main.add(animation, forMode: .common)
    }

    private func step() {
        var moving = false
        for index in levels.indices {
            let difference = targets[index] - levels[index]
            if abs(difference) > 0.003 {
                levels[index] += difference * (difference > 0 ? 0.39 : 0.14)
                moving = true
            } else {
                levels[index] = targets[index]
            }
        }
        needsDisplay = true
        if !moving {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let pitch = bounds.width / CGFloat(levels.count)
        let lineWidth = max(0.65, pitch * 0.54)
        let baseline: CGFloat = 3
        let path = CGMutablePath()
        for (index, level) in levels.enumerated() {
            let height = 0.8 + CGFloat(level) * 15.2
            let x = (CGFloat(index) + 0.5) * pitch - lineWidth / 2
            path.addRoundedRect(in: CGRect(x: x, y: baseline, width: lineWidth, height: height),
                                cornerWidth: lineWidth / 2, cornerHeight: 0.7)
        }
        let peak = CGFloat(levels.max() ?? 0)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 4.0,
                          color: NSColor(srgbRed: 0.61, green: 0.22, blue: 1, alpha: peak * 0.75).cgColor)
        context.setFillColor(NSColor(srgbRed: 0.62, green: 0.30, blue: 0.92, alpha: enabled ? 0.52 : 0.25).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()

        let colors = [
            NSColor(srgbRed: 0.61, green: 0.17, blue: 0.93, alpha: peak * 0.67).cgColor,
            NSColor(srgbRed: 0.92, green: 0.47, blue: 1, alpha: peak * 0.90).cgColor
        ]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: nil) else {
            return
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: baseline),
                                   end: CGPoint(x: 0, y: baseline + 16), options: [])
        context.restoreGState()
    }
}

private final class WorkspaceGlow: NSView {
    private let paint = CALayer()
    private let gradient = CAGradientLayer()
    private let reflection = CAGradientLayer()
    private let radius: CGFloat = 6
    private var selected = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(paint)
        paint.opacity = 0
        paint.shadowColor = NSColor(srgbRed: 0.77, green: 0.40, blue: 0.98, alpha: 1).cgColor
        paint.shadowOpacity = 0.42
        paint.shadowRadius = 5
        paint.shadowOffset = .zero
        gradient.cornerRadius = radius
        gradient.masksToBounds = true
        gradient.borderWidth = 0.75
        gradient.borderColor = NSColor(srgbRed: 0.91, green: 0.84, blue: 1, alpha: 0.64).cgColor
        gradient.colors = [
            NSColor(srgbRed: 0.68, green: 0.49, blue: 0.98, alpha: 0.96).cgColor,
            NSColor(srgbRed: 0.48, green: 0.29, blue: 0.83, alpha: 0.94).cgColor,
            NSColor(srgbRed: 0.29, green: 0.17, blue: 0.58, alpha: 0.97).cgColor,
        ]
        gradient.locations = [0, 0.53, 1]
        gradient.startPoint = CGPoint(x: 0.18, y: 1)
        gradient.endPoint = CGPoint(x: 0.74, y: 0)
        paint.addSublayer(gradient)

        reflection.colors = [
            NSColor(srgbRed: 0.94, green: 0.88, blue: 1, alpha: 0.20).cgColor,
            NSColor(srgbRed: 0.94, green: 0.88, blue: 1, alpha: 0).cgColor,
        ]
        reflection.startPoint = CGPoint(x: 0.5, y: 1)
        reflection.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.addSublayer(reflection)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint.frame = bounds
        paint.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        gradient.frame = paint.bounds
        let height = gradient.bounds.height * 0.50
        reflection.frame = CGRect(x: 0, y: gradient.bounds.height - height,
                                  width: gradient.bounds.width, height: height)
        CATransaction.commit()
    }

    func setActive(_ active: Bool, animated: Bool) {
        guard active != selected else { return }
        selected = active
        let startingOpacity = paint.presentation()?.opacity ?? paint.opacity
        let destination: Float = active ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paint.opacity = destination
        if animated {
            let transition = CABasicAnimation(keyPath: "opacity")
            transition.fromValue = startingOpacity
            transition.toValue = destination
            transition.duration = 0.24
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            paint.add(transition, forKey: "activation")
        } else {
            paint.removeAnimation(forKey: "activation")
        }
        CATransaction.commit()
    }
}
