import AppKit

/// Menu bar glyph matching the app icon: music bars that dip under a speech bubble while ducking.
@MainActor
enum MenuBarIcon {
    static let normal = make(ducking: false)
    static let ducking = make(ducking: true)

    private static func make(ducking: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            if ducking {
                bars([7, 4, 2.4, 4, 7], centerY: 4.8)
                bubble(NSRect(x: 4.9, y: 10.6, width: 8.2, height: 5.2), tailX: 8.4)
            } else {
                bars([6, 11, 14, 9, 6], centerY: 8)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = ducking ? L10n.menuBarLowered : "Hushover"
        return image
    }

    private static func bars(_ heights: [CGFloat], centerY: CGFloat) {
        let width: CGFloat = 2
        for (i, height) in heights.enumerated() {
            let x = 2 + CGFloat(i) * 3.5 - width / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: centerY - height / 2, width: width, height: height),
                         xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    private static func bubble(_ rect: NSRect, tailX: CGFloat) {
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tailX - 1.2, y: rect.minY + 0.6))
        tail.line(to: NSPoint(x: tailX - 0.6, y: rect.minY - 2.2))
        tail.line(to: NSPoint(x: tailX + 1.6, y: rect.minY + 0.6))
        tail.close()
        tail.fill()
    }
}
