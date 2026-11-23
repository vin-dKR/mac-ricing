import AppKit

enum WorkspaceChrome {
    static let edgeInset: CGFloat = 5
    static let footerHeight: CGFloat = 32
    static let matte = CGColor(srgbRed: 0.035, green: 0.038, blue: 0.06, alpha: 0.78)
}

/// The straight footer shares the frame's matte and has no independent outline.
final class GlassSurface: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let footer = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                            height: min(bounds.height, WorkspaceChrome.footerHeight))
        context.setFillColor(WorkspaceChrome.matte)
        context.fill(footer)
    }
}
