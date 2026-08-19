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

    private(set) var phase: Phase = .idle
    private(set) var artifactID: String?
    private(set) var generation: UInt64 = 0

    var isPlaying: Bool { phase == .playing }
    var isBuffering: Bool { phase == .buffering }

    /// Play/pause is a transport key: playing → pause, paused → resume.
    /// The selected frame is ignored. Offset is only used when a session
    /// first loads, not on later clicks.
    func toggleDecision(artifactID: String, hasPlayer: Bool) -> ArtifactAudioToggleDecision {
        if phase == .buffering, self.artifactID == artifactID {
            return .cancelBuffering
        }
        guard hasPlayer, phase == .playing || phase == .paused else {
            return .loadAndPlay
        }
        return phase == .playing ? .pause : .resume
    }

    @discardableResult
    mutating func beginPlay(artifactID: String) -> UInt64 {
        generation &+= 1
        self.artifactID = artifactID
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

    @discardableResult
    mutating func cancelIfBuffering(artifactID: String) -> Bool {
        guard phase == .buffering, self.artifactID == artifactID else { return false }
        stop()
        return true
    }

    private mutating func resetKeepingGeneration() {
        phase = .idle
        artifactID = nil
    }
}

enum ArtifactAudioToggleDecision: Equatable, Sendable {
    case cancelBuffering
    case pause
    case resume
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
    /// after a paused `play()`. Ignore those until the decoder has had a beat.
    private var ignoreFinishUntil: Date?

    public init(repository: RecallImageRepository) {
        self.repository = repository
    }

    public func toggle(moment: RecallMoment) {
        guard let artifactID = moment.audioArtifactId else { return }
        switch session.toggleDecision(
            artifactID: artifactID,
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
        case .loadAndPlay:
            startLoad(moment: moment)
        }
    }

    public func play(moment: RecallMoment) {
        if player != nil, !session.isBuffering, session.phase == .playing || session.phase == .paused {
            resumeInPlace(fallback: moment)
            return
        }
        startLoad(moment: moment)
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
            startLoad(moment: moment)
            return
        }
        // Do not seek. Setting `currentTime` on a paused AAC player and then
        // calling `play()` is the path that silently fails.
        if startEngine(player) {
            session.resume()
            publish()
            return
        }
        startLoad(moment: moment)
    }

    private func startLoad(moment: RecallMoment) {
        guard let artifactID = moment.audioArtifactId else { return }
        let offset = Self.offset(for: moment)
        player?.stop()
        player = nil

        let request = session.beginPlay(artifactID: artifactID)
        publish()

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadAndStart(artifactID: artifactID, offset: offset, generation: request)
        }
    }

    @discardableResult
    private func startEngine(_ existing: AVAudioPlayer) -> Bool {
        ignoreFinishUntil = Date().addingTimeInterval(0.35)
        existing.prepareToPlay()
        if existing.play(), existing.isPlaying {
            player = existing
            return true
        }
        return rebuildEngine(at: existing.currentTime)
    }

    @discardableResult
    private func rebuildEngine(at offset: TimeInterval) -> Bool {
        guard let data = loadedData else { return false }
        do {
            let rebuilt = try AVAudioPlayer(data: data)
            rebuilt.delegate = self
            rebuilt.prepareToPlay()
            ignoreFinishUntil = Date().addingTimeInterval(0.35)
            seek(rebuilt, to: offset)
            guard rebuilt.play(), rebuilt.isPlaying else { return false }
            player = rebuilt
            return true
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
            newPlayer.prepareToPlay()
            ignoreFinishUntil = Date().addingTimeInterval(0.35)
            seek(newPlayer, to: offset)
            if newPlayer.play(), newPlayer.isPlaying {
                player = newPlayer
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
