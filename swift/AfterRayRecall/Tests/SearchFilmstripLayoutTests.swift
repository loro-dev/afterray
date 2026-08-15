import XCTest
@testable import AfterRayRecall

final class SearchFilmstripLayoutTests: XCTestCase {
    private let stride = SearchFilmstripLayout.cellWidth + SearchFilmstripLayout.cellGap

    func testCellsAreEvenlySpacedWithGaps() {
        let layout = SearchFilmstripLayout(count: 3, viewportWidth: 600)
        // Newest first in the ranking, last on the strip: time reads left to
        // right here exactly as it does on the app timeline.
        XCTAssertEqual(
            layout.centerX(index: 0),
            2 * stride + SearchFilmstripLayout.cellWidth / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(layout.centerX(index: 2), SearchFilmstripLayout.cellWidth / 2)
        XCTAssertEqual(
            layout.centerX(index: 0) - layout.centerX(index: 1),
            stride,
            accuracy: 0.001
        )
        XCTAssertEqual(
            layout.contentWidth,
            3 * SearchFilmstripLayout.cellWidth + 2 * SearchFilmstripLayout.cellGap,
            accuracy: 0.001
        )
    }

    func testTheNewestResultOpensAtTheRightHandEnd() {
        let layout = SearchFilmstripLayout(count: 8, viewportWidth: 600)
        // A fresh session selects index 0, and that cell must be the last one.
        XCTAssertEqual(layout.slot(forIndex: 0), 7)
        XCTAssertEqual(layout.slot(forIndex: 7), 0)
        XCTAssertGreaterThan(layout.centerX(index: 0), layout.centerX(index: 1))
    }

    func testOnlyTheCellsNearTheViewportAreBuilt() {
        let layout = SearchFilmstripLayout(count: 60, viewportWidth: 600)
        let visible = layout.visibleIndices(around: 30)
        // 600 points of viewport is roughly four cells: a window, not the set.
        XCTAssertLessThan(visible.count, 12)
        XCTAssertTrue(visible.contains(30))
        XCTAssertFalse(visible.contains(0))
        XCTAssertFalse(visible.contains(59))
        // The ends of the strip clamp instead of running off the array.
        XCTAssertEqual(layout.visibleIndices(around: 0).lowerBound, 0)
        XCTAssertEqual(layout.visibleIndices(around: 59).upperBound, 60)
        XCTAssertTrue(SearchFilmstripLayout(count: 0, viewportWidth: 600)
            .visibleIndices(around: 0).isEmpty)
    }

    func testOffsetParksTheSelectedCellUnderTheCentredPlayhead() {
        let layout = SearchFilmstripLayout(count: 5, viewportWidth: 600)
        for index in 0..<5 {
            let centreAfterOffset = layout.centerX(index: index) + layout.offset(forIndex: index)
            XCTAssertEqual(centreAfterOffset, 300, accuracy: 0.001)
        }
    }

    func testIndexAtXRoundsToTheNearestCellAndClamps() {
        let layout = SearchFilmstripLayout(count: 4, viewportWidth: 600)
        // x grows to the right, where the newer — lower-ranked — results are.
        XCTAssertEqual(layout.index(atX: 0), 3)
        XCTAssertEqual(layout.index(atX: SearchFilmstripLayout.cellWidth / 2), 3)
        XCTAssertEqual(layout.index(atX: stride), 2)
        XCTAssertEqual(layout.index(atX: stride * 2 + 5), 1)
        XCTAssertEqual(layout.index(atX: -500), 3)
        XCTAssertEqual(layout.index(atX: 99_999), 0)
    }

    func testEmptyStripStaysWellDefined() {
        let layout = SearchFilmstripLayout(count: 0, viewportWidth: 600)
        XCTAssertEqual(layout.index(atX: 42), 0)
        XCTAssertGreaterThan(layout.contentWidth, 0)
    }

    func testDraggingRightWalksTowardOlderResults() {
        let layout = SearchFilmstripLayout(count: 10, viewportWidth: 600)
        // Older results sit to the left, so pulling the content right — the
        // same drag that travels backwards on the timeline — advances the rank.
        XCTAssertEqual(layout.steps(forDragTranslation: stride), 1)
        XCTAssertEqual(layout.steps(forDragTranslation: stride * 3), 3)
        XCTAssertEqual(layout.steps(forDragTranslation: -stride * 2), -2)
        XCTAssertEqual(layout.steps(forDragTranslation: 0), 0)
        // A twitch smaller than half a cell must not move the selection.
        XCTAssertEqual(layout.steps(forDragTranslation: stride * 0.3), 0)
    }
}

final class RelativeStampTests: XCTestCase {
    private let now: Int64 = 1_000_000_000_000

    private func stamp(agoMs: Int64) -> String {
        RelativeStamp.short(fromMs: now - agoMs, nowMs: now)
    }

    func testUsesTheCoarsestUnitThatStillReads() {
        XCTAssertEqual(stamp(agoMs: 0), "NOW")
        XCTAssertEqual(stamp(agoMs: 59_000), "NOW")
        XCTAssertEqual(stamp(agoMs: 60_000), "1M")
        XCTAssertEqual(stamp(agoMs: 59 * 60_000), "59M")
        XCTAssertEqual(stamp(agoMs: 60 * 60_000), "1H")
        XCTAssertEqual(stamp(agoMs: 23 * 3_600_000), "23H")
        XCTAssertEqual(stamp(agoMs: 24 * 3_600_000), "1D")
        XCTAssertEqual(stamp(agoMs: 6 * 86_400_000), "6D")
        XCTAssertEqual(stamp(agoMs: 7 * 86_400_000), "1W")
        XCTAssertEqual(stamp(agoMs: 52 * 7 * 86_400_000), "1Y")
    }

    func testClockSkewDoesNotProduceNegativeStamps() {
        XCTAssertEqual(RelativeStamp.short(fromMs: now + 60_000, nowMs: now), "NOW")
    }
}
