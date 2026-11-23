import AppKit
import ApplicationServices
import Carbon
import OSLog

let log = Logger(subsystem: "io.github.macricing.keyboard-desk", category: "launcher")
let home = FileManager.default.homeDirectoryForCurrentUser
let environment = ProcessInfo.processInfo.environment
let installRoot = environment["MAC_RICING_ROOT"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent(".local/share/mac-ricing/current")

struct Entry {
    let title: String
    let detail: String
    let run: () -> Void

    func matches(_ words: [Substring]) -> Bool {
        words.allSatisfy { "\(title) \(detail)".localizedStandardContains(String($0)) }
    }
}

func openSettings(_ destination: String) {
    guard let url = URL(string: "x-apple.systempreferences:\(destination)") else { return }
    NSWorkspace.shared.open(url)
}

func ghosttyURL() -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty")
}

func editorPath() -> String? {
    let tools = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    return (tools + ["/opt/homebrew/bin", "/usr/local/bin"]).map { directory in
        URL(fileURLWithPath: directory).appendingPathComponent("nvim").path
    }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

func openTerminal(editor: String? = nil) {
    let ghostty = ghosttyURL()
    let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
    guard let destination = ghostty ?? terminal else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    if let editor, ghostty != nil {
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-e", editor]
    }
    NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
        if let error { log.error("Terminal: \(error.localizedDescription, privacy: .public)") }
    }
}

func openBrowser() {
    let marker = URL(string: "https://example.com")!
    guard let app = NSWorkspace.shared.urlForApplication(toOpen: marker) else { return }
    NSWorkspace.shared.openApplication(at: app, configuration: .init())
}

func applicationEntries() -> [Entry] {
    let roots = ["/Applications", "/System/Applications", home.appendingPathComponent("Applications").path]
    var seen = Set<String>()
    var apps: [Entry] = []
    for root in roots {
        guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.localizedNameKey], options: [.skipsHiddenFiles]) else { continue }
        for case let url as URL in files where url.pathExtension == "app" {
            files.skipDescendants()
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
                ?? url.deletingPathExtension().lastPathComponent
            let title = (name as NSString).pathExtension == "app" ? String(name.dropLast(4)) : name
            apps.append(Entry(title: title, detail: "App") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            })
        }
    }
    return apps.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
}

func windowEntries() -> [Entry] {
    NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !$0.isTerminated }
        .flatMap { app -> [Entry] in
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.15)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return [] }
            return windows.map { window in
                var titleValue: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                let name = app.localizedName ?? "Application"
                let title = titleValue as? String ?? ""
                return Entry(title: title.isEmpty ? name : title, detail: name) {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    app.activate()
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
}

final class Desk: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "")
    private var entries: [Entry] = []
    private var results: [Entry] = []
    private var priorApp: NSRunningApplication?
    private var hotkeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPanel()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == 0x4B444553 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<Desk>.fromOpaque(context).takeUnretainedValue().runHotkey(key.id)
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            log.error("Hotkey handler failed: \(status)")
            return
        }
        register(kVK_Space, optionKey, 1)
        register(kVK_ANSI_Slash, optionKey, 2)
        register(kVK_Return, optionKey | controlKey, 3)
        register(kVK_ANSI_B, optionKey | controlKey, 4)
        if CommandLine.arguments.contains("--show") { show(windows: false) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(windows: false)
        return false
    }

    private func register(_ code: Int, _ modifiers: Int, _ id: UInt32) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), UInt32(modifiers),
            EventHotKeyID(signature: 0x4B444553, id: id), GetApplicationEventTarget(), 0, &reference)
        if let reference, status == noErr { hotkeys.append(reference) }
        else { log.error("Global shortcut \(id) could not be registered: \(status)") }
    }

    private func runHotkey(_ id: UInt32) {
        switch id {
        case 1: show(windows: false)
        case 2: show(windows: true)
        case 3: openTerminal()
        case 4: openBrowser()
        default: break
        }
    }

    private func setupPanel() {
        panel.title = "Keyboard Desk"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        field.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        field.setAccessibilityLabel("Search")
        field.delegate = self
        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 25
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel("Search results")
        table.target = self
        table.doubleAction = #selector(runSelection)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
    }

    private func show(windows: Bool) {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.processIdentifier != ProcessInfo.processInfo.processIdentifier { priorApp = current }
        let keyboardAccess = Entry(title: "Full Keyboard Access", detail: "System Settings") {
            openSettings("com.apple.Accessibility-Settings.extension?Keyboard")
        }
        if windows {
            entries = AXIsProcessTrusted() ? windowEntries() : [
                Entry(title: "Allow window search", detail: "Open Accessibility settings") {
                    openSettings("com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
                }
            ]
        } else {
            entries = [
                Entry(title: "Terminal", detail: "Ghostty or Terminal", run: { openTerminal() }),
                Entry(title: "Browser", detail: "Default browser", run: openBrowser),
                keyboardAccess,
                Entry(title: "Keyboard shortcuts", detail: "Open cheatsheet") {
                    NSWorkspace.shared.open(installRoot.appending(path: "share/Shortcuts.txt"))
                },
            ]
            if let editor = editorPath(), ghosttyURL() != nil {
                entries.append(Entry(title: "Neovim", detail: "Open in Ghostty") { openTerminal(editor: editor) })
            }
            entries += applicationEntries()
        }
        field.placeholderString = windows ? "Find a window…" : "Launch an app or action…"
        field.stringValue = ""
        filter()
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func filter() {
        let words = field.stringValue.split(whereSeparator: \.isWhitespace)
        results = entries.filter { $0.matches(words) }
        table.reloadData()
        if !results.isEmpty { select(0) }
        hint.stringValue = results.isEmpty ? "No matches   ·   Esc close" : "↑↓ select   ·   ↵ open   ·   Esc close"
    }

    private func select(_ row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func runSelection() {
        let row = table.selectedRow
        guard results.indices.contains(row) else { NSSound.beep(); return }
        let entry = results[row]
        panel.orderOut(nil)
        entry.run()
    }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            if !results.isEmpty {
                let offset = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
                select(max(0, min(results.count - 1, table.selectedRow + offset)))
            }
        case #selector(NSResponder.insertNewline(_:)):
            runSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            panel.orderOut(nil)
            priorApp?.activate()
        default:
            return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = results[row]
        let cell = NSTextField(labelWithString: "\(entry.title)   ·   \(entry.detail)")
        cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let desk = Desk()
app.delegate = desk
app.run()
