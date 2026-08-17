@testable import AfterRayCapturePolicy
import XCTest

final class EdgeSnapshotPacingTests: XCTestCase {
    func testFiresOnceTheSettleWindowIsQuiet() {
        var pacing = EdgeSnapshotPacing()
        pacing.arm(atMs: 1_000)
        XCTAssertFalse(pacing.shouldFire(nowMs: 1_400), "still inside the settle window")
        XCTAssertTrue(pacing.shouldFire(nowMs: 1_500))
        XCTAssertFalse(pacing.isArmed, "a fired candidate is consumed")
    }

    func testNewInputReArmsTheSettleWindow() {
        var pacing = EdgeSnapshotPacing()
        pacing.arm(atMs: 1_000)
        pacing.observeInput(atMs: 1_400)
        XCTAssertFalse(pacing.shouldFire(nowMs: 1_500), "the interaction is still going")
        pacing.observeInput(atMs: 1_800)
        XCTAssertFalse(pacing.shouldFire(nowMs: 2_100))
        XCTAssertTrue(pacing.shouldFire(nowMs: 2_300))
    }

    func testInputWithoutACandidateNeverFires() {
        var pacing = EdgeSnapshotPacing()
        pacing.observeInput(atMs: 1_000)
        XCTAssertFalse(pacing.isArmed)
        XCTAssertFalse(pacing.shouldFire(nowMs: 10_000), "typing alone is not a scope change")
    }

    func testHoldsFiveSecondsBetweenWalks() {
        var pacing = EdgeSnapshotPacing()
        pacing.arm(atMs: 0)
        XCTAssertTrue(pacing.shouldFire(nowMs: 1_000))
        pacing.arm(atMs: 2_000)
        XCTAssertFalse(pacing.shouldFire(nowMs: 3_000), "inside the 5s floor")
        XCTAssertFalse(pacing.isArmed, "a refused candidate is dropped, not queued")
        pacing.arm(atMs: 6_000)
        XCTAssertTrue(pacing.shouldFire(nowMs: 6_500))
    }

    func testCapsSixWalksPerRollingMinute() {
        var pacing = EdgeSnapshotPacing()
        var fired = 0
        // A candidate every 5.5s for two minutes: the floor alone would allow
        // about eleven walks per minute, so the bucket is what bounds this.
        for step in 0..<22 {
            let at = Int64(step) * 5_500
            pacing.arm(atMs: at)
            if pacing.shouldFire(nowMs: at + EdgeSnapshotPacing.settleMs) {
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
            XCTAssertTrue(pacing.shouldFire(nowMs: at + 500), "walk \(step) is inside the bucket")
        }
        pacing.arm(atMs: 33_000)
        XCTAssertFalse(pacing.shouldFire(nowMs: 33_500), "six already spent in this minute")
        // The first walk (t=500) leaves the window at t=60_500.
        pacing.arm(atMs: 60_000)
        XCTAssertTrue(pacing.shouldFire(nowMs: 60_600))
    }
}
