import XCTest
@testable import AfterRayRecall

final class SensitiveAudioDataTests: XCTestCase {
    func testClearOverwritesTheOwnedDecryptedBytes() {
        let data = SensitiveAudioData(copying: Data([0x01, 0x7f, 0xff]))

        data.clear()

        XCTAssertTrue(data.isCleared)
        XCTAssertTrue(data.isZeroed)
    }
}

final class ArtifactAudioPlaybackSessionTests: XCTestCase {
    func testCompletedLoadAfterStopDoesNotEnterPlaying() {
        var session = ArtifactAudioPlaybackSession()
        let source = playbackSource()
        let generation = session.beginPlay(source: source)

        XCTAssertTrue(session.isBuffering)
        XCTAssertEqual(session.artifactID, "audio-1")
        XCTAssertEqual(session.momentID, "moment-1")
        XCTAssertFalse(session.isPlaying)

        session.stop()

        XCTAssertFalse(session.isBuffering)
        XCTAssertFalse(session.isPlaying)
        XCTAssertNil(session.artifactID)
        XCTAssertNotEqual(session.generation, generation)
        XCTAssertFalse(session.finishLoad(generation: generation))
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isBuffering)
    }

    func testToggleWhileBufferingCancelsAndIgnoresLateLoad() {
        var session = ArtifactAudioPlaybackSession()
        let source = playbackSource()
        let generation = session.beginPlay(source: source)

        XCTAssertTrue(session.cancelIfBuffering(source: source))
        XCTAssertFalse(session.isBuffering)
        XCTAssertFalse(session.isPlaying)
        XCTAssertNil(session.artifactID)
        XCTAssertFalse(session.finishLoad(generation: generation))
        XCTAssertFalse(session.isPlaying)
    }

    func testCancelIfBufferingIgnoresADifferentArtifact() {
        var session = ArtifactAudioPlaybackSession()
        let source = playbackSource()
        let generation = session.beginPlay(source: source)

        XCTAssertFalse(
            session.cancelIfBuffering(
                source: playbackSource(momentID: "moment-2", artifactID: "audio-2")
            )
        )
        XCTAssertTrue(session.isBuffering)
        XCTAssertEqual(session.artifactID, "audio-1")
        XCTAssertTrue(session.finishLoad(generation: generation))
        XCTAssertTrue(session.isPlaying)
    }

    func testFailLoadAfterCancelIsIgnored() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(source: playbackSource())
        session.stop()
        session.failLoad(generation: generation)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isBuffering)
        XCTAssertNil(session.artifactID)
    }

    func testToggleOnlyPausesAndResumesTheSameMomentSource() {
        var session = ArtifactAudioPlaybackSession()
        let source = playbackSource()
        let generation = session.beginPlay(source: source)
        XCTAssertTrue(session.finishLoad(generation: generation))

        XCTAssertEqual(
            session.toggleDecision(source: source, hasPlayer: true),
            .pause
        )
        XCTAssertEqual(
            session.toggleDecision(
                source: playbackSource(momentID: "moment-2", offset: 7),
                hasPlayer: true
            ),
            .loadAndPlay
        )

        session.pause()
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(
            session.toggleDecision(source: source, hasPlayer: true),
            .resume
        )
        XCTAssertEqual(
            session.toggleDecision(
                source: playbackSource(momentID: "moment-2", artifactID: "other"),
                hasPlayer: true
            ),
            .loadAndPlay
        )

        session.resume()
        XCTAssertTrue(session.isPlaying)
    }

    func testToggleWhileBufferingCancelsViaDecision() {
        var session = ArtifactAudioPlaybackSession()
        let source = playbackSource()
        _ = session.beginPlay(source: source)
        XCTAssertEqual(
            session.toggleDecision(source: source, hasPlayer: false),
            .cancelBuffering
        )
    }

    func testToggleWithoutAPlayerReloads() {
        var session = ArtifactAudioPlaybackSession()
        let source = playbackSource()
        let generation = session.beginPlay(source: source)
        XCTAssertTrue(session.finishLoad(generation: generation))
        session.pause()
        XCTAssertEqual(
            session.toggleDecision(source: source, hasPlayer: false),
            .loadAndPlay
        )
    }

    private func playbackSource(
        momentID: String = "moment-1",
        artifactID: String = "audio-1",
        offset: TimeInterval = 0
    ) -> ArtifactAudioPlaybackSource {
        ArtifactAudioPlaybackSource(
            momentID: momentID,
            artifactID: artifactID,
            offset: offset
        )
    }
}

@MainActor
final class ArtifactAudioPlayerTests: XCTestCase {
    func testRepositoryPreparesAndDiscardsSensitiveAudio() async throws {
        let repository = RecallAudioRepository(
            daemon: DelayedArtifactDaemon(delayMs: 0, bytes: silentWav())
        )

        let prepared = try await repository.preparedAudio(artifactID: "audio-1")
        XCTAssertFalse(prepared.sensitiveData.isCleared)

        await repository.discard(prepared)
        XCTAssertTrue(prepared.sensitiveData.isCleared)
        XCTAssertTrue(prepared.sensitiveData.isZeroed)
    }

    func testOffsetUsesAudioStartedAtMsAndClampsBelowZero() {
        XCTAssertEqual(
            ArtifactAudioPlayer.offset(for: moment(capturedAtMs: 2_500, startedAtMs: 1_000)),
            1.5,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ArtifactAudioPlayer.offset(for: moment(capturedAtMs: 500, startedAtMs: 1_000)),
            0,
            accuracy: 0.000_1
        )
        XCTAssertEqual(
            ArtifactAudioPlayer.offset(for: moment(capturedAtMs: 2_500, startedAtMs: nil)),
            0,
            accuracy: 0.000_1
        )
    }

    func testStopDuringLoadDoesNotStartPlayback() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 80)
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let target = moment(capturedAtMs: 2_500, startedAtMs: 1_000, audioID: "audio-1")

        player.play(moment: target)
        XCTAssertTrue(player.isBuffering)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
        let generation = player.generation

        player.stop()
        XCTAssertFalse(player.isBuffering)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingArtifactID)
        XCTAssertNotEqual(player.generation, generation)

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertNil(player.playingArtifactID)
    }

    func testToggleWhileLoadingCancelsAndDoesNotPlay() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 80)
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let target = moment(capturedAtMs: 2_500, startedAtMs: 1_000, audioID: "audio-1")

        player.toggle(moment: target)
        XCTAssertTrue(player.isBuffering)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
        let generation = player.generation

        player.toggle(moment: target)
        XCTAssertFalse(player.isBuffering)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.playingArtifactID)
        XCTAssertNotEqual(player.generation, generation)

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertNil(player.playingArtifactID)
    }

    func testToggleAfterPauseResumesWithoutReloading() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav())
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let target = moment(capturedAtMs: 1_000, startedAtMs: 1_000, audioID: "audio-1")

        player.play(moment: target)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
        XCTAssertEqual(player.playingMomentID, "m1")
        let generation = player.generation

        player.pause()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isBuffering)
        XCTAssertEqual(player.playingArtifactID, "audio-1")

        player.toggle(moment: target)
        XCTAssertEqual(player.generation, generation)
        XCTAssertFalse(player.isBuffering)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
    }

    func testDifferentMomentInSameArtifactReloadsAtTheNewOffset() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav(duration: 10))
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let start = moment(
            id: "m1",
            capturedAtMs: 1_000,
            startedAtMs: 1_000,
            audioID: "audio-1"
        )
        let later = moment(
            id: "m2",
            capturedAtMs: 8_000,
            startedAtMs: 1_000,
            audioID: "audio-1"
        )

        player.play(moment: start)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        let generation = player.generation

        player.toggle(moment: later)
        XCTAssertTrue(player.isBuffering)
        XCTAssertGreaterThan(player.generation, generation)
        XCTAssertEqual(player.playingMomentID, "m2")
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        XCTAssertGreaterThanOrEqual(player.playbackTime, 6.9)
    }

    func testAutomaticFollowKeepsTheOriginalPlaybackSourceForPauseResume() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav(duration: 10))
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let source = moment(
            id: "m1",
            capturedAtMs: 1_000,
            startedAtMs: 1_000,
            audioID: "audio-1"
        )
        let followedFrame = moment(
            id: "m2",
            capturedAtMs: 3_000,
            startedAtMs: 1_000,
            audioID: "audio-1"
        )

        player.play(moment: source)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        let generation = player.generation

        player.followTimeline(to: followedFrame)
        XCTAssertEqual(player.playbackContext?.sourceMomentID, "m1")
        XCTAssertEqual(player.playbackContext?.followedMomentID, "m2")
        XCTAssertEqual(player.playbackContext?.segmentID, "segment-audio-1")
        XCTAssertEqual(player.playbackContext?.segmentDuration, 60)

        player.toggle(moment: followedFrame)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.generation, generation)

        player.toggle(moment: followedFrame)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.generation, generation)
        XCTAssertEqual(player.playbackContext?.sourceMomentID, "m1")
    }

    func testDetailHydrationRefinesEvidenceWithoutReplacingPlayback() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav(duration: 10))
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let source = moment(
            id: "m1",
            capturedAtMs: 1_000,
            startedAtMs: 1_000,
            audioID: "audio-1"
        )
        player.play(moment: source)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        let generation = player.generation

        let cue = RecallTranscriptCue(
            ordinal: 0,
            text: "Aligned words.",
            startOffsetMs: 0,
            endOffsetMs: 2_000,
            timingKind: .aligned
        )
        player.updateEvidence(from: moment(
            id: "m2",
            capturedAtMs: 2_000,
            startedAtMs: 1_000,
            audioID: "audio-1",
            transcriptText: "Aligned words.",
            transcriptCues: [cue]
        ))

        XCTAssertEqual(player.generation, generation)
        XCTAssertEqual(player.playbackContext?.sourceMomentID, "m1")
        XCTAssertEqual(player.playbackContext?.transcriptText, "Aligned words.")
        XCTAssertEqual(player.playbackContext?.transcriptCues, [cue])
    }

    func testStaleDetailHydrationCannotRefineANewerPlaybackGeneration() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav(duration: 10))
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let source = moment(
            id: "m1",
            capturedAtMs: 1_000,
            startedAtMs: 1_000,
            audioID: "audio-1"
        )
        player.play(moment: source)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        let staleGeneration = player.generation

        player.stop()
        player.play(moment: source)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        player.updateEvidence(
            from: moment(
                id: "m1",
                capturedAtMs: 1_000,
                startedAtMs: 1_000,
                audioID: "audio-1",
                transcriptText: "Stale words."
            ),
            generation: staleGeneration
        )

        XCTAssertNotEqual(player.generation, staleGeneration)
        XCTAssertNil(player.playbackContext?.transcriptText)
    }

    func testRepeatedPausePlayStaysOnTheSameSession() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav())
        let player = ArtifactAudioPlayer(repository: RecallAudioRepository(daemon: daemon))
        let target = moment(capturedAtMs: 1_000, startedAtMs: 1_000, audioID: "audio-1")

        player.play(moment: target)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        let generation = player.generation

        for _ in 0..<4 {
            player.toggle(moment: target)
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isBuffering)
            player.toggle(moment: target)
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(player.isBuffering)
            XCTAssertEqual(player.generation, generation)
        }
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeoutMs: Int) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for audio player state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func moment(
        id: String = "m1",
        capturedAtMs: Int64,
        startedAtMs: Int64?,
        audioID: String = "audio-1",
        transcriptText: String? = nil,
        transcriptCues: [RecallTranscriptCue] = []
    ) -> RecallMoment {
        let segmentStartedAtMs = startedAtMs ?? capturedAtMs
        return RecallMoment(
            id: id,
            sessionId: "s1",
            capturedAtMs: capturedAtMs,
            imageArtifactId: "img-1",
            transcriptText: transcriptText,
            transcriptCues: transcriptCues,
            audioSegmentId: "segment-\(audioID)",
            audioArtifactId: audioID,
            audioStartedAtMs: segmentStartedAtMs,
            audioEndedAtMs: max(segmentStartedAtMs + 60_000, capturedAtMs + 1_000)
        )
    }
}

private actor DelayedArtifactDaemon: RecallDaemonServing {
    private let delayMs: Int
    private let bytes: Data

    init(delayMs: Int, bytes: Data = Data("audio".utf8)) {
        self.delayMs = delayMs
        self.bytes = bytes
    }

    func sessions() async throws -> [RecallSession] { [] }
    func timeline() async throws -> [RecallMoment] { [] }
    func timeline(sinceMs _: Int64) async throws -> [RecallMoment] { [] }
    func moments(sessionID _: String) async throws -> [RecallMoment] { [] }
    func recallWindow(sessionID _: String, centerMs _: Int64, limit _: Int) async throws -> [RecallMoment] { [] }
    func setFavorite(momentID _: String, favorite _: Bool) async throws {}

    func artifact(id: String) async throws -> ArtifactPayload {
        try await Task.sleep(for: .milliseconds(delayMs))
        return ArtifactPayload(id: id, contentType: "audio/wav", bytes: bytes)
    }
}

/// 16-bit PCM silence long enough for AVAudioPlayer to actually start.
private func silentWav(duration: TimeInterval = 1.0, sampleRate: Int = 8_000) -> Data {
    let samples = max(Int(duration * Double(sampleRate)), 1)
    let dataSize = samples * 2
    var data = Data()
    data.reserveCapacity(44 + dataSize)
    func appendASCII(_ value: String) {
        data.append(contentsOf: value.utf8)
    }
    func appendU32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func appendU16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    appendASCII("RIFF")
    appendU32(UInt32(36 + dataSize))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendU32(16)
    appendU16(1)
    appendU16(1)
    appendU32(UInt32(sampleRate))
    appendU32(UInt32(sampleRate * 2))
    appendU16(2)
    appendU16(16)
    appendASCII("data")
    appendU32(UInt32(dataSize))
    data.append(Data(count: dataSize))
    return data
}
