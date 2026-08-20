import XCTest
@testable import AfterRayRecall

/// The window used to collapse to a single row and blank the viewport once the
/// real scroll offset drifted past the estimate-built content height. These pin
/// that it cannot, and that the estimate/measure loop settles.
final class HistoryWindowConvergenceTests: XCTestCase {
    private let viewport: CGFloat = 460

    private func origins(count: Int, height: CGFloat = 124) -> [CGFloat] {
        HistoryListLayout.origins(heights: [CGFloat](repeating: height, count: count))
    }

    // MARK: the white screen

    /// The exact shape that shipped blank: 91 rows, offset well past the
    /// modelled content height.
    func testAnOffsetPastTheModelStillFillsTheViewport() {
        let origins = origins(count: 91)
        let past = (origins.last ?? 0) * 1.4
        let range = HistoryListLayout.visibleRange(
            origins: origins,
            offset: past,
            viewportHeight: viewport
        )
        XCTAssertFalse(range.isEmpty)
        let mountedHeight = origins[range.upperBound] - origins[range.lowerBound]
        XCTAssertGreaterThan(
            mountedHeight,
            viewport,
            "the mounted rows must cover the viewport, not one row at the end"
        )
    }

    /// Sweep the whole document, plus well past both ends, and assert the
    /// window is never degenerate anywhere.
    func testTheWindowIsNeverEmptyAtAnyOffset() {
        let origins = origins(count: 91)
        let height = origins.last ?? 0
        for step in stride(from: -2_000, through: height * 1.5, by: 137) {
            let range = HistoryListLayout.visibleRange(
                origins: origins,
                offset: step,
                viewportHeight: viewport
            )
            XCTAssertFalse(range.isEmpty, "empty window at offset \(step)")
            XCTAssertLessThanOrEqual(range.upperBound, 91)
            XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
        }
    }

    func testASingleRowListStillMounts() {
        let range = HistoryListLayout.visibleRange(
            origins: origins(count: 1),
            offset: 0,
            viewportHeight: viewport
        )
        XCTAssertEqual(range, 0..<1)
    }

    func testAnEmptyListMountsNothing() {
        XCTAssertTrue(
            HistoryListLayout.visibleRange(origins: [0], offset: 0, viewportHeight: viewport)
                .isEmpty
        )
    }

    /// Expand/collapse keeps the same row identity and count. The height keys
    /// are therefore the signal that must invalidate the mounted window.
    func testExpandCollapseChangesTheLayoutKeys() {
        let slot = DaySlotSummary(
            slotStartMs: 0,
            slotEndMs: DaySummaryLayout.slotDurationMs,
            state: "done",
            facts: DaySlotFacts(apps: []),
            title: "A slot",
            bullets: ["detail"]
        )
        let collapsed = [HistoryListItem.slot(slot, expanded: false)]
        let expanded = [HistoryListItem.slot(slot, expanded: true)]

        XCTAssertEqual(collapsed.count, expanded.count)
        XCTAssertEqual(collapsed.map(\.id), expanded.map(\.id))
        XCTAssertNotEqual(
            HistoryListLayout.heightKeys(items: collapsed, isLoadingMore: false),
            HistoryListLayout.heightKeys(items: expanded, isLoadingMore: false)
        )
    }

    /// A tall detail card can leave the old offset beyond the shorter document
    /// after collapse. Keeping that offset produces an empty viewport until
    /// the next scroll geometry event clamps it.
    func testCollapseClampsTheOffsetIntoTheShorterDocument() {
        let expanded = HistoryListLayout.origins(
            heights: [100, 2_500, 100, 100, 100, 100]
        )
        let collapsed = HistoryListLayout.origins(
            heights: [CGFloat](repeating: 100, count: 6)
        )
        let oldOffset: CGFloat = 2_000

        XCTAssertEqual(
            HistoryListLayout.clampedOffset(
                origins: expanded,
                offset: oldOffset,
                viewportHeight: viewport
            ),
            oldOffset
        )

        let reconciled = HistoryListLayout.clampedOffset(
            origins: collapsed,
            offset: oldOffset,
            viewportHeight: viewport
        )
        XCTAssertEqual(
            reconciled,
            HistoryListLayout.contentHeight(origins: collapsed) - viewport
        )
        let range = HistoryListLayout.visibleRange(
            origins: collapsed,
            offset: reconciled,
            viewportHeight: viewport,
            overscan: 0
        )
        XCTAssertGreaterThanOrEqual(
            collapsed[range.upperBound] - collapsed[range.lowerBound],
            viewport
        )
    }

    // MARK: the spacers

    /// Whatever the window, spacers plus mounted rows must equal the document.
    /// If this drifts, the scroll bar is lying about how much is left.
    func testSpacersAndMountedRowsAlwaysSumToTheContentHeight() {
        let origins = origins(count: 91)
        let height = HistoryListLayout.contentHeight(origins: origins)
        for step in stride(from: CGFloat(0), through: height, by: 211) {
            let range = HistoryListLayout.visibleRange(
                origins: origins,
                offset: step,
                viewportHeight: viewport
            )
            let top = HistoryListLayout.leadingSpacer(rangeStart: range.lowerBound, origins: origins)
            let bottom = HistoryListLayout.trailingSpacer(rangeEnd: range.upperBound, origins: origins)
            let rows = origins[range.upperBound] - origins[range.lowerBound]
            XCTAssertEqual(top + rows + bottom, height, accuracy: 0.001)
        }
    }

    // MARK: compensation

    func testAHeightCorrectionAboveTheFoldMovesTheOffset() {
        XCTAssertEqual(
            HistoryListLayout.offsetDeltaAfterHeightChange(
                rowOrigin: 100,
                viewportOffset: 900,
                heightDelta: 40
            ),
            40
        )
    }

    /// Below the fold nothing on screen moved, so the offset must not either.
    /// This is the common case — you meet a row for the first time by
    /// scrolling toward it — and it is why compensation does not fight
    /// momentum.
    func testAHeightCorrectionBelowTheFoldLeavesTheOffsetAlone() {
        XCTAssertEqual(
            HistoryListLayout.offsetDeltaAfterHeightChange(
                rowOrigin: 1_400,
                viewportOffset: 900,
                heightDelta: 40
            ),
            0
        )
    }

    /// The loop that had no fixed point: measure the mounted rows, let the
    /// model move, compensate, re-window — and check it settles instead of
    /// oscillating. Real rows here are 1.8x their estimate.
    func testMeasuringConvergesInsteadOfOscillating() {
        let count = 91
        let estimate: CGFloat = 124
        let real: CGFloat = 224
        let cache = HistoryRowHeightCache()
        var offset: CGFloat = 3_000

        func model() -> [CGFloat] {
            HistoryListLayout.origins(
                heights: (0..<count).map { index in
                    cache.height(for: "row-\(index)") { estimate }
                }
            )
        }

        var lastRange: Range<Int>?
        var settledAfter: Int?
        for pass in 0..<50 {
            let before = model()
            let range = HistoryListLayout.visibleRange(
                origins: before,
                offset: offset,
                viewportHeight: viewport
            )
            var shift: CGFloat = 0
            for index in range {
                if let delta = cache.record(id: "row-\(index)", measured: real) {
                    shift += HistoryListLayout.offsetDeltaAfterHeightChange(
                        rowOrigin: before[index],
                        viewportOffset: offset,
                        heightDelta: delta
                    )
                }
            }
            offset += shift

            if shift == 0, range == lastRange {
                settledAfter = pass
                break
            }
            lastRange = range
        }

        guard let settledAfter else {
            return XCTFail("the measure/compensate loop never settled")
        }
        XCTAssertLessThan(settledAfter, 10, "settled, but took \(settledAfter) passes")

        // And once settled, the window still covers the viewport.
        let final = model()
        let range = HistoryListLayout.visibleRange(
            origins: final,
            offset: offset,
            viewportHeight: viewport
        )
        XCTAssertGreaterThan(final[range.upperBound] - final[range.lowerBound], viewport)
    }

    // MARK: the estimate itself

    /// An estimate that parses the card body is worse than no estimate. This
    /// is the 113ms regression, guarded at its source.
    func testEstimatingNinetyRowsDoesNotParseMarkdown() {
        var lines: [String] = []
        for index in 0..<24 {
            lines.append(index % 6 == 0 ? "## Section \(index)" : "- **bold** and `code` prose.")
        }
        let slots = (0..<91).map { index in
            HistoryListItem.slot(
                DaySlotSummary(
                    slotStartMs: Int64(index) * 1_800_000,
                    slotEndMs: Int64(index) * 1_800_000 + 1_800_000,
                    state: "summarized",
                    facts: DaySlotFacts(apps: [DayAppFact(name: "Xcode", ms: 900_000)]),
                    title: "A slot",
                    details: lines.joined(separator: "\n")
                ),
                expanded: false
            )
        }
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            for item in slots { _ = HistoryRowHeight.estimate(item) }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 10
        XCTAssertLessThan(ms, 5.0, "estimating 91 rows took \(ms)ms — something is parsing")
    }
}

/// Following the playhead reveals the card only when it is not already on
/// screen. Getting this wrong is silent in both directions: too eager and the
/// panel bounces on every slot boundary, too lazy and it stops tracking.
final class HistoryRevealTests: XCTestCase {
    private let viewport: CGFloat = 460
    private let rowHeight: CGFloat = 100

    /// Rows are 100pt with 8pt gaps. `origins` folds each gap into the next
    /// edge, so row `i`'s extent here is `108i ..< 108(i+1)` — card plus gap.
    private func origins(count: Int = 40) -> [CGFloat] {
        HistoryListLayout.origins(heights: [CGFloat](repeating: rowHeight, count: count))
    }

    private func reveal(_ index: Int, offset: CGFloat) -> CGFloat? {
        HistoryListLayout.offsetToReveal(
            index: index,
            origins: origins(),
            offset: offset,
            viewportHeight: viewport
        )
    }

    func testARowAlreadyOnScreenDoesNotScroll() {
        // At offset 0 the viewport covers 0-460, so rows 0-3 are fully inside.
        for index in 0...3 {
            XCTAssertNil(reveal(index, offset: 0), "row \(index) is visible and must not scroll")
        }
    }

    /// The point of the exercise: crossing several slot boundaries inside one
    /// screenful must not move the document at all.
    func testScrubbingAcrossAScreenfulOfCardsNeverScrolls() {
        var scrolls = 0
        for index in 0...3 where reveal(index, offset: 0) != nil { scrolls += 1 }
        XCTAssertEqual(scrolls, 0)
    }

    func testARowBelowTheFoldRisesJustEnough() {
        // Row 4 spans 432-540; the viewport ends at 460.
        let target = reveal(4, offset: 0)
        XCTAssertNotNil(target)
        // It comes to rest against the bottom edge, not at the top.
        XCTAssertEqual(target ?? 0, 540 + 24 - viewport, accuracy: 0.5)
        XCTAssertLessThan(target ?? .infinity, 432, "a jump to the top would be 432")
    }

    func testARowAboveTheFoldDropsJustEnough() {
        // Scrolled to 1000, row 4 (432-532) is above the viewport.
        let target = reveal(4, offset: 1_000)
        XCTAssertNotNil(target)
        XCTAssertEqual(target ?? 0, 432 - 24, accuracy: 0.5)
    }

    func testItNeverScrollsPastEitherEnd() {
        let all = origins()
        let content = HistoryListLayout.contentHeight(origins: all)
        for index in [0, 1, 20, 38] {
            for offset in stride(from: CGFloat(0), through: content, by: 97) {
                guard let target = HistoryListLayout.offsetToReveal(
                    index: index,
                    origins: all,
                    offset: offset,
                    viewportHeight: viewport
                ) else { continue }
                XCTAssertGreaterThanOrEqual(target, 0)
                XCTAssertLessThanOrEqual(target, max(0, content - viewport) + 0.5)
            }
        }
    }

    /// Whatever it returns, the row must actually be on screen afterwards —
    /// otherwise the next boundary asks again and the panel judders.
    func testRevealingAlwaysLandsTheRowOnScreen() {
        let all = origins()
        for index in 0..<39 {
            for offset in stride(from: CGFloat(0), through: 3_500, by: 211) {
                let target = HistoryListLayout.offsetToReveal(
                    index: index,
                    origins: all,
                    offset: offset,
                    viewportHeight: viewport
                ) ?? offset
                let overlapTop = max(all[index], target)
                let overlapBottom = min(all[index + 1], target + viewport)
                XCTAssertGreaterThan(
                    overlapBottom - overlapTop,
                    0,
                    "row \(index) still off screen from offset \(offset)"
                )
            }
        }
    }

    func testARowTallerThanTheViewportAlignsItsTop() {
        let tall = HistoryListLayout.origins(heights: [100, 900, 100])
        let target = HistoryListLayout.offsetToReveal(
            index: 1,
            origins: tall,
            offset: 0,
            viewportHeight: viewport
        )
        XCTAssertEqual(target ?? -1, 108, accuracy: 0.5)
    }

    func testASubPointCorrectionIsNotWorthARelayout() {
        let all = origins()
        // Row 4 resolves to 104; ask from a hair away.
        let target = HistoryListLayout.offsetToReveal(
            index: 4,
            origins: all,
            offset: 103.7,
            viewportHeight: viewport
        )
        XCTAssertNil(target)
    }
}
