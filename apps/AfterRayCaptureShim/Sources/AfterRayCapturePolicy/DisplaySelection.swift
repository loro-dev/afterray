import CoreGraphics

package struct CaptureDisplayGeometry: Equatable {
    package let id: UInt32
    package let frame: CGRect

    package init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

package enum CaptureDisplaySelection {
    /// Chooses the display containing most of the focused window. The main
    /// display wins an exact tie and is also the fallback when AX cannot
    /// provide a usable window frame.
    package static func displayID(
        for windowFrame: CGRect?,
        displays: [CaptureDisplayGeometry],
        fallbackDisplayID: UInt32?
    ) -> UInt32? {
        guard !displays.isEmpty else { return nil }
        let fallback = fallbackDisplayID.flatMap { fallbackID in
            displays.first(where: { $0.id == fallbackID })?.id
        } ?? displays[0].id
        guard
            let windowFrame,
            !windowFrame.isNull,
            !windowFrame.isInfinite,
            !windowFrame.isEmpty
        else { return fallback }

        let intersections = displays.map { display in
            let intersection = windowFrame.intersection(display.frame)
            let area = intersection.isNull || intersection.isEmpty
                ? 0
                : intersection.width * intersection.height
            return (display.id, area)
        }
        guard let maximumArea = intersections.map(\.1).max(), maximumArea > 0 else {
            return fallback
        }
        if intersections.contains(where: { $0.0 == fallback && $0.1 == maximumArea }) {
            return fallback
        }
        return intersections.first(where: { $0.1 == maximumArea })?.0 ?? fallback
    }
}
