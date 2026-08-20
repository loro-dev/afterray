import SwiftUI

/// A windowed history list: only the rows intersecting the viewport (plus
/// `HistoryListLayout.overscan`) are mounted, and the rest of the document is
/// held open by two spacers sized from the height model.
///
/// This is the Telegram `ListView` model, which needs three things SwiftUI
/// only offers from macOS 15. All three are load-bearing:
///
/// - `onScrollGeometryChange` — read the offset without routing geometry
///   through a `PreferenceKey`, which fed every scroll frame back through a
///   body pass and was half of why the previous attempt oscillated.
/// - `onGeometryChange` — measure a mounted row the same way.
/// - `ScrollPosition.scrollTo(y:)` — **write** the offset in points. This is
///   the compensation: when a measured height replaces an estimate for a row
///   above the fold, the offset moves by the same delta and the pixels on
///   screen stay put.
///
/// Without that last one the model and the real document drift apart with no
/// way to reconcile them, the window resolves off the end of the model, and
/// the viewport goes blank. That is not hypothetical — it shipped. The full
/// account is in `context/history-list-scrolling.md`; read it before changing
/// anything here.
///
/// Why it converges: a row's height is only ever wrong *before its first
/// measurement*, and a row is only met for the first time by scrolling toward
/// it — which puts it below the fold, where a correction needs no
/// compensation at all. Measured heights never expire, so scrolling back up is
/// exact. Compensation is the rare case (a jump into unmeasured rows), not the
/// steady state, which is why writing the offset does not fight momentum.
struct HistoryListScrollView<Row: View>: View {
    var items: [HistoryListItem]
    var isLoadingMore: Bool
    var hasMore: Bool
    var showsIndicator: Bool
    var followID: String?
    var followGeneration: Int
    var onLoadMore: () -> Void
    var onStickyChip: (DayHeadingChip?) -> Void
    var row: (HistoryListItem) -> Row

    @State private var runtime = HistoryWindowRuntime()
    @State private var mounted: Range<Int> = 0..<0
    @State private var scrollPosition = ScrollPosition()
    /// Bumped when a measurement changes the height model, to rebuild the
    /// spacers. The heights themselves live in `runtime`, off `@State`, so a
    /// measurement that changes nothing costs nothing.
    @State private var modelRevision = 0

    var body: some View {
        let _ = modelRevision
        let origins = currentOrigins()
        let range = renderedRange(origins: origins)
        let top = HistoryListLayout.leadingSpacer(rangeStart: range.lowerBound, origins: origins)
        let bottom = HistoryListLayout.trailingSpacer(rangeEnd: range.upperBound, origins: origins)
        let lastID = items.last?.id

        ScrollView(.vertical, showsIndicators: showsIndicator) {
            VStack(spacing: 0) {
                if top > 0 {
                    Color.clear.frame(height: top)
                }
                ForEach(items[range]) { item in
                    row(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            record(height: height, for: item)
                        }
                        .padding(.bottom, item.id == lastID ? 0 : HistoryListLayout.spacing)
                        .id(item.id)
                }
                if bottom > 0 {
                    Color.clear.frame(height: bottom)
                }
            }
            .padding(.horizontal, HistoryListLayout.horizontalInset)
            .padding(.bottom, HistoryListLayout.bottomPadding)
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: HistoryViewportMetrics.self) { geometry in
            HistoryViewportMetrics(
                offset: HistoryListLayout.offset(visibleMinY: geometry.visibleRect.minY),
                height: geometry.containerSize.height
            )
        } action: { _, metrics in
            runtime.offset = metrics.offset
            runtime.viewportHeight = metrics.height
            applyWindow()
        }
        .onChange(of: layoutKeys) { _, _ in
            applyWindow(reconcilingOffset: true)
        }
        .onChange(of: followGeneration) { _, _ in follow() }
        .onAppear {
            applyWindow()
            follow()
        }
        .background(ScrollFenceView())
    }

    private func currentOrigins() -> [CGFloat] {
        HistoryListLayout.origins(
            heights: HistoryListLayout.heights(
                items: items,
                cache: runtime.cache,
                isLoadingMore: isLoadingMore
            )
        )
    }

    private var layoutKeys: [String] {
        HistoryListLayout.heightKeys(items: items, isLoadingMore: isLoadingMore)
    }

    /// `mounted` lags the model by one update after the item list changes, so
    /// clamp it, and derive a window outright when there is not one yet.
    private func renderedRange(origins: [CGFloat]) -> Range<Int> {
        guard !items.isEmpty else { return 0..<0 }
        let lower = min(max(0, mounted.lowerBound), items.count)
        let upper = min(max(lower, mounted.upperBound), items.count)
        guard lower < upper else {
            return HistoryListLayout.visibleRange(
                origins: origins,
                offset: runtime.offset,
                viewportHeight: runtime.viewportHeight
            )
        }
        return lower..<upper
    }

    private func applyWindow(reconcilingOffset: Bool = false) {
        let origins = currentOrigins()
        if reconcilingOffset {
            let clamped = HistoryListLayout.clampedOffset(
                origins: origins,
                offset: runtime.offset,
                viewportHeight: runtime.viewportHeight
            )
            if abs(clamped - runtime.offset) >= 1 {
                runtime.offset = clamped
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scrollPosition.scrollTo(y: clamped)
                }
            } else {
                runtime.offset = clamped
            }
        }
        let next = HistoryListLayout.visibleRange(
            origins: origins,
            offset: runtime.offset,
            viewportHeight: runtime.viewportHeight
        )
        if next != mounted { mounted = next }

        onStickyChip(
            HistoryStickyHeading.chip(items: items, origins: origins, offset: runtime.offset)
        )

        guard hasMore, !isLoadingMore else { return }
        guard HistoryLoadMore.isNearBottom(
            offset: runtime.offset,
            viewportHeight: runtime.viewportHeight,
            contentHeight: HistoryListLayout.contentHeight(origins: origins)
                + HistoryListLayout.bottomPadding
        ) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - runtime.lastLoadMoreAt > 0.25 else { return }
        runtime.lastLoadMoreAt = now
        onLoadMore()
    }

    /// A row just reported its real height. Update the model, and if the row
    /// is above the fold, move the offset by the same delta so what the user
    /// is looking at does not shift under them.
    private func record(height: CGFloat, for item: HistoryListItem) {
        let key = item.heightKey(isLoadingMore: isLoadingMore)
        // Cheap check first. `onGeometryChange` fires for every mounted row on
        // every layout pass, and almost all of them report a height the model
        // already has; building the origins array before finding that out made
        // an O(rows) pass the common case instead of the rare one.
        guard let delta = runtime.cache.record(id: key, measured: height) else { return }
        // Only now: the row's position under the layout the user is currently
        // seeing, which is what the delta has to be measured against.
        let originsBefore = currentOrigins()

        if let index = HistoryListLayout.index(of: item.id, in: items),
           index < originsBefore.count
        {
            let shift = HistoryListLayout.offsetDeltaAfterHeightChange(
                rowOrigin: originsBefore[index],
                viewportOffset: runtime.offset,
                heightDelta: delta
            )
            if shift != 0 {
                runtime.offset += shift
                scrollPosition.scrollTo(y: runtime.offset)
            }
        }

        modelRevision &+= 1
        applyWindow()
    }

    /// Scroll to the followed row by model position, not by identity — the
    /// target is usually not mounted, and `scrollTo(y:)` does not care.
    /// Reveal the followed row, and only if it needs revealing.
    ///
    /// Not "scroll it to the top": that fires on every slot boundary the
    /// playhead crosses, which is ~48 of them in a drag across one day. The
    /// panel bounced, and every jump cost a `ScrollView` re-measure. Asking
    /// instead for the minimum scroll that puts the row on screen means a
    /// scrub within one screenful of cards moves the document not at all,
    /// while the highlight still tracks live.
    private func follow() {
        guard let followID,
              let index = HistoryListLayout.index(of: followID, in: items)
        else { return }
        if ScrollFenceRegistry.shared.pointerInsideAnyFence() { return }
        guard let target = HistoryListLayout.offsetToReveal(
            index: index,
            origins: currentOrigins(),
            offset: runtime.offset,
            viewportHeight: runtime.viewportHeight
        ) else { return }
        runtime.offset = target
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(y: target)
        }
    }
}

private struct HistoryViewportMetrics: Equatable {
    var offset: CGFloat
    var height: CGFloat
}

/// Scroll geometry and the height cache, deliberately off `@State`: these
/// change on every scroll frame and none of them may rebuild the list. Only
/// `mounted` does that, and only when the window actually moves.
final class HistoryWindowRuntime {
    let cache = HistoryRowHeightCache()
    var offset: CGFloat = 0
    var viewportHeight: CGFloat = HistoryListLayout.defaultViewport
    var lastLoadMoreAt: CFAbsoluteTime = 0
}
