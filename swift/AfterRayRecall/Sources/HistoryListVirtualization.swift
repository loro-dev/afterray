import Foundation

/// One row in the history scroller. Flattened so the window sees a stable
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

    /// Height-cache key, which is *not* `id`.
    ///
    /// `id` is view identity and must stay stable across expand/collapse or
    /// the row is torn down and rebuilt on every toggle. But an expanded card
    /// is hundreds of points taller, so a cache keyed on `id` alone hands the
    /// layout model the wrong height. Same for the loader, 8pt idle / 36pt busy.
    func heightKey(isLoadingMore: Bool) -> String {
        switch self {
        case .heading:
            id
        case let .slot(_, expanded):
            expanded ? "\(id)+" : id
        case .loadMore:
            isLoadingMore ? "more!" : "more"
        }
    }
}

/// A first guess at a row's height, replaced by the measured value as soon as
/// the row is laid out.
///
/// **Nothing here may parse Markdown.** An estimate that costs a full
/// `AttributedString(markdown:)` pass over the card body is worse than no
/// estimate at all — that mistake cost 113ms a frame once already
/// ([context](../../../context/history-list-scrolling.md)). Every question
/// below is answered from the shape of the data.
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
        var height = slotChrome
        let hasTitle = !(slot.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasTitle, hasDescription(slot) { height += descriptionBlock }
        if !hasTitle, DaySummaryLayout.fallbackBadge(state: slot.state) != nil {
            height += badgeLine
        }
        if DaySummaryLayout.hasExpandableDetail(slot: slot) { height += detailsLink }
        if expanded { height += CGFloat(sectionGuess(slot)) * expandedSection }
        if !slot.facts.apps.isEmpty { height += iconStrip }
        return height
    }

    private static func hasDescription(_ slot: DaySlotSummary) -> Bool {
        if let description = slot.description,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return !(slot.bullets ?? []).isEmpty
    }

    /// How many sections an expanded card is likely to draw, counted from the
    /// document's shape rather than by parsing it. A v3 body's sections are
    /// its headings, and a body with no headings renders as one.
    private static func sectionGuess(_ slot: DaySlotSummary) -> Int {
        if let details = slot.details, !details.isEmpty {
            let headings = details.split(separator: "\n").reduce(into: 0) { count, line in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { count += 1 }
            }
            return max(1, headings)
        }
        if let threads = slot.threads, !threads.isEmpty {
            return threads.count
                + (slot.decisions?.isEmpty == false ? 1 : 0)
                + (slot.notCaptured?.isEmpty == false ? 1 : 0)
        }
        return (slot.bullets ?? []).count
    }
}

/// Heights for rows the window has laid out, plus memoized guesses for the
/// ones it has not.
///
/// Not `ObservableObject`: recording a height must not rebuild the panel.
///
/// Estimates are memoized per key. Building the height array is O(rows) and
/// runs on every body pass, so every entry has to be a dictionary lookup.
final class HistoryRowHeightCache: @unchecked Sendable {
    private let lock = NSLock()
    private var measured: [String: CGFloat] = [:]
    private var estimates: [String: CGFloat] = [:]

    /// `estimate` is called at most once per key, and never once the row has
    /// been measured. Pass the work as a closure; do not evaluate it eagerly.
    func height(for key: String, estimate: () -> CGFloat) -> CGFloat {
        lock.lock()
        if let known = measured[key] ?? estimates[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let value = estimate()
        lock.lock()
        estimates[key] = value
        lock.unlock()
        return value
    }

    /// Records a measured height and reports how far the model moved, or nil
    /// if it did not move. The caller needs the delta to compensate the scroll
    /// offset when the row sits above the fold.
    func record(id: String, measured value: CGFloat) -> CGFloat? {
        guard value.isFinite, value > 1 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let previous = measured[id] ?? estimates[id]
        measured[id] = value
        guard let previous else { return nil }
        let delta = value - previous
        return abs(delta) >= 1 ? delta : nil
    }

    func invalidate(_ id: String) {
        lock.lock()
        measured[id] = nil
        estimates[id] = nil
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

/// The windowed layout model: which rows to mount, and how much empty space
/// holds the place of the ones that are not.
enum HistoryListLayout {
    static let spacing: CGFloat = 8
    /// Telegram `ListView.invisibleInset`: mount this much past the fold.
    static let overscan: CGFloat = 600
    static let defaultViewport: CGFloat = 460
    static let horizontalInset: CGFloat = 6
    static let bottomPadding: CGFloat = 8

    static func heights(
        items: [HistoryListItem],
        cache: HistoryRowHeightCache,
        isLoadingMore: Bool
    ) -> [CGFloat] {
        items.map { item in
            cache.height(for: item.heightKey(isLoadingMore: isLoadingMore)) {
                HistoryRowHeight.estimate(item, isLoadingMore: isLoadingMore)
            }
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

    static func contentHeight(origins: [CGFloat]) -> CGFloat {
        origins.last ?? 0
    }

    /// Rows intersecting the viewport plus overscan.
    ///
    /// **Total by construction: for a non-empty list this always returns a
    /// non-empty range that spans the viewport.** The previous version mapped a
    /// real scroll offset onto a model built from estimates, and when the two
    /// drifted far enough apart it fell through to a `(count-1)..<count`
    /// fallback — one row mounted, viewport blank. Clamping the offset into the
    /// model first means an out-of-range offset resolves to the nearest real
    /// screenful instead of off the end.
    static func visibleRange(
        origins: [CGFloat],
        offset: CGFloat,
        viewportHeight: CGFloat,
        overscan: CGFloat = overscan
    ) -> Range<Int> {
        let count = max(origins.count - 1, 0)
        guard count > 0 else { return 0..<0 }
        let viewport = viewportHeight > 0 ? viewportHeight : defaultViewport
        let height = contentHeight(origins: origins)
        let clamped = min(max(0, offset), max(0, height - viewport))
        let y0 = clamped - overscan
        let y1 = clamped + viewport + overscan

        var start: Int?
        var end = 0
        for index in 0..<count where origins[index + 1] > y0 && origins[index] < y1 {
            if start == nil { start = index }
            end = index + 1
        }
        guard let start, end > start else {
            // Unreachable for a well-formed model — every row has height, so
            // some row must intersect a clamped window. Answer with the last
            // screenful rather than nothing, so a malformed model degrades to
            // "wrong rows" and never to "no rows".
            return max(0, count - 1)..<count
        }
        return start..<end
    }

    static func leadingSpacer(rangeStart: Int, origins: [CGFloat]) -> CGFloat {
        guard rangeStart < origins.count else { return 0 }
        return max(0, origins[rangeStart])
    }

    static func trailingSpacer(rangeEnd: Int, origins: [CGFloat]) -> CGFloat {
        guard rangeEnd < origins.count else { return 0 }
        return max(0, contentHeight(origins: origins) - origins[rangeEnd])
    }

    static func index(of id: String, in items: [HistoryListItem]) -> Int? {
        items.firstIndex { $0.id == id }
    }

    /// Scroll distance from the top of the content. Rubber-banding past the
    /// top reports a negative visible origin; clamp it so "near the bottom"
    /// cannot fire while the user is overscrolling upward.
    static func offset(visibleMinY: CGFloat) -> CGFloat {
        max(0, visibleMinY)
    }

    /// Keep the highlighted row on screen while the playhead moves over it.
    ///
    /// Returns the offset that reveals row `index`, or **nil when it is
    /// already visible** — which is the whole point. Following by jumping the
    /// row to the top fires on every slot boundary, and a drag across a day
    /// crosses ~48 of them: the panel bounces under a finger that is nowhere
    /// near it, and each jump costs a `ScrollView` re-measure. Revealing only
    /// what has left the viewport means a scrub inside one screenful of cards
    /// moves the document not at all.
    ///
    /// The scroll is the minimum that works: a row just under the fold rises
    /// to sit above it, it does not fly to the top.
    static func offsetToReveal(
        index: Int,
        origins: [CGFloat],
        offset: CGFloat,
        viewportHeight: CGFloat,
        margin: CGFloat = 24
    ) -> CGFloat? {
        guard index >= 0, index + 1 < origins.count, viewportHeight > 0 else { return nil }
        let maxOffset = max(0, contentHeight(origins: origins) - viewportHeight)
        // `origins` folds the gap after a row into the next edge, so a row's
        // extent here includes its trailing spacing. Revealing 8pt more than
        // the card is harmless — it shows the gap — and avoids threading the
        // raw heights through just to subtract it again.
        let rowTop = origins[index]
        let rowBottom = origins[index + 1]

        // A row taller than the viewport that already spans it is as visible
        // as it can get.
        if rowTop <= offset, rowBottom >= offset + viewportHeight { return nil }

        let inset = min(margin, max(0, (viewportHeight - (rowBottom - rowTop)) / 2))
        let top = rowTop - inset
        let bottom = rowBottom + inset
        if top >= offset, bottom <= offset + viewportHeight { return nil }

        // Align the top when the row is above the fold, and also when it
        // cannot fit: showing the bottom edge of a card taller than the
        // viewport hides the title, which is the part worth reading.
        let alignTop = top < offset || bottom - top > viewportHeight
        let clamped = min(max(0, alignTop ? top : bottom - viewportHeight), maxOffset)
        // Below the tolerance the request is noise: a sub-point correction
        // would still cost a relayout.
        return abs(clamped - offset) < 1 ? nil : clamped
    }

    /// When a row's measured height replaces its estimate, everything below it
    /// moves by `heightDelta`. If the row sits above the viewport, the pixels
    /// on screen have just been pushed too — so the scroll offset has to move
    /// by the same amount to hold them still.
    ///
    /// This is the compensation Telegram's `ListView` does in layout, and the
    /// piece that makes an estimate-based window converge instead of drift. It
    /// needs a writable scroll offset (`ScrollPosition.scrollTo(y:)`,
    /// macOS 15); on macOS 14 it could not be expressed at all.
    static func offsetDeltaAfterHeightChange(
        rowOrigin: CGFloat,
        viewportOffset: CGFloat,
        heightDelta: CGFloat
    ) -> CGFloat {
        guard abs(heightDelta) >= 1, rowOrigin < viewportOffset else { return 0 }
        return heightDelta
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
    ///
    /// Computed from the model rather than from measured positions, because
    /// the headings this asks about are above the fold and therefore not
    /// mounted. The model is exact up there: a row you have already scrolled
    /// past has been measured, and measured heights never expire.
    static func chip(
        items: [HistoryListItem],
        origins: [CGFloat],
        offset: CGFloat
    ) -> DayHeadingChip? {
        var candidate: (origin: CGFloat, chip: DayHeadingChip)?
        for (index, item) in items.enumerated() {
            guard case let .heading(dayStartMs, label, isToday) = item else { continue }
            guard index < origins.count, origins[index] < offset else { continue }
            if candidate == nil || origins[index] >= candidate!.origin {
                candidate = (
                    origins[index],
                    DayHeadingChip(dayStartMs: dayStartMs, label: label, isToday: isToday)
                )
            }
        }
        return candidate?.chip
    }
}
