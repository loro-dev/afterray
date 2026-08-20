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
