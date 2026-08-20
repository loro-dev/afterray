import XCTest
@testable import AfterRayRecall

final class HistoryDocumentFollowTests: XCTestCase {
    /// The document follows on settle, not on every boundary the playhead
    /// crosses. A drag across a day crosses ~48 of them in a couple of
    /// seconds, and each one cost a panel rebuild and a `ScrollView`
    /// re-measure — frames lost to relayout while the main thread was
    /// otherwise idle.
    func testSlotChangeAloneDoesNotMoveTheDocument() {
        XCTAssertFalse(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 1,
                currentSlot: 2,
                settleRequested: false
            )
        )
    }

    func testMovementWithinSameSlotDoesNotRequestAnotherFollow() {
        XCTAssertFalse(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: 2,
                settleRequested: false
            )
        )
    }

    func testSettleMovesTheDocument() {
        XCTAssertTrue(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 1,
                currentSlot: 2,
                settleRequested: true
            )
        )
        XCTAssertTrue(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: 2,
                settleRequested: true
            )
        )
    }

    /// Nothing to scroll to — an idle gap has no card.
    func testSettleWithNoSlotDoesNothing() {
        XCTAssertFalse(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: nil,
                settleRequested: true
            )
        )
    }
}

final class HistoryLoadMoreTests: XCTestCase {
    func testOffsetFarFromTheEndIsNotNear() {
        XCTAssertFalse(
            HistoryLoadMore.isNearBottom(offset: 0, viewportHeight: 460, contentHeight: 2_000)
        )
    }

    func testOffsetNearTheEndPrefetches() {
        XCTAssertTrue(
            HistoryLoadMore.isNearBottom(offset: 1_200, viewportHeight: 460, contentHeight: 2_000)
        )
    }

    func testEmptyViewportNeverLoads() {
        XCTAssertFalse(
            HistoryLoadMore.isNearBottom(offset: 10, viewportHeight: 0, contentHeight: 400)
        )
    }

    func testShortContentFillsTheNextPage() {
        XCTAssertTrue(
            HistoryLoadMore.isNearBottom(offset: 0, viewportHeight: 460, contentHeight: 200)
        )
    }
}

/// The chip is computed from the layout model, because the headings it asks
/// about are above the fold and therefore not mounted. The model is exact up
/// there: a row already scrolled past has been measured.
final class HistoryStickyHeadingTests: XCTestCase {
    private let today = HistoryListItem.heading(
        dayStartMs: 2,
        label: "Today · Aug 19",
        isToday: true
    )
    private let yesterday = HistoryListItem.heading(
        dayStartMs: 1,
        label: "Tue · Aug 18",
        isToday: false
    )

    func testNoChipWhileTheInFlowHeadingIsOnScreen() {
        XCTAssertNil(
            HistoryStickyHeading.chip(items: [today], origins: [0, 28], offset: 0)
        )
    }

    func testChipIsTheHeadingThatJustLeftTheTop() {
        XCTAssertEqual(
            HistoryStickyHeading.chip(
                items: [today, yesterday],
                origins: [0, 36, 64],
                offset: 12
            )?.label,
            "Today · Aug 19"
        )
    }

    func testLaterDayReplacesTheChipOnceItScrollsOff() {
        XCTAssertEqual(
            HistoryStickyHeading.chip(
                items: [today, yesterday],
                origins: [0, 36, 64],
                offset: 40
            )?.label,
            "Tue · Aug 18"
        )
    }
}
