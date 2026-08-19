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
    func testTriggerBelowTheViewportIsNotNear() {
        XCTAssertFalse(HistoryLoadMore.isNearBottom(triggerMinY: 2_000, viewportHeight: 460))
    }

    func testTriggerEnteringTheLeadIsNear() {
        XCTAssertTrue(HistoryLoadMore.isNearBottom(triggerMinY: 700, viewportHeight: 460))
    }

    func testEmptyViewportNeverLoads() {
        XCTAssertFalse(HistoryLoadMore.isNearBottom(triggerMinY: 10, viewportHeight: 0))
    }
}

final class HistoryStickyHeadingTests: XCTestCase {
    func testNoChipWhileTheInFlowHeadingIsOnScreen() {
        let today = DayHeadingAnchor(
            dayStartMs: 1,
            label: "Today · Aug 19",
            isToday: true,
            minY: 8
        )
        XCTAssertNil(HistoryStickyHeading.chip(from: [today]))
    }

    func testChipIsTheHeadingThatJustLeftTheTop() {
        let today = DayHeadingAnchor(
            dayStartMs: 2,
            label: "Today · Aug 19",
            isToday: true,
            minY: -40
        )
        let yesterday = DayHeadingAnchor(
            dayStartMs: 1,
            label: "Tue · Aug 18",
            isToday: false,
            minY: 200
        )
        XCTAssertEqual(HistoryStickyHeading.chip(from: [today, yesterday])?.label, "Today · Aug 19")
    }

    func testLaterDayReplacesTheChipOnceItScrollsOff() {
        let today = DayHeadingAnchor(
            dayStartMs: 2,
            label: "Today · Aug 19",
            isToday: true,
            minY: -400
        )
        let yesterday = DayHeadingAnchor(
            dayStartMs: 1,
            label: "Tue · Aug 18",
            isToday: false,
            minY: -12
        )
        XCTAssertEqual(HistoryStickyHeading.chip(from: [today, yesterday])?.label, "Tue · Aug 18")
    }
}
