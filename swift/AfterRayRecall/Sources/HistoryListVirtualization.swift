import Foundation

/// One row in the history scroller. Flattened so a lazy stack sees a stable
/// count of single-child rows — not a day section that expands into N slots.
enum HistoryListItem: Identifiable, Equatable {
    case heading(dayStartMs: Int64, label: String, isToday: Bool)
    case slot(DaySlotSummary, expanded: Bool)
    case loadMore

    var id: String {
        switch self {
        case let .heading(dayStartMs, _, _):
            "d-\(dayStartMs)"
        case let .slot(slot, _):
            "s-\(slot.slotStartMs)"
        case .loadMore:
            "more"
        }
    }

    static func headingID(dayStartMs: Int64) -> String { "d-\(dayStartMs)" }
    static func slotID(slotStartMs: Int64) -> String { "s-\(slotStartMs)" }
}

/// Guess-then-measure, the UITableView `estimatedRowHeight` model.
///
/// `LazyVStack` estimates off-screen rows from nearby measured ones (often
/// ~0). A feed of wrapped titles then makes document height — and the
/// scrollbar — jump on every recycle. We seed a content-aware guess and
/// replace it with the measured height after first layout. Recycled rows
/// reuse the cache so the stack never falls back to 0.
enum HistoryRowHeight {
    static let heading: CGFloat = 28
    static let loadMoreIdle: CGFloat = 8
    static let loadMoreBusy: CGFloat = 36
    static let slotChrome: CGFloat = 52
    static let descriptionBlock: CGFloat = 34
    static let detailsLink: CGFloat = 18
    static let badgeLine: CGFloat = 16
    static let iconStrip: CGFloat = 20
    static let expandedSection: CGFloat = 44

    static func estimate(_ item: HistoryListItem, isLoadingMore: Bool = false) -> CGFloat {
        switch item {
        case .heading:
            heading
        case .loadMore:
            isLoadingMore ? loadMoreBusy : loadMoreIdle
        case let .slot(slot, expanded):
            estimateSlot(slot, expanded: expanded)
        }
    }

    static func estimateSlot(_ slot: DaySlotSummary, expanded: Bool) -> CGFloat {
        let row = DaySummaryLayout.rowText(slot: slot)
        var height = slotChrome
        if !row.detail.isEmpty { height += descriptionBlock }
        if row.badge != nil { height += badgeLine }
        let sections = DaySummaryLayout.expandedSections(slot: slot)
        if !sections.isEmpty { height += detailsLink }
        if expanded { height += CGFloat(sections.count) * expandedSection }
        if !slot.facts.apps.isEmpty { height += iconStrip }
        return height
    }
}

/// Measured heights for rows the lazy stack has already laid out.
///
/// Not `ObservableObject`: recording a height must not rebuild the panel.
/// Live rows can grow past `minHeight`; the cache only matters when a row
/// is discarded and mounted again.
final class HistoryRowHeightCache: @unchecked Sendable {
    private let lock = NSLock()
    private var measured: [String: CGFloat] = [:]

    func height(for id: String, estimate: CGFloat) -> CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return measured[id] ?? estimate
    }

    func record(id: String, measured value: CGFloat) {
        guard value.isFinite, value > 1 else { return }
        lock.lock()
        defer { lock.unlock() }
        if let previous = measured[id], abs(previous - value) < 1 { return }
        measured[id] = value
    }

    func invalidate(_ id: String) {
        lock.lock()
        measured[id] = nil
        lock.unlock()
    }
}

/// Header caption for how many days the panel is showing.
///
/// The number is the vault's occupied local-day count, not how many days
/// have been paged into the scroller. Missing or zero hides the caption
/// rather than guessing from the loaded page.
enum HistoryDayCount {
    static func label(totalDays: Int?) -> String {
        guard let totalDays, totalDays > 0 else { return "" }
        return totalDays == 1 ? "1 day" : "\(totalDays) days"
    }
}

enum HistoryListItems {
    static func build(
        summaries: [DaySummary],
        nowMs: Int64,
        expandedSlotStarts: Set<Int64>,
        hasMore: Bool
    ) -> [HistoryListItem] {
        var items: [HistoryListItem] = []
        items.reserveCapacity(summaries.reduce(0) { $0 + $1.slots.count + 1 } + 1)
        for summary in summaries {
            let heading = DaySummaryLayout.dateHeading(
                dayStartMs: summary.dayStartMs,
                nowMs: nowMs
            )
            items.append(
                .heading(
                    dayStartMs: summary.dayStartMs,
                    label: DaySummaryLayout.headingLabel(heading),
                    isToday: heading.isToday
                )
            )
            for slot in DaySummaryLayout.displayOrder(summary.slots) {
                items.append(
                    .slot(slot, expanded: expandedSlotStarts.contains(slot.slotStartMs))
                )
            }
        }
        if hasMore { items.append(.loadMore) }
        return items
    }
}

/// Windowed list: mount only the rows that intersect the viewport (plus
/// overscan and any pinned index). Unmounted rows stay in the document as
/// spacers so `LazyVStack`'s "unmounted height is 0" trap cannot recur.
enum HistoryListLayout {
    static let spacing: CGFloat = 8
    /// Telegram `ListView.invisibleInset`: mount this much past the fold.
    static let overscan: CGFloat = 500
    static let defaultViewport: CGFloat = 460
    /// Telegram chat history prefetches when the visible index is within
    /// five loaded rows of an edge — not when a sentinel's `onAppear` fires.
    static let prefetchEdge = 5
    static let horizontalInset: CGFloat = 6
    static let bottomPadding: CGFloat = 8

    static func heights(
        items: [HistoryListItem],
        cache: HistoryRowHeightCache,
        isLoadingMore: Bool
    ) -> [CGFloat] {
        items.map { item in
            cache.height(
                for: item.id,
                estimate: HistoryRowHeight.estimate(item, isLoadingMore: isLoadingMore)
            )
        }
    }

    /// `n+1` edges: `origins[i]` is the top of item `i`, `origins[n]` is the
    /// content height. The gap after item `i` is folded into `origins[i+1]`.
    static func origins(heights: [CGFloat], spacing: CGFloat = spacing) -> [CGFloat] {
        var origins: [CGFloat] = []
        origins.reserveCapacity(heights.count + 1)
        var y: CGFloat = 0
        origins.append(y)
        for (index, height) in heights.enumerated() {
            y += height
            if index < heights.count - 1 { y += spacing }
            origins.append(y)
        }
        return origins
    }

    static func offset(contentMinY: CGFloat) -> CGFloat {
        max(0, -contentMinY)
    }

    static func visibleRange(
        origins: [CGFloat],
        offset: CGFloat,
        viewportHeight: CGFloat,
        overscan: CGFloat = overscan
    ) -> Range<Int> {
        let count = max(origins.count - 1, 0)
        guard count > 0 else { return 0..<0 }
        let viewport = viewportHeight > 0 ? viewportHeight : defaultViewport
        let y0 = max(0, offset - overscan)
        let y1 = offset + viewport + overscan
        var start: Int?
        var end = 0
        for index in 0..<count {
            let top = origins[index]
            let bottom = origins[index + 1]
            if bottom > y0 && top < y1 {
                if start == nil { start = index }
                end = index + 1
            }
        }
        if let start {
            return start..<end
        }
        if y0 >= (origins.last ?? 0) {
            return (count - 1)..<count
        }
        return 0..<min(count, 1)
    }

    static func mountedRanges(
        origins: [CGFloat],
        offset: CGFloat,
        viewportHeight: CGFloat,
        extraIndices: Set<Int> = [],
        overscan: CGFloat = overscan
    ) -> [Range<Int>] {
        let count = max(origins.count - 1, 0)
        guard count > 0 else { return [] }
        let visible = visibleRange(
            origins: origins,
            offset: offset,
            viewportHeight: viewportHeight,
            overscan: overscan
        )
        return merge(range: visible, extras: extraIndices, count: count)
    }

    static func merge(range: Range<Int>, extras: Set<Int>, count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        var indices = Set(range)
        for extra in extras where extra >= 0 && extra < count {
            indices.insert(extra)
        }
        let sorted = indices.sorted()
        guard let first = sorted.first else { return [] }
        var ranges: [Range<Int>] = []
        var start = first
        var previous = first
        for index in sorted.dropFirst() {
            if index <= previous + 1 {
                previous = index
            } else {
                ranges.append(start..<(previous + 1))
                start = index
                previous = index
            }
        }
        ranges.append(start..<(previous + 1))
        return ranges
    }

    static func leadingSpacer(
        rangeStart: Int,
        previousEnd: Int,
        origins: [CGFloat]
    ) -> CGFloat {
        guard rangeStart < origins.count, previousEnd < origins.count else { return 0 }
        return max(0, origins[rangeStart] - origins[previousEnd])
    }

    static func trailingSpacer(lastEnd: Int, origins: [CGFloat]) -> CGFloat {
        guard let contentHeight = origins.last, lastEnd < origins.count else { return 0 }
        return max(0, contentHeight - origins[lastEnd])
    }

    static func index(of id: String, in items: [HistoryListItem]) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// If a row above the viewport changes height, the clip origin must move
    /// by the same delta so the pixels under the fold stay put.
    static func offsetDeltaAfterHeightChange(
        rowOrigin: CGFloat,
        viewportOffset: CGFloat,
        heightDelta: CGFloat
    ) -> CGFloat {
        guard abs(heightDelta) >= 1, rowOrigin < viewportOffset else { return 0 }
        return heightDelta
    }

    static func shouldPrefetchOlder(
        visibleLastIndex: Int,
        itemCount: Int,
        edge: Int = prefetchEdge
    ) -> Bool {
        itemCount > 0 && visibleLastIndex >= max(0, itemCount - 1 - edge)
    }

    static func shouldLoadMore(
        visibleLastIndex: Int,
        itemCount: Int,
        offset: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> Bool {
        shouldPrefetchOlder(visibleLastIndex: visibleLastIndex, itemCount: itemCount)
            || HistoryLoadMore.isNearBottom(
                offset: offset,
                viewportHeight: viewportHeight,
                contentHeight: contentHeight
            )
    }
}

/// Whether the next page should be fetched. Prefetch starts `lead` points
/// before the content end so a flick to the bottom is already loading.
enum HistoryLoadMore {
    static let lead: CGFloat = 400

    static func isNearBottom(
        offset: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> Bool {
        viewportHeight > 0 && offset + viewportHeight + lead >= contentHeight
    }
}

/// Compact chip over the scroller, not a full-width pinned bar: AppKit
/// images in slot rows composite above a `Section` header.
struct DayHeadingChip: Equatable {
    var dayStartMs: Int64
    var label: String
    var isToday: Bool
}

enum HistoryStickyHeading {
    /// The day's in-flow heading that just left the top. Nil while that
    /// heading is still on screen — the chip must not duplicate it.
    /// Computed from content offset so unmounted headings still count.
    static func chip(
        items: [HistoryListItem],
        origins: [CGFloat],
        offset: CGFloat
    ) -> DayHeadingChip? {
        var candidate: (origin: CGFloat, chip: DayHeadingChip)?
        for (index, item) in items.enumerated() {
            guard case let .heading(dayStartMs, label, isToday) = item else { continue }
            guard index < origins.count else { continue }
            let origin = origins[index]
            guard origin < offset else { continue }
            if candidate == nil || origin >= candidate!.origin {
                candidate = (
                    origin,
                    DayHeadingChip(dayStartMs: dayStartMs, label: label, isToday: isToday)
                )
            }
        }
        return candidate?.chip
    }
}
