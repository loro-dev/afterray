import XCTest
@testable import AfterRayRecall

final class AudioTimelineFollowTests: XCTestCase {
    func testUserTravelInvalidatesAudioButPlaybackTravelDoesNot() {
        XCTAssertTrue(RecallTimelineTravelPolicy.invalidatesAudio(.user))
        XCTAssertFalse(RecallTimelineTravelPolicy.invalidatesAudio(.audioPlayback))
    }

    func testPlaybackClockResolvesTheLastCaptureAtOrBeforeIt() {
        let moments = [
            moment(id: "m1", capturedAtMs: 1_000),
            moment(id: "m2", capturedAtMs: 2_000),
            moment(id: "m3", capturedAtMs: 4_000),
        ]
        let target = AudioTimelineFollow.target(
            for: position(timelineMs: 3_500),
            moments: moments
        )

        XCTAssertEqual(target?.moment.id, "m2")
        XCTAssertEqual(target?.nextBoundaryMs, 4_000)
    }

    func testPlaybackFollowNeverCrossesIntoAnotherCaptureSession() {
        let moments = [
            moment(id: "m1", capturedAtMs: 1_000),
            moment(id: "other", sessionID: "s2", capturedAtMs: 2_000),
        ]

        XCTAssertNil(
            AudioTimelineFollow.target(
                for: position(timelineMs: 2_100),
                moments: moments
            )
        )
    }

    func testPlaybackFollowDoesNotHoldAFrameAcrossAnIdleGap() {
        let moments = [
            moment(id: "m1", capturedAtMs: 1_000),
            moment(
                id: "m2",
                capturedAtMs: 1_000 + TimelineLayout.idleGapThresholdMs + 5_000
            ),
        ]
        let beyondFrameLifetime = 1_000 + TimelineLayout.captureIntervalMs + 1

        XCTAssertNil(
            AudioTimelineFollow.target(
                for: position(timelineMs: beyondFrameLifetime),
                moments: moments
            )
        )
    }

    func testNextCheckTargetsBoundaryButRemainsCancellationResponsive() {
        let target = AudioTimelineFollowTarget(
            moment: moment(id: "m1", capturedAtMs: 1_000),
            nextBoundaryMs: 2_000
        )
        XCTAssertEqual(
            AudioTimelineFollow.nextCheckInterval(
                position: position(timelineMs: 1_900),
                target: target
            ),
            0.1,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            AudioTimelineFollow.nextCheckInterval(
                position: position(timelineMs: 1_000),
                target: target
            ),
            AudioTimelineFollow.maximumCheckInterval,
            accuracy: 0.000_1
        )
    }

    private func position(timelineMs: Int64) -> AudioTimelinePlaybackPosition {
        AudioTimelinePlaybackPosition(
            sourceMomentID: "m1",
            sourceSessionID: "s1",
            sourceCapturedAtMs: 1_000,
            timelineMs: timelineMs
        )
    }

    private func moment(
        id: String,
        sessionID: String = "s1",
        capturedAtMs: Int64
    ) -> RecallMoment {
        RecallMoment(
            id: id,
            sessionId: sessionID,
            capturedAtMs: capturedAtMs,
            imageArtifactId: "image-\(id)"
        )
    }
}
