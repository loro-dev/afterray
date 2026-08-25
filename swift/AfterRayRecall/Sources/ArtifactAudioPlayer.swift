import AVFoundation
import Foundation

// @dec:forced-aligned-audio-transcript-cues — docs/decisions/active/product/2026-08-24-forced-aligned-audio-transcript-cues.md
struct ArtifactAudioPlaybackSource: Equatable, Sendable {
    let momentID: String
    let sessionID: String
    let segmentID: String
    let artifactID: String
    let offset: TimeInterval
    let capturedAtMs: Int64
    let segmentStartedAtMs: Int64
    let segmentEndedAtMs: Int64
    let transcriptText: String?
    let transcriptCues: [RecallTranscriptCue]

    init(
        momentID: String,
        sessionID: String = "session-1",
        segmentID: String? = nil,
        artifactID: String,
        offset: TimeInterval,
        capturedAtMs: Int64 = 0,
        segmentStartedAtMs: Int64 = 0,
        segmentEndedAtMs: Int64 = 60_000,
        transcriptText: String? = nil,
        transcriptCues: [RecallTranscriptCue] = []
    ) {
        self.momentID = momentID
        self.sessionID = sessionID
        self.segmentID = segmentID ?? artifactID
        self.artifactID = artifactID
        self.offset = offset
        self.capturedAtMs = capturedAtMs
        self.segmentStartedAtMs = segmentStartedAtMs
        self.segmentEndedAtMs = segmentEndedAtMs
        self.transcriptText = transcriptText
        self.transcriptCues = transcriptCues
    }

    init?(moment: RecallMoment) {
        guard let segment = moment.audioSegment else { return nil }
        self.momentID = moment.id
        self.sessionID = moment.sessionId
        self.segmentID = segment.id
        self.artifactID = segment.artifactID
        self.offset = ArtifactAudioPlayer.offset(for: moment)
        self.capturedAtMs = moment.capturedAtMs
        self.segmentStartedAtMs = segment.startedAtMs
        self.segmentEndedAtMs = segment.endedAtMs
        self.transcriptText = segment.transcriptText
        self.transcriptCues = segment.transcriptCues
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.momentID == rhs.momentID
            && lhs.segmentID == rhs.segmentID
            && lhs.artifactID == rhs.artifactID
            && lhs.offset == rhs.offset
    }

    func replacingEvidence(from moment: RecallMoment) -> Self? {
        guard let segment = moment.audioSegment, segment.id == segmentID else { return nil }
        return Self(
            momentID: momentID,
            sessionID: sessionID,
            segmentID: segmentID,
            artifactID: artifactID,
            offset: offset,
            capturedAtMs: capturedAtMs,
            segmentStartedAtMs: segmentStartedAtMs,
            segmentEndedAtMs: segmentEndedAtMs,
            transcriptText: segment.transcriptText,
            transcriptCues: segment.transcriptCues
        )
    }
}

/// Generation-guarded playback session. A completed fetch may only start
/// audio when `finishLoad` accepts the same generation and source that
/// `beginPlay` issued.
struct ArtifactAudioPlaybackSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case buffering
        case playing
        case paused
    }

    private(set) var phase: Phase = .idle
    private(set) var source: ArtifactAudioPlaybackSource?
    private(set) var generation: UInt64 = 0

    var isPlaying: Bool { phase == .playing }
    var isBuffering: Bool { phase == .buffering }
    var artifactID: String? { source?.artifactID }
    var momentID: String? { source?.momentID }

    /// Pause/resume is valid only while the selected moment still owns this
    /// exact source. Adjacent moments can share one artifact but require a
    /// different seek offset, so artifact identity alone is insufficient.
    func toggleDecision(
        source: ArtifactAudioPlaybackSource,
        hasPlayer: Bool
    ) -> ArtifactAudioToggleDecision {
        if phase == .buffering, self.source == source {
            return .cancelBuffering
        }
        guard self.source == source,
              hasPlayer,
              phase == .playing || phase == .paused
        else {
            return .loadAndPlay
        }
        return phase == .playing ? .pause : .resume
    }

    @discardableResult
    mutating func beginPlay(source: ArtifactAudioPlaybackSource) -> UInt64 {
        generation &+= 1
        self.source = source
        phase = .buffering
        return generation
    }

    /// Returns true only if this load is still the active request.
    mutating func finishLoad(generation request: UInt64) -> Bool {
        guard generation == request, phase == .buffering else { return false }
        phase = .playing
        return true
    }

    mutating func failLoad(generation request: UInt64) {
        guard generation == request, phase == .buffering else { return }
        resetKeepingGeneration()
    }

    mutating func pause() {
        guard phase == .playing else { return }
        phase = .paused
    }

    mutating func resume() {
        guard phase == .paused else { return }
        phase = .playing
    }

    mutating func stop() {
        generation &+= 1
        resetKeepingGeneration()
    }

    mutating func refreshEvidence(from moment: RecallMoment) {
        guard let refreshed = source?.replacingEvidence(from: moment) else { return }
        source = refreshed
    }

    @discardableResult
    mutating func cancelIfBuffering(source: ArtifactAudioPlaybackSource) -> Bool {
        guard phase == .buffering, self.source == source else { return false }
        stop()
        return true
    }

    private mutating func resetKeepingGeneration() {
        phase = .idle
        source = nil
    }
}

enum ArtifactAudioToggleDecision: Equatable, Sendable {
    case cancelBuffering
    case pause
    case resume
    case loadAndPlay
}

/// Mutable ownership for decrypted audio retained between pause and resume.
/// `Data` alone has no reliable explicit erasure boundary; this wrapper owns
/// one copied buffer and zeros it before the app releases its reference.
/// Mutable only during its ownership handoff between the audio repository and
/// the MainActor player. The two actors never access it concurrently.
final class SensitiveAudioData: @unchecked Sendable {
    private let storage: NSMutableData
    private(set) var isCleared = false

    init(copying data: Data) {
        storage = NSMutableData(data: data)
    }

    var playerData: Data {
        precondition(!isCleared)
        return storage as Data
    }

    var isZeroed: Bool {
        Data(referencing: storage).allSatisfy { $0 == 0 }
    }

    func clear() {
        guard !isCleared else { return }
        storage.resetBytes(in: NSRange(location: 0, length: storage.length))
        isCleared = true
    }

    deinit {
        clear()
    }
}

@MainActor
public final class ArtifactAudioPlayer: NSObject, ObservableObject, RecallAudioPlaying, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var playingArtifactID: String?
    /// Changes only at capture boundaries. The simultaneous store playhead
    /// publication redraws the root, so this must not publish a second update.
    public private(set) var playingMomentID: String?

    public var playbackContext: RecallAudioPlaybackContext? {
        guard let source = session.source, let playingMomentID else { return nil }
        return RecallAudioPlaybackContext(
            sourceMomentID: source.momentID,
            followedMomentID: playingMomentID,
            segmentID: source.segmentID,
            artifactID: source.artifactID,
            sourceOffset: source.offset,
            segmentStartedAtMs: source.segmentStartedAtMs,
            segmentEndedAtMs: source.segmentEndedAtMs,
            transcriptText: source.transcriptText,
            transcriptCues: source.transcriptCues
        )
    }

    public var timelinePlaybackPosition: AudioTimelinePlaybackPosition? {
        guard session.isPlaying, let source = session.source else { return nil }
        let currentTime = playbackTime
        guard currentTime.isFinite else { return nil }
        return AudioTimelinePlaybackPosition(
            sourceMomentID: source.momentID,
            sourceSessionID: source.sessionID,
            sourceCapturedAtMs: source.capturedAtMs,
            timelineMs: source.segmentStartedAtMs
                + Int64((currentTime * 1_000).rounded())
        )
    }

    /// Read by the leaf audio chrome. These clocks deliberately do not
    /// publish: a 12Hz root invalidation competed with timeline scrubbing.
    public var playbackTime: TimeInterval {
        player?.currentTime ?? parkedPlaybackTime
    }

    public var playbackDuration: TimeInterval {
        let duration = player?.duration ?? parkedPlaybackDuration
        return duration.isFinite && duration > 0 ? duration : 0
    }

    public var generation: UInt64 { session.generation }

    private let repository: RecallAudioRepository
    private var session = ArtifactAudioPlaybackSession()
    private var player: AVAudioPlayer?
    private var loadedData: SensitiveAudioData?
    private var loadTask: Task<Void, Never>?
    private var parkedPlaybackTime: TimeInterval = 0
    private var parkedPlaybackDuration: TimeInterval = 0
    /// AAC `AVAudioPlayer` can fire `audioPlayerDidFinishPlaying` immediately
    /// after a paused `play()`. Ignore those until the decoder has had a beat.
    private var ignoreFinishUntil: Date?

    public init(repository: RecallAudioRepository) {
        self.repository = repository
    }

    public func toggle(moment: RecallMoment) {
        let source = playingMomentID == moment.id
            ? session.source
            : ArtifactAudioPlaybackSource(moment: moment)
        guard let source else { return }
        switch session.toggleDecision(
            source: source,
            hasPlayer: player != nil
        ) {
        case .cancelBuffering:
            session.stop()
            loadTask?.cancel()
            loadTask = nil
            abandonEngine()
            publish()
        case .pause:
            pause()
        case .resume:
            resumeInPlace(fallback: source)
        case .loadAndPlay:
            startLoad(source: source)
        }
    }

    public func play(moment: RecallMoment) {
        let source = playingMomentID == moment.id
            ? session.source
            : ArtifactAudioPlaybackSource(moment: moment)
        guard let source else { return }
        if session.source == source,
           player != nil,
           !session.isBuffering,
           session.phase == .playing || session.phase == .paused
        {
            resumeInPlace(fallback: source)
            return
        }
        startLoad(source: source)
    }

    /// Advances presentation ownership without changing the playback source.
    /// Called only by the automatic timeline follower at capture boundaries.
    public func followTimeline(to moment: RecallMoment) {
        guard session.isPlaying,
              let source = session.source,
              moment.sessionId == source.sessionID,
              playingMomentID != moment.id
        else { return }
        playingMomentID = moment.id
    }

    /// Refines caption data after `moment_get` without changing the immutable
    /// playback identity, seek offset, generation, or decoder.
    public func updateEvidence(
        from moment: RecallMoment,
        generation expectedGeneration: UInt64? = nil
    ) {
        if let expectedGeneration, expectedGeneration != session.generation { return }
        session.refreshEvidence(from: moment)
    }

    public func pause() {
        parkPlaybackPosition()
        player?.pause()
        session.pause()
        publish()
    }

    public func stop() {
        guard session.phase != .idle
                || player != nil
                || loadTask != nil
                || loadedData != nil
        else { return }
        session.stop()
        loadTask?.cancel()
        loadTask = nil
        abandonEngine()
        publish()
    }

    /// Audio duration is derived from decrypted artifact bytes, so it follows
    /// the same lock/sleep clearing boundary as every other recall cache.
    public func clearSensitiveData() {
        stop()
    }

    nonisolated public static func offset(for moment: RecallMoment) -> TimeInterval {
        guard let segment = moment.audioSegment else { return 0 }
        return min(
            max(Double(moment.capturedAtMs - segment.startedAtMs) / 1_000, 0),
            segment.duration
        )
    }

    private func resumeInPlace(fallback source: ArtifactAudioPlaybackSource) {
        guard let player else {
            startLoad(source: source)
            return
        }
        // Do not seek. Setting `currentTime` on a paused AAC player and then
        // calling `play()` is the path that silently fails.
        if startEngine(player) {
            session.resume()
            publish()
            return
        }
        startLoad(source: source, playbackOffset: player.currentTime)
    }

    private func startLoad(
        source: ArtifactAudioPlaybackSource,
        playbackOffset: TimeInterval? = nil
    ) {
        player?.stop()
        player = nil
        clearLoadedData()
        ignoreFinishUntil = nil
        let requestedOffset = playbackOffset ?? source.offset
        parkedPlaybackTime = requestedOffset
        parkedPlaybackDuration = 0

        let request = session.beginPlay(source: source)
        playingMomentID = source.momentID
        publish()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadAndStart(
                source: source,
                playbackOffset: requestedOffset,
                generation: request
            )
        }
    }

    @discardableResult
    private func startEngine(_ existing: AVAudioPlayer) -> Bool {
        ignoreFinishUntil = Date().addingTimeInterval(0.35)
        if existing.play(), existing.isPlaying {
            player = existing
            parkPlaybackPosition()
            return true
        }
        return false
    }

    private func loadAndStart(
        source: ArtifactAudioPlaybackSource,
        playbackOffset: TimeInterval,
        generation request: UInt64
    ) async {
        do {
            let prepared = try await repository.preparedAudio(
                artifactID: source.artifactID
            )
            guard session.generation == request,
                  session.source == source,
                  session.phase == .buffering
            else {
                await repository.discard(prepared)
                return
            }
            let newPlayer = prepared.player
            guard session.finishLoad(generation: request) else {
                await repository.discard(prepared)
                return
            }
            loadedData = prepared.sensitiveData
            newPlayer.delegate = self
            ignoreFinishUntil = Date().addingTimeInterval(0.35)
            seek(newPlayer, to: playbackOffset)
            parkedPlaybackTime = newPlayer.currentTime
            parkedPlaybackDuration = newPlayer.duration
            if newPlayer.play(), newPlayer.isPlaying {
                player = newPlayer
                publish()
                return
            }
            session.pause()
            player = newPlayer
            parkPlaybackPosition()
            publish()
        } catch {
            guard session.generation == request else { return }
            session.failLoad(generation: request)
            abandonEngine()
            publish()
        }
    }

    private func seek(_ player: AVAudioPlayer, to offset: TimeInterval) {
        let duration = player.duration
        guard duration.isFinite, duration > 0 else {
            player.currentTime = max(offset, 0)
            return
        }
        player.currentTime = min(max(offset, 0), max(duration - 0.05, 0))
    }

    private func abandonEngine() {
        player?.stop()
        player = nil
        clearLoadedData()
        ignoreFinishUntil = nil
        parkedPlaybackTime = 0
        parkedPlaybackDuration = 0
    }

    private func clearLoadedData() {
        guard let sensitiveData = loadedData else { return }
        loadedData = nil
        Task { [repository] in
            await repository.clear(sensitiveData)
        }
    }

    private func publish() {
        if isPlaying != session.isPlaying {
            isPlaying = session.isPlaying
        }
        if isBuffering != session.isBuffering {
            isBuffering = session.isBuffering
        }
        if playingArtifactID != session.artifactID {
            playingArtifactID = session.artifactID
        }
        if session.source == nil, playingMomentID != nil {
            playingMomentID = nil
        } else if playingMomentID == nil, let source = session.source {
            playingMomentID = source.momentID
        }
    }

    private func parkPlaybackPosition() {
        guard let player else { return }
        parkedPlaybackTime = player.currentTime
        parkedPlaybackDuration = player.duration
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === finished else { return }
            if let until = self.ignoreFinishUntil, Date() < until {
                if !finished.isPlaying, self.session.phase == .playing {
                    self.session.pause()
                    self.publish()
                }
                return
            }
            let duration = finished.duration
            let nearEnd = duration.isFinite && duration > 0 && finished.currentTime >= duration - 0.35
            guard flag && (nearEnd || finished.currentTime <= 0.02) else {
                if !finished.isPlaying, self.session.phase == .playing {
                    self.session.pause()
                    self.publish()
                }
                return
            }
            self.stop()
        }
    }
}
