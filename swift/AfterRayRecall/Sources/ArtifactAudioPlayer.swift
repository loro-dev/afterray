import AVFoundation
import Foundation

/// Generation-guarded playback session. A completed fetch may only start
/// audio when `finishLoad` accepts the same generation that `beginPlay` issued.
struct ArtifactAudioPlaybackSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case buffering
        case playing
        case paused
    }

    /// How close two moment offsets must be to count as "the same moment".
    /// This is compared against the last *requested* origin, never against
    /// `AVAudioPlayer.currentTime` — that clock walks forward while audio
    /// plays, so a 1.5s slop against it made pause stop working after the
    /// first second and a half.
    static let momentSlop: TimeInterval = 1.5

    private(set) var phase: Phase = .idle
    private(set) var artifactID: String?
    private(set) var generation: UInt64 = 0
    /// Offset we last started or seeked to — the selected moment.
    private(set) var originOffset: TimeInterval = 0

    var isPlaying: Bool { phase == .playing }
    var isBuffering: Bool { phase == .buffering }

    func isSameMoment(offset: TimeInterval) -> Bool {
        abs(originOffset - offset) < Self.momentSlop
    }

    /// What a play/pause click should do. Pure so the 1.5s slop cannot drift
    /// between the player and its tests.
    func toggleDecision(
        artifactID: String,
        offset: TimeInterval,
        hasPlayer: Bool
    ) -> ArtifactAudioToggleDecision {
        if phase == .buffering, self.artifactID == artifactID {
            return .cancelBuffering
        }
        guard self.artifactID == artifactID, hasPlayer, phase == .playing || phase == .paused else {
            return .loadAndPlay
        }
        if isSameMoment(offset: offset) {
            return phase == .playing ? .pause : .resume
        }
        return .seekAndPlay(offset)
    }

    @discardableResult
    mutating func beginPlay(artifactID: String, offset: TimeInterval = 0) -> UInt64 {
        generation &+= 1
        self.artifactID = artifactID
        originOffset = offset
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

    mutating func noteSeek(to offset: TimeInterval) {
        originOffset = offset
    }

    mutating func stop() {
        generation &+= 1
        resetKeepingGeneration()
    }

    @discardableResult
    mutating func cancelIfBuffering(artifactID: String) -> Bool {
        guard phase == .buffering, self.artifactID == artifactID else { return false }
        stop()
        return true
    }

    private mutating func resetKeepingGeneration() {
        phase = .idle
        artifactID = nil
        originOffset = 0
    }
}

enum ArtifactAudioToggleDecision: Equatable, Sendable {
    case cancelBuffering
    case pause
    case resume
    case seekAndPlay(TimeInterval)
    case loadAndPlay
}

@MainActor
public final class ArtifactAudioPlayer: NSObject, ObservableObject, RecallAudioPlaying, AVAudioPlayerDelegate {
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var playingArtifactID: String?

    public var generation: UInt64 { session.generation }

    private let repository: RecallImageRepository
    private var session = ArtifactAudioPlaybackSession()
    private var player: AVAudioPlayer?
    private var loadedData: Data?
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchArtifactID: String?
    /// AAC `AVAudioPlayer` can fire `audioPlayerDidFinishPlaying` immediately
    /// after a paused seek. Ignore those until the decoder has had a beat.
    private var ignoreFinishUntil: Date?

    public init(repository: RecallImageRepository) {
        self.repository = repository
    }

    public func toggle(moment: RecallMoment) {
        guard let artifactID = moment.audioArtifactId else { return }
        let offset = Self.offset(for: moment)
        switch session.toggleDecision(
            artifactID: artifactID,
            offset: offset,
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
            resumeInPlace(fallback: moment)
        case .seekAndPlay:
            seekAndPlay(offset: offset, fallback: moment)
        case .loadAndPlay:
            play(moment: moment)
        }
    }

    public func play(moment: RecallMoment) {
        guard let artifactID = moment.audioArtifactId else { return }
        let offset = Self.offset(for: moment)

        if session.artifactID == artifactID, let player, !session.isBuffering {
            if startEngine(player, seekTo: offset) {
                session.noteSeek(to: offset)
                session.resume()
                publish()
                return
            }
        }

        player?.stop()
        player = nil

        let request = session.beginPlay(artifactID: artifactID, offset: offset)
        publish()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadAndStart(artifactID: artifactID, offset: offset, generation: request)
        }
    }

    public func pause() {
        player?.pause()
        session.pause()
        publish()
    }

    public func stop() {
        session.stop()
        loadTask?.cancel()
        loadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchArtifactID = nil
        abandonEngine()
        publish()
    }

    public func prefetch(artifactID: String?) {
        guard let artifactID else {
            prefetchTask?.cancel()
            prefetchTask = nil
            prefetchArtifactID = nil
            return
        }
        guard prefetchArtifactID != artifactID else { return }
        prefetchTask?.cancel()
        prefetchArtifactID = artifactID
        prefetchTask = Task { [repository] in
            _ = try? await repository.data(artifactID: artifactID)
        }
    }

    public static func offset(for moment: RecallMoment) -> TimeInterval {
        guard let startedAtMs = moment.audioStartedAtMs else { return 0 }
        return max(Double(moment.capturedAtMs - startedAtMs) / 1_000, 0)
    }

    private func resumeInPlace(fallback moment: RecallMoment) {
        guard let player else {
            play(moment: moment)
            return
        }
        // Resume first, seek never. Setting `currentTime` on a paused AAC
        // player and then calling `play()` is the path that silently fails
        // and leaves the button stuck on pause.
        if startEngine(player, seekTo: nil) {
            session.resume()
            publish()
            return
        }
        play(moment: moment)
    }

    private func seekAndPlay(offset: TimeInterval, fallback moment: RecallMoment) {
        guard let player else {
            play(moment: moment)
            return
        }
        if startEngine(player, seekTo: offset) {
            session.noteSeek(to: offset)
            session.resume()
            publish()
            return
        }
        play(moment: moment)
    }

    /// Start (or restart) the decoder. Always `play()` before assigning
    /// `currentTime`: AAC-in-M4A from capture refuses the inverse order
    /// after `pause()`.
    @discardableResult
    private func startEngine(_ existing: AVAudioPlayer, seekTo offset: TimeInterval?) -> Bool {
        ignoreFinishUntil = Date().addingTimeInterval(0.35)
        existing.prepareToPlay()
        let started = existing.play()
        if started {
            if let offset {
                seek(existing, to: offset)
                if !existing.isPlaying {
                    existing.prepareToPlay()
                    _ = existing.play()
                }
            }
            if existing.isPlaying {
                player = existing
                return true
            }
        }
        return rebuildEngine(seekTo: offset ?? existing.currentTime)
    }

    @discardableResult
    private func rebuildEngine(seekTo offset: TimeInterval) -> Bool {
        guard let data = loadedData else { return false }
        do {
            let rebuilt = try AVAudioPlayer(data: data)
            rebuilt.delegate = self
            rebuilt.prepareToPlay()
            ignoreFinishUntil = Date().addingTimeInterval(0.35)
            guard rebuilt.play() else { return false }
            seek(rebuilt, to: offset)
            if !rebuilt.isPlaying {
                _ = rebuilt.play()
            }
            player = rebuilt
            return rebuilt.isPlaying
        } catch {
            return false
        }
    }

    private func loadAndStart(artifactID: String, offset: TimeInterval, generation request: UInt64) async {
        do {
            let data = try await repository.data(artifactID: artifactID)
            guard session.generation == request, session.phase == .buffering else { return }
            let newPlayer = try AVAudioPlayer(data: data)
            guard session.finishLoad(generation: request) else {
                newPlayer.stop()
                return
            }
            loadedData = data
            newPlayer.delegate = self
            if startEngine(newPlayer, seekTo: offset) {
                publish()
                return
            }
            session.pause()
            player = newPlayer
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
        loadedData = nil
        ignoreFinishUntil = nil
    }

    private func publish() {
        isPlaying = session.isPlaying
        isBuffering = session.isBuffering
        playingArtifactID = session.artifactID
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === finished else { return }
            if let until = self.ignoreFinishUntil, Date() < until {
                // Spurious finish after a paused seek: snap back to paused
                // rather than tearing the session down (the next click would
                // otherwise reload, and a second click during that load
                // cancelled it — the "click several times" loop).
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
