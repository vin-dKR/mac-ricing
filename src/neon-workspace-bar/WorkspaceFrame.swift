import AppKit
import SwiftUI

struct WorkspaceCornerRadii: Equatable {
    var topLeft: CGFloat = 10
    var topRight: CGFloat = 10
    var bottomLeft: CGFloat = 10
    var bottomRight: CGFloat = 10
}

/// A slim matte around the desktop, with an opening for the wallpaper and tiles.
final class WorkspaceFrame: NSView {
    var cornerRadii = WorkspaceCornerRadii() {
        didSet {
            if cornerRadii != oldValue { needsDisplay = true }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset = WorkspaceChrome.edgeInset
        let footer = WorkspaceChrome.footerHeight
        guard let context = NSGraphicsContext.current?.cgContext,
              bounds.width > inset * 2, bounds.height > footer + inset else { return }
        let body = NSRect(x: bounds.minX, y: bounds.minY + footer,
                          width: bounds.width, height: bounds.height - footer)
        let opening = NSRect(x: body.minX + inset, y: body.minY,
                             width: body.width - inset * 2, height: body.height - inset)
        context.setFillColor(WorkspaceChrome.matte)
        context.addRect(body)
        context.addPath(openingPath(in: opening))
        context.fillPath(using: .evenOdd)
    }

    private func openingPath(in rect: CGRect) -> CGPath {
        let radii = RectangleCornerRadii(topLeading: cornerRadii.topLeft, bottomLeading: cornerRadii.bottomLeft,
                                         bottomTrailing: cornerRadii.bottomRight, topTrailing: cornerRadii.topRight)
        let path = Path(roundedRect: CGRect(origin: .zero, size: rect.size), cornerRadii: radii, style: .continuous).cgPath
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY)
        return path.copy(using: &flip) ?? path
    }
}
