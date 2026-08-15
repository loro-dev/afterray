import CoreGraphics
import Foundation

public struct AppUsageIdentity: Equatable, Hashable, Sendable {
    public let name: String
    public let bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }

    public static func of(_ moment: RecallMoment) -> AppUsageIdentity {
        AppUsageIdentity(
            name: moment.applicationName ?? "Unknown app",
            bundleIdentifier: moment.bundleIdentifier
        )
    }
}

public struct AppUsageRun: Equatable, Identifiable, Sendable {
    public let id: Int
    public let identity: AppUsageIdentity
    public let startMs: Int64
    public let endMs: Int64
    public let startIndex: Int
    public let endIndex: Int
    public let startX: CGFloat
    public let width: CGFloat
    public let isIdle: Bool

    public var applicationName: String { isIdle ? "休眠" : identity.name }
    public var bundleIdentifier: String? { isIdle ? nil : identity.bundleIdentifier }
    public var durationMs: Int64 { max(endMs - startMs, 1) }
    public var endX: CGFloat { startX + width }

    public func contains(ms: Int64, isLast: Bool) -> Bool {
        if isLast { return ms >= startMs && ms <= endMs }
        return ms >= startMs && ms < endMs
    }

    public func contains(x: CGFloat, isLast: Bool) -> Bool {
        if isLast { return x >= startX && x <= endX }
        return x >= startX && x < endX
    }
}

/// A starred capture, already placed. Filtering the whole moment list for
/// favourites on every frame was one of the scroll's per-frame O(n) costs;
/// they change only when the captures do, so they are placed once here.
public struct TimelineFavorite: Equatable, Identifiable, Sendable {
    public let id: String
    public let x: CGFloat
}

/// Everything a timeline derives from the captures alone: the bounds and the
/// uncoloured runs. Zoom and viewport width only decide how wide each run is
/// drawn, so keeping this separate lets a zoom drag re-place runs without
/// re-scanning and re-sorting every moment.
public struct TimelineSpine: Equatable, Sendable {
    let startMs: Int64
    let endMs: Int64
    let raw: [TimelineLayout.RawRun]
    let visualTotalMs: Int64

    public init(moments: [RecallMoment]) {
        let bounds = TimelineLayout.timeBounds(moments: moments)
        startMs = bounds.startMs
        endMs = bounds.endMs
        let runs = TimelineLayout.makeRuns(moments: moments, endMs: bounds.endMs)
        raw = runs
        visualTotalMs = max(runs.reduce(Int64(0)) { $0 + $1.visualDurationMs }, 1)
    }
}

/// Single mapping from wall-clock time to timeline x, and back.
///
/// Short app-switch runs can be inflated to a minimum width, but that warp is
/// part of this function. Playhead, colored runs, hits, and drag all use it.
public struct TimelineLayout: Equatable, Sendable {
    public let moments: [RecallMoment]
    public let runs: [AppUsageRun]
    public let favorites: [TimelineFavorite]
    public let startMs: Int64
    public let endMs: Int64
    public let contentWidth: CGFloat

    public static let minimumSegmentWidth: CGFloat = 5
    public static let idleGapThresholdMs: Int64 = 30_000
    public static let captureIntervalMs: Int64 = 10_000
    public static let maximumIdleVisualDurationMs: Int64 = 120_000

    public init(
        moments: [RecallMoment],
        viewportWidth: CGFloat,
        density: Double,
        minimumSegmentWidth: CGFloat = TimelineLayout.minimumSegmentWidth
    ) {
        self.init(
            spine: TimelineSpine(moments: moments),
            moments: moments,
            viewportWidth: viewportWidth,
            density: density,
            minimumSegmentWidth: minimumSegmentWidth
        )
    }

    /// Re-places an already-computed spine at a new width. This is the path a
    /// zoom drag takes: O(runs), with no moment scan.
    public init(
        spine: TimelineSpine,
        moments: [RecallMoment],
        viewportWidth: CGFloat,
        density: Double,
        minimumSegmentWidth: CGFloat = TimelineLayout.minimumSegmentWidth
    ) {
        self.moments = moments
        startMs = spine.startMs
        endMs = spine.endMs

        let visualTotal = spine.visualTotalMs
        let seconds = CGFloat(visualTotal) / 1_000
        // Zoom multiplies `density`. Keep a high ceiling so a long archive can
        // still widen instead of sticking at the old 9_000 pt cap.
        let naturalWidth = seconds * CGFloat(density)
        let floorWidth = max(viewportWidth, 1) * 1.18
        let baseWidth = max(floorWidth, min(naturalWidth, 64_000))

        var cursor: CGFloat = 0
        var placed: [AppUsageRun] = []
        placed.reserveCapacity(spine.raw.count)
        for raw in spine.raw {
            let natural = baseWidth * CGFloat(raw.visualDurationMs) / CGFloat(visualTotal)
            let width = max(natural, minimumSegmentWidth)
            placed.append(
                AppUsageRun(
                    id: raw.id,
                    identity: raw.identity,
                    startMs: raw.startMs,
                    endMs: raw.endMs,
                    startIndex: raw.startIndex,
                    endIndex: raw.endIndex,
                    startX: cursor,
                    width: width,
                    isIdle: raw.isIdle
                )
            )
            cursor += width
        }
        runs = placed
        contentWidth = max(cursor, 1)
        favorites = Self.placeFavorites(
            moments: moments,
            runs: placed,
            startMs: spine.startMs,
            endMs: spine.endMs,
            contentWidth: contentWidth
        )
    }

    private static func placeFavorites(
        moments: [RecallMoment],
        runs: [AppUsageRun],
        startMs: Int64,
        endMs: Int64,
        contentWidth: CGFloat
    ) -> [TimelineFavorite] {
        moments.reduce(into: [TimelineFavorite]()) { marks, moment in
            guard moment.isFavorite else { return }
            marks.append(
                TimelineFavorite(
                    id: moment.id,
                    x: x(
                        ms: moment.capturedAtMs,
                        runs: runs,
                        startMs: startMs,
                        endMs: endMs,
                        contentWidth: contentWidth
                    )
                )
            )
        }
    }

    public static func timeBounds(moments: [RecallMoment]) -> (startMs: Int64, endMs: Int64) {
        guard let first = moments.first, let last = moments.last else {
            return (0, 1)
        }
        let intervals = zip(moments, moments.dropFirst())
            .map { max($1.capturedAtMs - $0.capturedAtMs, 1_000) }
            .sorted()
        let trailingInterval = intervals.isEmpty ? 10_000 : intervals[intervals.count / 2]
        return (first.capturedAtMs, last.capturedAtMs + min(trailingInterval, 60_000))
    }

    public func x(ms: Int64) -> CGFloat {
        Self.x(
            ms: ms,
            runs: runs,
            startMs: startMs,
            endMs: endMs,
            contentWidth: contentWidth
        )
    }

    private static func x(
        ms: Int64,
        runs: [AppUsageRun],
        startMs: Int64,
        endMs: Int64,
        contentWidth: CGFloat
    ) -> CGFloat {
        if ms <= startMs { return 0 }
        if ms >= endMs { return contentWidth }
        guard let run = run(containingMs: ms, in: runs) else { return contentWidth }
        let duration = CGFloat(max(run.endMs - run.startMs, 1))
        let t = CGFloat(ms - run.startMs) / duration
        return run.startX + t * run.width
    }

    public func ms(x: CGFloat) -> Int64 {
        if x <= 0 { return startMs }
        if x >= contentWidth { return endMs }
        guard let run = run(atX: x) else { return endMs }
        let t = Double((x - run.startX) / max(run.width, 0.000_1))
        let clamped = min(max(t, 0), 1)
        let value = run.startMs + Int64((Double(run.endMs - run.startMs) * clamped).rounded())
        return min(max(value, run.startMs), run.endMs)
    }

    public func playheadX(playheadMs: Int64, isLive: Bool) -> CGFloat {
        x(ms: isLive ? endMs : playheadMs)
    }

    public func run(containingMs ms: Int64) -> AppUsageRun? {
        Self.run(containingMs: ms, in: runs)
    }

    public func run(atX x: CGFloat) -> AppUsageRun? {
        Self.run(atX: x, in: runs)
    }

    /// Runs tile the whole span end to end, so the run holding `ms` is the
    /// last one starting at or before it. Scrubbing asked this once per
    /// frame per lookup; a linear scan made that O(runs).
    static func run(containingMs ms: Int64, in runs: [AppUsageRun]) -> AppUsageRun? {
        guard let first = runs.first, let last = runs.last else { return nil }
        let index = searchIndex(in: runs) { $0.startMs <= ms }
        if runs[index].contains(ms: ms, isLast: index == runs.count - 1) {
            return runs[index]
        }
        if last.contains(ms: ms, isLast: true) || ms >= last.startMs {
            return last
        }
        return first
    }

    static func run(atX x: CGFloat, in runs: [AppUsageRun]) -> AppUsageRun? {
        guard let first = runs.first, let last = runs.last else { return nil }
        let index = searchIndex(in: runs) { $0.startX <= x }
        if runs[index].contains(x: x, isLast: index == runs.count - 1) {
            return runs[index]
        }
        if last.contains(x: x, isLast: true) || x >= last.startX {
            return last
        }
        return first
    }

    /// Index of the last element satisfying a predicate that is true for a
    /// prefix of the collection, or 0 when none is.
    private static func searchIndex(
        in runs: [AppUsageRun],
        while isBefore: (AppUsageRun) -> Bool
    ) -> Int {
        var low = 0
        var high = runs.count - 1
        while low < high {
            let mid = low + (high - low + 1) / 2
            if isBefore(runs[mid]) {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// The runs that intersect `range`, for a view that only draws what the
    /// viewport can show. A day of captures is tens of thousands of points
    /// wide; the visible slice is one screen of it.
    public func runs(intersecting range: ClosedRange<CGFloat>) -> ArraySlice<AppUsageRun> {
        guard !runs.isEmpty else { return runs[runs.startIndex..<runs.startIndex] }
        let firstIndex = Self.searchIndex(in: runs) { $0.startX <= range.lowerBound }
        var lastIndex = firstIndex
        while lastIndex + 1 < runs.count, runs[lastIndex + 1].startX <= range.upperBound {
            lastIndex += 1
        }
        return runs[firstIndex...lastIndex]
    }

    public func clamp(_ playheadMs: Int64) -> Int64 {
        min(max(playheadMs, startMs), endMs)
    }

    /// `direction` < 0 prefers the recorded moment before an idle gap,
    /// > 0 prefers the moment after, 0 picks the nearer edge.
    public func snapToRecordedMs(_ playheadMs: Int64, preferring direction: Int = 0) -> Int64 {
        guard let run = run(containingMs: playheadMs), run.isIdle else {
            return playheadMs
        }
        let previous = moments[run.startIndex].capturedAtMs
        let nextIndex = run.startIndex + 1
        guard nextIndex < moments.count else { return previous }
        let next = moments[nextIndex].capturedAtMs
        if direction < 0 { return previous }
        if direction > 0 { return next }
        return abs(playheadMs - previous) <= abs(next - playheadMs) ? previous : next
    }

    struct RawRun: Equatable, Sendable {
        let id: Int
        let identity: AppUsageIdentity
        let startMs: Int64
        let endMs: Int64
        let startIndex: Int
        let endIndex: Int
        let isIdle: Bool
        var durationMs: Int64 { max(endMs - startMs, 1) }
        var visualDurationMs: Int64 {
            if isIdle {
                return min(durationMs, TimelineLayout.maximumIdleVisualDurationMs)
            }
            return durationMs
        }
    }

    static func makeRuns(moments: [RecallMoment], endMs: Int64) -> [RawRun] {
        guard !moments.isEmpty else { return [] }
        var collected: [RawRun] = []
        var runStart = 0
        // Hoisted: rebuilding the run's identity for every moment doubled the
        // string traffic of the only full scan on this path.
        var runIdentity = AppUsageIdentity.of(moments[0])
        for index in 1...moments.count {
            let atEnd = index == moments.count
            let nextGap = atEnd ? 0 : moments[index].capturedAtMs - moments[index - 1].capturedAtMs
            let identityChanged = !atEnd && AppUsageIdentity.of(moments[index]) != runIdentity
            let idleAhead = !atEnd && nextGap > idleGapThresholdMs
            guard atEnd || identityChanged || idleAhead else { continue }

            let lastMoment = moments[index - 1]
            let appEndMs: Int64
            if atEnd {
                appEndMs = endMs
            } else if idleAhead {
                appEndMs = min(lastMoment.capturedAtMs + captureIntervalMs, moments[index].capturedAtMs)
            } else {
                appEndMs = moments[index].capturedAtMs
            }
            collected.append(
                RawRun(
                    id: collected.count,
                    identity: .of(moments[runStart]),
                    startMs: moments[runStart].capturedAtMs,
                    endMs: appEndMs,
                    startIndex: runStart,
                    endIndex: index - 1,
                    isIdle: false
                )
            )
            if idleAhead {
                collected.append(
                    RawRun(
                        id: collected.count,
                        identity: AppUsageIdentity(name: "休眠", bundleIdentifier: nil),
                        startMs: appEndMs,
                        endMs: moments[index].capturedAtMs,
                        startIndex: index - 1,
                        endIndex: index - 1,
                        isIdle: true
                    )
                )
            }
            runStart = index
            if !atEnd { runIdentity = AppUsageIdentity.of(moments[index]) }
        }
        return collected
    }
}

/// Keeps one `TimelineLayout` alive across renders, rebuilding only what its
/// inputs invalidate. Main thread only — it is held by a view's `@State` and
/// read from `body`.
///
/// Held by reference on purpose: the cache is derived data, so refreshing it
/// during a render must not itself invalidate the view.
public final class TimelineLayoutCache {
    private var moments: [RecallMoment] = []
    private var spine: TimelineSpine?
    private var viewportWidth: CGFloat = -1
    private var density: Double = -1
    private var placed: TimelineLayout?

    /// How much work the cache has actually avoided. Read by the tests: the
    /// guarantee worth protecting is a count, not a duration.
    public private(set) var scans = 0
    public private(set) var placements = 0

    public init() {}

    public func layout(
        moments: [RecallMoment],
        viewportWidth: CGFloat,
        density: Double
    ) -> TimelineLayout {
        let spine = spine(for: moments)
        if let placed, viewportWidth == self.viewportWidth, density == self.density {
            return placed
        }
        let built = TimelineLayout(
            spine: spine,
            moments: moments,
            viewportWidth: viewportWidth,
            density: density
        )
        self.viewportWidth = viewportWidth
        self.density = density
        placed = built
        placements += 1
        return built
    }

    /// `Array ==` short-circuits on shared storage, so the steady state — the
    /// same captures frame after frame — costs a pointer comparison. The
    /// store only republishes when something actually changed.
    private func spine(for moments: [RecallMoment]) -> TimelineSpine {
        if let spine, self.moments == moments { return spine }
        let built = TimelineSpine(moments: moments)
        self.moments = moments
        spine = built
        placed = nil
        scans += 1
        return built
    }
}

public enum RecallPlayhead {
    /// Last captured frame at or before `playheadMs`. Idle gaps resolve to nil.
    public static func resolve(playheadMs: Int64, moments: [RecallMoment]) -> RecallMoment? {
        guard let index = resolveIndex(playheadMs: playheadMs, moments: moments) else { return nil }
        let moment = moments[index]
        if index + 1 < moments.count {
            let gap = moments[index + 1].capturedAtMs - moment.capturedAtMs
            if gap > TimelineLayout.idleGapThresholdMs,
               playheadMs > moment.capturedAtMs + TimelineLayout.captureIntervalMs
            {
                return nil
            }
        }
        return moment
    }

    /// Captures are stored oldest first, so the frame under the playhead is
    /// the last one at or before it. Scrubbing resolves this several times a
    /// frame — walking the whole day to find it is what made it expensive.
    public static func resolveIndex(playheadMs: Int64, moments: [RecallMoment]) -> Int? {
        guard !moments.isEmpty else { return nil }
        if playheadMs < moments[0].capturedAtMs { return 0 }
        var low = 0
        var high = moments.count - 1
        while low < high {
            let mid = low + (high - low + 1) / 2
            if moments[mid].capturedAtMs <= playheadMs {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    public static func clamp(_ playheadMs: Int64, moments: [RecallMoment]) -> Int64 {
        let bounds = TimelineLayout.timeBounds(moments: moments)
        guard !moments.isEmpty else { return 0 }
        return min(max(playheadMs, bounds.startMs), bounds.endMs)
    }

    /// Drag / precise scroll: move the playhead by `deltaX` timeline points.
    /// Positive `deltaX` travels backward in time (content moves right).
    public static func move(
        playheadMs: Int64,
        isLive: Bool,
        deltaX: CGFloat,
        layout: TimelineLayout
    ) -> (playheadMs: Int64, isLive: Bool) {
        guard !layout.moments.isEmpty else { return (playheadMs, isLive) }
        let originX = layout.playheadX(playheadMs: playheadMs, isLive: isLive)
        let ms = layout.ms(x: originX - deltaX)
        if ms >= layout.endMs {
            return (layout.moments[layout.moments.count - 1].capturedAtMs, true)
        }
        let recorded = layout.snapToRecordedMs(ms, preferring: deltaX > 0 ? -1 : 1)
        return (recorded, false)
    }

    public static func stepMoment(
        playheadMs: Int64,
        isLive: Bool,
        delta: Int,
        moments: [RecallMoment]
    ) -> (playheadMs: Int64, isLive: Bool) {
        guard !moments.isEmpty else { return (playheadMs, isLive) }
        let current = isLive
            ? moments.count
            : (resolveIndex(playheadMs: playheadMs, moments: moments) ?? 0)
        let next = current + delta
        if next >= moments.count {
            return (moments[moments.count - 1].capturedAtMs, true)
        }
        if next < 0 {
            return (moments[0].capturedAtMs, false)
        }
        return (moments[next].capturedAtMs, false)
    }
}

enum RecallDisplayedFrame {
    static func choose<Frame>(
        artifactID: String,
        cached: Frame?,
        loadedID: String?,
        loadedFrame: Frame?
    ) -> Frame? {
        if let cached { return cached }
        if loadedID == artifactID { return loadedFrame }
        return loadedFrame
    }
}

/// Throttle, not debounce: stills keep updating while the playhead moves,
/// at most one committed frame per `intervalMilliseconds`.
///
/// 1. Idle: start the latest requested still immediately.
/// 2. Once a still is loading or fading, newer requests only overwrite
///    `pendingID`. The in-flight still is still shown — it is not skipped.
/// 3. When the fade finishes, `pendingID` (latest wins) starts the next tick
///    immediately, so dragging keeps the picture moving.
struct RecallStillGate: Equatable {
    static let intervalMilliseconds = 70
    static var interval: Duration { .milliseconds(intervalMilliseconds) }
    static var animationDuration: TimeInterval {
        TimeInterval(intervalMilliseconds) / 1_000
    }

    /// Incoming still fade. `cubic-bezier(0.22, 0.85, 0.87, 0.22)`:
    /// fast, then a hold around halfway, then fast again.
    static func fadeProgress(at linearTime: CGFloat) -> CGFloat {
        CGFloat(unitBezier(Double(linearTime), x1: 0.22, y1: 0.85, x2: 0.87, y2: 0.22))
    }

    enum Phase: Equatable {
        case idle
        case loading
        case transitioning
    }

    enum Step: Equatable {
        case none
        case needFrame(String)
    }

    private(set) var currentID: String?
    private(set) var targetID: String?
    private(set) var pendingID: String?
    private(set) var phase: Phase = .idle

    var isBusy: Bool { phase != .idle }

    mutating func request(_ id: String) -> Step {
        if phase == .idle {
            if currentID == id {
                pendingID = nil
                return .none
            }
            return begin(id)
        }
        if targetID == id {
            pendingID = nil
            return .none
        }
        pendingID = id
        return .none
    }

    /// The target frame is in memory. Show it even if something newer is
    /// already pending — that is what makes this a throttle.
    ///
    /// The first still stays in `.loading` until `commitSettle`, so playhead
    /// motion during view attach cannot start a second load.
    mutating func frameReady(_ id: String) -> Prepared {
        guard phase == .loading, targetID == id else { return .ignore }
        if currentID == nil {
            return .settle(id)
        }
        phase = .transitioning
        return .transition(to: id)
    }

    mutating func commitSettle(_ id: String) -> Step {
        guard phase == .loading, targetID == id, currentID == nil else { return .none }
        currentID = id
        targetID = nil
        phase = .idle
        if let next = takePending(otherThan: currentID) {
            return begin(next)
        }
        return .none
    }

    mutating func loadFailed(_ id: String) -> Step {
        guard phase == .loading, targetID == id else { return .none }
        targetID = nil
        phase = .idle
        if let next = takePending(otherThan: currentID) {
            return begin(next)
        }
        return .none
    }

    mutating func transitionFinished() -> Step {
        guard phase == .transitioning, let targetID else { return .none }
        currentID = targetID
        self.targetID = nil
        phase = .idle
        if let next = takePending(otherThan: currentID) {
            return begin(next)
        }
        return .none
    }

    enum Prepared: Equatable {
        case ignore
        case settle(String)
        case transition(to: String)
    }

    private mutating func begin(_ id: String) -> Step {
        targetID = id
        pendingID = nil
        phase = .loading
        return .needFrame(id)
    }

    private mutating func takePending(otherThan id: String?) -> String? {
        guard let pendingID else { return nil }
        self.pendingID = nil
        if pendingID == id { return nil }
        return pendingID
    }
}

/// Solve y for x on the unit cubic Bézier (0,0) → (x1,y1) → (x2,y2) → (1,1).
private func unitBezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }

    var t = x
    for _ in 0..<8 {
        let current = sampleBezier(t, p1: x1, p2: x2)
        let delta = current - x
        if abs(delta) < 1e-6 { break }
        let derivative = sampleBezierDerivative(t, p1: x1, p2: x2)
        if abs(derivative) < 1e-6 { break }
        t = min(max(t - delta / derivative, 0), 1)
    }
    return min(max(sampleBezier(t, p1: y1, p2: y2), 0), 1)
}

private func sampleBezier(_ t: Double, p1: Double, p2: Double) -> Double {
    let inverse = 1 - t
    return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
}

private func sampleBezierDerivative(_ t: Double, p1: Double, p2: Double) -> Double {
    let inverse = 1 - t
    return 3 * inverse * inverse * p1 + 6 * inverse * t * (p2 - p1) + 3 * t * t * (1 - p2)
}
