import CoreGraphics
import Foundation

/// Even spacing for the search filmstrip.
///
/// Deliberately *not* proportional to time, unlike `TimelineLayout`. Search
/// results are a discrete list — a match from three seconds ago and one from
/// last Tuesday are equally worth a look, so each gets an equal cell. The
/// relative-time caption under each cell carries the temporal information the
/// spacing no longer does.
public struct SearchFilmstripLayout: Equatable, Sendable {
    public static let cellWidth: CGFloat = 132
    public static let cellHeight: CGFloat = 82
    public static let cellGap: CGFloat = 14

    public let count: Int
    public let viewportWidth: CGFloat

    public init(count: Int, viewportWidth: CGFloat) {
        self.count = max(count, 0)
        self.viewportWidth = max(viewportWidth, 1)
    }

    public static var stride: CGFloat { cellWidth + cellGap }

    /// Centre of cell `index` along the strip.
    public func centerX(index: Int) -> CGFloat {
        CGFloat(index) * Self.stride + Self.cellWidth / 2
    }

    public var contentWidth: CGFloat {
        guard count > 0 else { return 1 }
        return CGFloat(count) * Self.cellWidth + CGFloat(count - 1) * Self.cellGap
    }

    /// How far to slide the strip so cell `index` sits under the fixed playhead
    /// at the viewport centre. Mirrors `AppUsageTimeline`: the playhead never
    /// moves, the content does.
    public func offset(forIndex index: Int) -> CGFloat {
        viewportWidth / 2 - centerX(index: index)
    }

    /// Cell nearest to a tap at `x` within the *strip's* own coordinates.
    public func index(atX x: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let raw = Int(((x + Self.cellGap / 2) / Self.stride).rounded(.down))
        return min(max(raw, 0), count - 1)
    }

    /// Whole-cell step for a drag of `deltaX` points. Dragging left (negative)
    /// moves the strip left, bringing later — that is, older — cells under the
    /// playhead, matching how the main timeline travels backwards in time.
    public func steps(forDragTranslation deltaX: CGFloat) -> Int {
        Int((-deltaX / Self.stride).rounded())
    }
}

/// Compact "how long ago" captions for filmstrip cells.
///
/// Full timestamps under two dozen cells is a wall of digits nobody reads. The
/// exact time still lives in the playhead capsule above the strip, which is the
/// one place it is worth the room.
public enum RelativeStamp {
    private static let minute: Int64 = 60_000
    private static let hour: Int64 = 60 * minute
    private static let day: Int64 = 24 * hour
    private static let week: Int64 = 7 * day

    /// `NOW`, `5M`, `3H`, `2D`, `6W`, `2Y`.
    public static func short(fromMs: Int64, nowMs: Int64) -> String {
        let elapsed = max(nowMs - fromMs, 0)
        if elapsed < minute { return "NOW" }
        if elapsed < hour { return "\(elapsed / minute)M" }
        if elapsed < day { return "\(elapsed / hour)H" }
        if elapsed < week { return "\(elapsed / day)D" }
        let weeks = elapsed / week
        if weeks < 52 { return "\(weeks)W" }
        return "\(weeks / 52)Y"
    }
}
