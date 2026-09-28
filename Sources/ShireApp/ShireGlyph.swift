import AppKit

/// The Shire logo reduced to a one-colour menu bar glyph: a rounded hill with an arched doorway and two server
/// drawers inside. Drawn with paths (no image asset) so it stays crisp at 16 points and takes the menu bar's colour.
enum ShireGlyph {
    /// The glyph's own box, in points. The status dot sits to its right.
    static let size = NSSize(width: 18, height: 16)

    static func draw(in rect: NSRect, color: NSColor) {
        let sx = rect.width / size.width, sy = rect.height / size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }

        // The hill, with the doorway cut out of it (even-odd fill).
        let hill = NSBezierPath()
        // The base flares out at the corners, like the logo's mound settling into the ground.
        hill.move(to: p(0, 1))
        hill.curve(to: p(1.6, 4.2), controlPoint1: p(1.2, 1.4), controlPoint2: p(1.6, 2.6))
        hill.curve(to: p(9, 12.6), controlPoint1: p(1.6, 9.6), controlPoint2: p(4.8, 12.6))
        hill.curve(to: p(16.4, 4.2), controlPoint1: p(13.2, 12.6), controlPoint2: p(16.4, 9.6))
        hill.curve(to: p(18, 1), controlPoint1: p(16.4, 2.6), controlPoint2: p(16.8, 1.4))
        hill.close()
        hill.move(to: p(3.6, 1))
        hill.line(to: p(3.6, 5.2))
        hill.curve(to: p(9, 9.6), controlPoint1: p(3.6, 8.1), controlPoint2: p(6, 9.6))
        hill.curve(to: p(14.4, 5.2), controlPoint1: p(12, 9.6), controlPoint2: p(14.4, 8.1))
        hill.line(to: p(14.4, 1))
        hill.close()
        hill.windingRule = .evenOdd
        color.setFill()
        hill.fill()

        // Two server drawers in the doorway, each with its status light punched out.
        for y in [1.9, 4.7] {
            let drawer = NSRect(x: rect.minX + 4.9 * sx, y: rect.minY + y * sy, width: 8.2 * sx, height: 2.2 * sy)
            NSBezierPath(roundedRect: drawer, xRadius: 0.8 * sx, yRadius: 0.8 * sy).fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 11 * sx, y: rect.minY + (y + 0.6) * sy, width: 1 * sx, height: 1 * sy)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The menu bar image: the glyph plus a status dot, drawn at display time so the glyph follows the menu bar's
    /// light or dark appearance while the dot keeps its colour.
    static func menuBarImage(dot: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { rect in
            draw(in: NSRect(origin: .zero, size: size), color: .labelColor)
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - 5.5, y: 9.5, width: 5.5, height: 5.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
