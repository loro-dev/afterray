@testable import AfterRayCapturePolicy
import XCTest

final class EdgeSnapshotPacingTests: XCTestCase {
    func testFiresOnceTheSettleWindowIsQuiet() {
        var pacing = EdgeSnapshotPacing()
        pacing.arm(atMs: 1_000)
        XCTAssertFalse(pacing.fire(nowMs: 1_400) { true }, "still inside the settle window")
        XCTAssertTrue(pacing.fire(nowMs: 1_500) { true })
        XCTAssertFalse(pacing.isArmed, "a fired candidate is consumed")
    }

    func testNewInputReArmsTheSettleWindow() {
        var pacing = EdgeSnapshotPacing()
        pacing.arm(atMs: 1_000)
        pacing.observeInput(atMs: 1_400)
        XCTAssertFalse(pacing.fire(nowMs: 1_500) { true }, "the interaction is still going")
        pacing.observeInput(atMs: 1_800)
        XCTAssertFalse(pacing.fire(nowMs: 2_100) { true })
        XCTAssertTrue(pacing.fire(nowMs: 2_300) { true })
    }

    func testInputWithoutACandidateNeverFires() {
        var pacing = EdgeSnapshotPacing()
        pacing.observeInput(atMs: 1_000)
        XCTAssertFalse(pacing.isArmed)
        XCTAssertFalse(pacing.fire(nowMs: 10_000) { true }, "typing alone is not a scope change")
    }

    func testHoldsFiveSecondsBetweenWalks() {
        var pacing = EdgeSnapshotPacing()
        pacing.arm(atMs: 0)
        XCTAssertTrue(pacing.fire(nowMs: 1_000) { true })
        pacing.arm(atMs: 2_000)
        XCTAssertFalse(pacing.fire(nowMs: 3_000) { true }, "inside the 5s floor")
        XCTAssertFalse(pacing.isArmed, "a refused candidate is dropped, not queued")
        pacing.arm(atMs: 6_000)
        XCTAssertTrue(pacing.fire(nowMs: 6_500) { true })
    }

    func testCapsSixWalksPerRollingMinute() {
        var pacing = EdgeSnapshotPacing()
        var fired = 0
        // A candidate every 5.5s for two minutes: the floor alone would allow
        // about eleven walks per minute, so the bucket is what bounds this.
        for step in 0..<22 {
            let at = Int64(step) * 5_500
            pacing.arm(atMs: at)
            if pacing.fire(nowMs: at + EdgeSnapshotPacing.settleMs) { true } {
                fired += 1
            }
        }
        XCTAssertEqual(fired, 12, "six per minute across two minutes")
    }

    func testTheWindowRollsRatherThanResetting() {
        var pacing = EdgeSnapshotPacing()
        for step in 0..<6 {
            let at = Int64(step) * 5_500
            pacing.arm(atMs: at)
            XCTAssertTrue(pacing.fire(nowMs: at + 500) { true }, "walk \(step) is inside the bucket")
        }
        pacing.arm(atMs: 33_000)
        XCTAssertFalse(pacing.fire(nowMs: 33_500) { true }, "six already spent in this minute")
        // The first walk (t=500) leaves the window at t=60_500.
        pacing.arm(atMs: 60_000)
        XCTAssertTrue(pacing.fire(nowMs: 60_600) { true })
    }

    /// A candidate the walk declines — a browser, an excluded app, a window
    /// that will not resolve — must not spend the minute's allowance, or one
    /// app the shim never snapshots would starve every app it does.
    func testADeclinedWalkDoesNotSpendTheBudget() {
        var pacing = EdgeSnapshotPacing()
        for index in 0..<20 {
            let now = Int64(index) * 6_000
            pacing.arm(atMs: now - EdgeSnapshotPacing.settleMs)
            XCTAssertFalse(
                pacing.fire(nowMs: now) { false },
                "a walk that did not happen reports no fire"
            )
        }
        // Twenty refusals later the budget is untouched.
        pacing.arm(atMs: 200_000)
        XCTAssertTrue(pacing.fire(nowMs: 200_000 + EdgeSnapshotPacing.settleMs) { true })
    }
}

/// Decision 4: a typing burst must not be attributed to a landing point so
/// coarse that it drags the run's engaged scope up to the whole window.
final class TypingTargetTests: XCTestCase {
    func testSpecificFocusIsUsedEvenWithAFreshClick() {
        XCTAssertEqual(
            TypingTarget.choose(focusedRole: "AXTextArea", lastClickAgeMs: 10),
            .focus
        )
    }

    /// The measured Electron and Zed cases — the ones this rule exists for.
    func testCoarseFocusFallsBackToTheLastClick() {
        for coarse in ["AXWebArea", "AXWindow", "AXGroup", "AXScrollArea"] {
            XCTAssertEqual(
                TypingTarget.choose(focusedRole: coarse, lastClickAgeMs: 5_000),
                .lastClick,
                "\(coarse) is the app declining to say where the caret is"
            )
        }
    }

    func testNoFocusAtAllFallsBackToTheLastClick() {
        XCTAssertEqual(TypingTarget.choose(focusedRole: nil, lastClickAgeMs: 0), .lastClick)
    }

    /// A stale click describes a caret that has since moved; reporting the
    /// coarse focus honestly is better than asserting a wrong scope.
    func testAStaleClickIsNotUsed() {
        XCTAssertEqual(
            TypingTarget.choose(
                focusedRole: "AXWebArea",
                lastClickAgeMs: TypingTarget.lastClickMaxAgeMs + 1
            ),
            .focus
        )
        XCTAssertEqual(
            TypingTarget.choose(
                focusedRole: "AXWebArea",
                lastClickAgeMs: TypingTarget.lastClickMaxAgeMs
            ),
            .lastClick,
            "the boundary itself is still fresh"
        )
    }

    func testKeyboardOnlyUserWithNoClickKeepsFocus() {
        XCTAssertEqual(TypingTarget.choose(focusedRole: "AXWebArea", lastClickAgeMs: nil), .focus)
    }
}
