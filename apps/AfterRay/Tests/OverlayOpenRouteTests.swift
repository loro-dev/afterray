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

final class OverlayCloseKeyTests: XCTestCase {
    func testEscapeDismissesWhenOverlayIsKey() {
        XCTAssertTrue(
            OverlayCloseKey.shouldDismiss(
                keyCode: OverlayCloseKey.escapeKeyCode,
                isCommandW: false,
                overlayVisible: true,
                overlayIsKey: true,
                permissionGuideVisible: false
            )
        )
    }

    func testEscapeDoesNothingWhenOverlayIsHidden() {
        XCTAssertFalse(
            OverlayCloseKey.shouldDismiss(
                keyCode: OverlayCloseKey.escapeKeyCode,
                isCommandW: false,
                overlayVisible: false,
                overlayIsKey: false,
                permissionGuideVisible: false
            )
        )
    }

    func testEscapeDoesNotStealFromAStandardWindow() {
        XCTAssertFalse(
            OverlayCloseKey.shouldDismiss(
                keyCode: OverlayCloseKey.escapeKeyCode,
                isCommandW: false,
                overlayVisible: true,
                overlayIsKey: false,
                permissionGuideVisible: false
            )
        )
    }

    func testCommandWDismissesWhenOverlayIsKey() {
        XCTAssertTrue(
            OverlayCloseKey.shouldDismiss(
                keyCode: 13,
                isCommandW: true,
                overlayVisible: true,
                overlayIsKey: true,
                permissionGuideVisible: false
            )
        )
    }

    func testEscapeDismissesThePermissionGuide() {
        XCTAssertTrue(
            OverlayCloseKey.shouldDismiss(
                keyCode: OverlayCloseKey.escapeKeyCode,
                isCommandW: false,
                overlayVisible: false,
                overlayIsKey: false,
                permissionGuideVisible: true
            )
        )
    }
}
