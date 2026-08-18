import AfterRayRecall
import XCTest
@testable import AfterRayApp

final class OverlayOpenRouteTests: XCTestCase {
    func testExplicitHistoryNavigationWinsOverNowAndExistingSearch() {
        let slot = DaySlotSummary(
            slotStartMs: 600_000,
            slotEndMs: 1_200_000,
            state: "done",
            anchorMomentId: "anchor",
            facts: DaySlotFacts(apps: [])
        )
        XCTAssertEqual(
            OverlayOpenRoute.resolve(intent: .summary(slot), hasSelectedSearch: true),
            .summary(slot)
        )
    }

    func testMomentCitationWinsOverExistingSearch() {
        XCTAssertEqual(
            OverlayOpenRoute.resolve(intent: .moment("m1"), hasSelectedSearch: true),
            .moment("m1")
        )
    }

    func testEmptyIntentFallsBackToSelectedSearch() {
        XCTAssertEqual(
            OverlayOpenRoute.resolve(intent: nil, hasSelectedSearch: true),
            .selectedSearch
        )
    }
}
