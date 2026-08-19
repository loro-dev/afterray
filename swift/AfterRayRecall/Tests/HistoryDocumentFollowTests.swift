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
