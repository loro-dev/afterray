import XCTest
@testable import AfterRayRecall

final class HistoryDocumentFollowTests: XCTestCase {
    func testSlotChangeRequestsImmediateFollow() {
        XCTAssertTrue(
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

    func testSettleRequestsFinalCorrectionWithinSameSlot() {
        XCTAssertTrue(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: 2,
                settleRequested: true
            )
        )
    }

    func testMissingCurrentSlotDoesNotRequestLiveFollow() {
        XCTAssertFalse(
            HistoryDocumentFollow.shouldFollow(
                previousSlot: 2,
                currentSlot: nil,
                settleRequested: false
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
            HistoryStickyHeading.chip(
                items: [today],
                origins: [0, 28],
                offset: 0
            )
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
