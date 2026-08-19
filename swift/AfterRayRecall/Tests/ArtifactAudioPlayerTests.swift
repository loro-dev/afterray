import XCTest
@testable import AfterRayRecall

final class ArtifactAudioPlaybackSessionTests: XCTestCase {
    func testCompletedLoadAfterStopDoesNotEnterPlaying() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")

        XCTAssertTrue(session.isBuffering)
        XCTAssertEqual(session.artifactID, "audio-1")
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
        let generation = session.beginPlay(artifactID: "audio-1")

        XCTAssertTrue(session.cancelIfBuffering(artifactID: "audio-1"))
        XCTAssertFalse(session.isBuffering)
        XCTAssertFalse(session.isPlaying)
        XCTAssertNil(session.artifactID)
        XCTAssertFalse(session.finishLoad(generation: generation))
        XCTAssertFalse(session.isPlaying)
    }

    func testCancelIfBufferingIgnoresADifferentArtifact() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")

        XCTAssertFalse(session.cancelIfBuffering(artifactID: "audio-2"))
        XCTAssertTrue(session.isBuffering)
        XCTAssertEqual(session.artifactID, "audio-1")
        XCTAssertTrue(session.finishLoad(generation: generation))
        XCTAssertTrue(session.isPlaying)
    }

    func testFailLoadAfterCancelIsIgnored() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1")
        session.stop()
        session.failLoad(generation: generation)
        XCTAssertFalse(session.isPlaying)
        XCTAssertFalse(session.isBuffering)
        XCTAssertNil(session.artifactID)
    }

    func testToggleOnTheSameMomentPausesAndResumes() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1", offset: 4)
        XCTAssertTrue(session.finishLoad(generation: generation))

        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 4, hasPlayer: true),
            .pause
        )

        session.pause()
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 4.2, hasPlayer: true),
            .resume
        )

        session.resume()
        XCTAssertTrue(session.isPlaying)
    }

    func testToggleUsesOriginOffsetNotDecoderCurrentTime() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1", offset: 2)
        XCTAssertTrue(session.finishLoad(generation: generation))

        // After a couple of seconds of playback the decoder clock has walked
        // off the moment, but the button is still "this moment". That used to
        // be read as a seek, so pause never stuck and resume always rewound.
        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 2, hasPlayer: true),
            .pause
        )

        session.pause()
        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 2, hasPlayer: true),
            .resume
        )
    }

    func testToggleOnADifferentMomentSeeksInsteadOfPausing() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1", offset: 2)
        XCTAssertTrue(session.finishLoad(generation: generation))

        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 8, hasPlayer: true),
            .seekAndPlay(8)
        )

        session.pause()
        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 8, hasPlayer: true),
            .seekAndPlay(8)
        )
    }

    func testToggleWhileBufferingCancelsViaDecision() {
        var session = ArtifactAudioPlaybackSession()
        _ = session.beginPlay(artifactID: "audio-1", offset: 1)
        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 1, hasPlayer: false),
            .cancelBuffering
        )
    }

    func testToggleWithoutAPlayerReloads() {
        var session = ArtifactAudioPlaybackSession()
        let generation = session.beginPlay(artifactID: "audio-1", offset: 1)
        XCTAssertTrue(session.finishLoad(generation: generation))
        session.pause()
        XCTAssertEqual(
            session.toggleDecision(artifactID: "audio-1", offset: 1, hasPlayer: false),
            .loadAndPlay
        )
    }
}

@MainActor
final class ArtifactAudioPlayerTests: XCTestCase {
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
        let player = ArtifactAudioPlayer(repository: RecallImageRepository(daemon: daemon))
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
        let player = ArtifactAudioPlayer(repository: RecallImageRepository(daemon: daemon))
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
        let player = ArtifactAudioPlayer(repository: RecallImageRepository(daemon: daemon))
        let target = moment(capturedAtMs: 1_000, startedAtMs: 1_000, audioID: "audio-1")

        player.play(moment: target)
        try await waitUntil(player.isPlaying, timeoutMs: 400)
        XCTAssertEqual(player.playingArtifactID, "audio-1")
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

    func testRepeatedPausePlayStaysOnTheSameSession() async throws {
        let daemon = DelayedArtifactDaemon(delayMs: 10, bytes: silentWav())
        let player = ArtifactAudioPlayer(repository: RecallImageRepository(daemon: daemon))
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
        capturedAtMs: Int64,
        startedAtMs: Int64?,
        audioID: String = "audio-1"
    ) -> RecallMoment {
        RecallMoment(
            id: "m1",
            sessionId: "s1",
            capturedAtMs: capturedAtMs,
            imageArtifactId: "img-1",
            audioArtifactId: audioID,
            audioStartedAtMs: startedAtMs
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
