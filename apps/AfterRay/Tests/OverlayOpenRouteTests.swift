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

    func testHideParksLiveWhenReopenWouldGoLive() {
        XCTAssertTrue(OverlayOpenRoute.shouldParkLiveOnHide(hasSelectedSearch: false))
        XCTAssertFalse(OverlayOpenRoute.shouldParkLiveOnHide(hasSelectedSearch: true))
    }
}

final class OverlayPanelPlacementTests: XCTestCase {
    func testSameFrameIsAWarmOrderFront() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertFalse(OverlayPanelPlacement.needsMove(from: frame, to: frame))
    }

    func testMovingToAnotherScreenRequiresSetFrame() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(OverlayPanelPlacement.needsMove(from: laptop, to: external))
    }

    func testArrangementChangeMovesOriginOnly() {
        let before = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let after = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        XCTAssertTrue(OverlayPanelPlacement.needsMove(from: before, to: after))
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

final class ScreenshotUIProcessTests: XCTestCase {
    func testRecognisesTheScreenshotUIBundles() {
        XCTAssertTrue(ScreenshotUIProcess.isScreenshotApp("com.apple.screencaptureui"))
        XCTAssertTrue(ScreenshotUIProcess.isScreenshotApp("com.apple.screenshot.launcher"))
        XCTAssertTrue(ScreenshotUIProcess.isScreenshotApp("com.apple.Screenshot"))
        XCTAssertFalse(ScreenshotUIProcess.isScreenshotApp("com.apple.finder"))
        XCTAssertFalse(ScreenshotUIProcess.isScreenshotApp(nil))
    }

    func testResumesWhenTheLastScreenshotUIExits() {
        XCTAssertTrue(
            ScreenshotUIProcess.shouldResumeAfterTermination(
                bundleIdentifier: "com.apple.screencaptureui",
                processIdentifier: 11,
                running: [
                    (bundleIdentifier: "com.apple.screencaptureui", processIdentifier: 11),
                    (bundleIdentifier: "com.apple.finder", processIdentifier: 2),
                ]
            )
        )
    }

    func testStaysYieldedWhileAnotherScreenshotUIIsAlive() {
        XCTAssertFalse(
            ScreenshotUIProcess.shouldResumeAfterTermination(
                bundleIdentifier: "com.apple.screencaptureui",
                processIdentifier: 11,
                running: [
                    (bundleIdentifier: "com.apple.screenshot.launcher", processIdentifier: 12),
                ]
            )
        )
    }

    func testIgnoresUnrelatedTerminations() {
        XCTAssertFalse(
            ScreenshotUIProcess.shouldResumeAfterTermination(
                bundleIdentifier: "com.apple.finder",
                processIdentifier: 2,
                running: []
            )
        )
    }
}
