import AppKit

/// A small-size redraw of the AfterRay gravitational-lensing mark.
///
/// Two moments of one ray wrap around the negative-space event horizon. This
/// preserves the app icon's motion without shrinking its glow and texture into
/// menu-bar noise.
enum AfterRayMenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            // The present ray enters from the lower left, then lenses around
            // the lower and right edges of the event horizon.
            let presentRay = NSBezierPath()
            presentRay.lineWidth = 1.55
            presentRay.lineCapStyle = .round
            presentRay.lineJoinStyle = .round
            presentRay.move(to: NSPoint(x: 1.35, y: 1.35))
            presentRay.line(to: NSPoint(x: 5.15, y: 5.15))
            presentRay.curve(
                to: NSPoint(x: 11.75, y: 4.45),
                controlPoint1: NSPoint(x: 6.93, y: 3.50),
                controlPoint2: NSPoint(x: 9.65, y: 3.22)
            )
            presentRay.curve(
                to: NSPoint(x: 14.30, y: 10.53),
                controlPoint1: NSPoint(x: 13.85, y: 5.68),
                controlPoint2: NSPoint(x: 14.90, y: 8.17)
            )
            NSColor.black.setStroke()
            presentRay.stroke()

            // Its afterimage exits at the upper right and wraps the opposite
            // side. Lower alpha adds depth without introducing a second color.
            let afterimage = NSBezierPath()
            afterimage.lineWidth = 1.55
            afterimage.lineCapStyle = .round
            afterimage.lineJoinStyle = .round
            afterimage.move(to: NSPoint(x: 16.65, y: 16.65))
            afterimage.line(to: NSPoint(x: 12.85, y: 12.85))
            afterimage.curve(
                to: NSPoint(x: 6.25, y: 13.55),
                controlPoint1: NSPoint(x: 11.07, y: 14.50),
                controlPoint2: NSPoint(x: 8.35, y: 14.78)
            )
            afterimage.curve(
                to: NSPoint(x: 3.70, y: 7.47),
                controlPoint1: NSPoint(x: 4.15, y: 12.32),
                controlPoint2: NSPoint(x: 3.10, y: 9.83)
            )
            NSColor.black.withAlphaComponent(0.58).setStroke()
            afterimage.stroke()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "AfterRay"
        return image
    }
}
