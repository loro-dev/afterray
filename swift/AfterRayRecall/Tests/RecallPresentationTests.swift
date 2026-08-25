import XCTest
@testable import AfterRayRecall

final class RecallPresentationTests: XCTestCase {
    func testTransientLiveStateRemovesHistoryBackdropBeforeBindingSettles() {
        XCTAssertTrue(RecallPresentation.isLive(committed: false, transient: true))
        XCTAssertFalse(
            RecallPresentation.showsHistoryBackdrop(committed: false, transient: true)
        )
    }

    func testTransientHistoryStateKeepsBackdropWhileLeavingNow() {
        XCTAssertFalse(RecallPresentation.isLive(committed: true, transient: false))
        XCTAssertTrue(
            RecallPresentation.showsHistoryBackdrop(committed: true, transient: false)
        )
    }

    func testSettledStateIsUsedOutsideScrubbing() {
        XCTAssertTrue(RecallPresentation.isLive(committed: true, transient: nil))
        XCTAssertFalse(RecallPresentation.isLive(committed: false, transient: nil))
    }

    func testHydratedSelectionSuppliesTranscriptWithoutPlayback() throws {
        let lean = RecallMoment(
            id: "moment-1",
            sessionId: "session-1",
            capturedAtMs: 1_000,
            audioSegmentId: "segment-1",
            audioArtifactId: "audio-1",
            audioStartedAtMs: 0,
            audioEndedAtMs: 10_000
        )
        let hydrated = RecallMoment(
            id: "moment-1",
            sessionId: "session-1",
            capturedAtMs: 1_000,
            transcriptText: "Visible while paused.",
            audioSegmentId: "segment-1",
            audioArtifactId: "audio-1",
            audioStartedAtMs: 0,
            audioEndedAtMs: 10_000
        )

        let presented = try XCTUnwrap(
            RecallSelectionPresentation.resolve(
                playheadMs: 1_000,
                moments: [lean],
                hydratedSelection: hydrated
            )
        )

        XCTAssertEqual(presented.transcriptText, "Visible while paused.")
    }

    func testStaleHydratedSelectionIsNotShownOnAnotherFrame() throws {
        let current = RecallMoment(
            id: "moment-2",
            sessionId: "session-1",
            capturedAtMs: 2_000
        )
        let stale = RecallMoment(
            id: "moment-1",
            sessionId: "session-1",
            capturedAtMs: 1_000,
            transcriptText: "Old words"
        )

        let presented = try XCTUnwrap(
            RecallSelectionPresentation.resolve(
                playheadMs: 2_000,
                moments: [current],
                hydratedSelection: stale
            )
        )

        XCTAssertEqual(presented.id, "moment-2")
        XCTAssertNil(presented.transcriptText)
    }

    func testSearchSelectionQuietKeyStaysStableAcrossGestureFrames() {
        let first = RecallSelectionQuietTaskKey.make(
            timelineTravelOrigin: .user,
            isScrubbing: true,
            searchSelectedIndex: 1,
            searchSelectedMomentID: "cold-1",
            selectedMomentID: "warm-moment",
            playheadDayKey: "2026-08-24"
        )
        let later = RecallSelectionQuietTaskKey.make(
            timelineTravelOrigin: .user,
            isScrubbing: true,
            searchSelectedIndex: 37,
            searchSelectedMomentID: "cold-37",
            selectedMomentID: "same-warm-moment",
            playheadDayKey: "2026-08-24"
        )

        XCTAssertEqual(first, later)
        XCTAssertEqual(first, "scrubbing")
    }

    func testSettledColdSearchSelectionGetsItsOwnLoadKey() {
        let first = RecallSelectionQuietTaskKey.make(
            timelineTravelOrigin: nil,
            isScrubbing: false,
            searchSelectedIndex: 1,
            searchSelectedMomentID: "cold-1",
            selectedMomentID: "unchanged-warm-moment",
            playheadDayKey: "2026-08-24"
        )
        let final = RecallSelectionQuietTaskKey.make(
            timelineTravelOrigin: nil,
            isScrubbing: false,
            searchSelectedIndex: 37,
            searchSelectedMomentID: "cold-37",
            selectedMomentID: "unchanged-warm-moment",
            playheadDayKey: "2026-08-24"
        )

        XCTAssertNotEqual(first, final)
        XCTAssertEqual(final, "search|37|cold-37")
    }

    func testNewSearchAtTheSameIndexGetsANewLoadKey() {
        let firstQuery = RecallSelectionQuietTaskKey.make(
            timelineTravelOrigin: nil,
            isScrubbing: false,
            searchSelectedIndex: 0,
            searchSelectedMomentID: "first-query-result",
            selectedMomentID: "old-canvas",
            playheadDayKey: "2026-08-24"
        )
        let nextQuery = RecallSelectionQuietTaskKey.make(
            timelineTravelOrigin: nil,
            isScrubbing: false,
            searchSelectedIndex: 0,
            searchSelectedMomentID: "next-query-result",
            selectedMomentID: "old-canvas",
            playheadDayKey: "2026-08-24"
        )

        XCTAssertNotEqual(firstQuery, nextQuery)
    }
}
