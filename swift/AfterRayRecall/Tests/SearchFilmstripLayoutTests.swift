import XCTest
@testable import AfterRayRecall

final class SearchFilmstripLayoutTests: XCTestCase {
    private let stride = SearchFilmstripLayout.cellWidth + SearchFilmstripLayout.cellGap

    func testCellsAreEvenlySpacedWithGaps() {
        let layout = SearchFilmstripLayout(count: 3, viewportWidth: 600)
        XCTAssertEqual(layout.centerX(index: 0), SearchFilmstripLayout.cellWidth / 2)
        XCTAssertEqual(
            layout.centerX(index: 1) - layout.centerX(index: 0),
            stride,
            accuracy: 0.001
        )
        XCTAssertEqual(
            layout.contentWidth,
            3 * SearchFilmstripLayout.cellWidth + 2 * SearchFilmstripLayout.cellGap,
            accuracy: 0.001
        )
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
        XCTAssertEqual(layout.index(atX: 0), 0)
        XCTAssertEqual(layout.index(atX: SearchFilmstripLayout.cellWidth / 2), 0)
        XCTAssertEqual(layout.index(atX: stride), 1)
        XCTAssertEqual(layout.index(atX: stride * 2 + 5), 2)
        XCTAssertEqual(layout.index(atX: -500), 0)
        XCTAssertEqual(layout.index(atX: 99_999), 3)
    }

    func testEmptyStripStaysWellDefined() {
        let layout = SearchFilmstripLayout(count: 0, viewportWidth: 600)
        XCTAssertEqual(layout.index(atX: 42), 0)
        XCTAssertGreaterThan(layout.contentWidth, 0)
    }

    func testDraggingLeftWalksTowardOlderResults() {
        let layout = SearchFilmstripLayout(count: 10, viewportWidth: 600)
        // Older results sit to the right, so pulling content left advances.
        XCTAssertEqual(layout.steps(forDragTranslation: -stride), 1)
        XCTAssertEqual(layout.steps(forDragTranslation: -stride * 3), 3)
        XCTAssertEqual(layout.steps(forDragTranslation: stride * 2), -2)
        XCTAssertEqual(layout.steps(forDragTranslation: 0), 0)
        // A twitch smaller than half a cell must not move the selection.
        XCTAssertEqual(layout.steps(forDragTranslation: -stride * 0.3), 0)
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
