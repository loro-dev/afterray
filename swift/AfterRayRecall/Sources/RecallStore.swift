import Foundation

@MainActor
public final class RecallStore: ObservableObject {
    @Published public private(set) var sessions: [RecallSession] = []
    @Published public private(set) var moments: [RecallMoment] = []
    @Published public private(set) var playheadMs: Int64 = 0
    @Published public private(set) var selectedIndex: Int = 0
    @Published public private(set) var loadState: RecallLoadState = .ready

    private let daemon: any RecallDaemonServing
    private var sensitiveGeneration: UInt64 = 0

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
    }

    public var selectedMoment: RecallMoment? {
        RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments)
    }

    public func loadTimeline(preservingSelection: Bool = false) async {
        let requestGeneration = sensitiveGeneration
        do {
            let loadedSessions = try await daemon.sessions().sorted { $0.startedAtMs < $1.startedAtMs }
            let loaded = try await daemon.timeline().sorted { $0.capturedAtMs < $1.capturedAtMs }
            guard sensitiveGeneration == requestGeneration else { return }
            sessions = loadedSessions
            apply(loaded, preservingSelection: preservingSelection)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) {
                return
            }
            moments = []
            applyPlayhead(0)
            loadState = .failed(message: error.localizedDescription)
        }
    }

    /// Refreshes a small overlap window so recently completed OCR/AX work can
    /// replace existing moments without rescanning the entire encrypted vault.
    public func refreshTimeline(preservingSelection: Bool = true) async {
        guard !moments.isEmpty else {
            await loadTimeline(preservingSelection: preservingSelection)
            return
        }

        let overlapStart = max(moments.count - 20, 0)
        let sinceMs = moments[overlapStart].capturedAtMs
        let requestGeneration = sensitiveGeneration
        do {
            let updated = try await daemon.timeline(sinceMs: sinceMs)
                .sorted { left, right in
                    if left.capturedAtMs == right.capturedAtMs { return left.id < right.id }
                    return left.capturedAtMs < right.capturedAtMs
                }
            guard sensitiveGeneration == requestGeneration else { return }
            guard !updated.isEmpty else { return }
            let prefix = moments.prefix { $0.capturedAtMs < sinceMs }
            let existingOverlap = Array(moments.dropFirst(prefix.count))
            guard existingOverlap != updated else { return }
            apply(Array(prefix) + updated, preservingSelection: preservingSelection)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) {
                if case .failed = loadState { return }
                return
            }
            loadState = .failed(message: error.localizedDescription)
        }
    }

    public func loadSession(
        id: String,
        selecting momentID: String? = nil,
        preservingSelection: Bool = false
    ) async throws {
        let requestGeneration = sensitiveGeneration
        let loaded = try await daemon.moments(sessionID: id).sorted { $0.capturedAtMs < $1.capturedAtMs }
        guard sensitiveGeneration == requestGeneration else { return }
        apply(loaded, selecting: momentID, preservingSelection: preservingSelection)
    }

    private func apply(
        _ loaded: [RecallMoment],
        selecting momentID: String? = nil,
        preservingSelection: Bool = false
    ) {
        // Read the selection after the daemon request returns. The user may
        // continue scrubbing while that request is in flight, and the refresh
        // must preserve their newest position rather than a stale snapshot.
        let preservedMomentID = preservingSelection ? selectedMoment?.id : nil
        let preservedPlayheadMs = playheadMs
        moments = loaded
        if let targetID = momentID, let moment = loaded.first(where: { $0.id == targetID }) {
            applyPlayhead(moment.capturedAtMs)
        } else if preservingSelection {
            let bounds = TimelineLayout.timeBounds(moments: loaded)
            if !loaded.isEmpty, preservedPlayheadMs >= bounds.startMs, preservedPlayheadMs <= bounds.endMs {
                applyPlayhead(preservedPlayheadMs)
            } else if let preservedMomentID, let moment = loaded.first(where: { $0.id == preservedMomentID }) {
                applyPlayhead(moment.capturedAtMs)
            } else {
                applyPlayhead(loaded.last?.capturedAtMs ?? 0)
            }
        } else {
            applyPlayhead(loaded.last?.capturedAtMs ?? 0)
        }
        loadState = .ready
    }

    public func openSearchHit(_ hit: RecallSearchHit) async {
        await openMoment(id: hit.momentId)
    }

    /// Reloads the timeline and parks the playhead on `momentID`.
    ///
    /// The full reload is the point: a search hit is routinely outside the
    /// window currently in memory.
    public func openMoment(id momentID: String) async {
        let requestGeneration = sensitiveGeneration
        do {
            let loaded = try await daemon.timeline().sorted { $0.capturedAtMs < $1.capturedAtMs }
            guard sensitiveGeneration == requestGeneration else { return }
            apply(loaded, selecting: momentID)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) { return }
            loadState = .failed(message: error.localizedDescription)
        }
    }

    /// Moves the playhead to a moment already in memory.
    ///
    /// Returns `false` when it is not loaded, so callers stepping through
    /// search results can fall back to `openMoment` instead of paying for a
    /// full timeline reload on every step.
    @discardableResult
    public func selectLoaded(momentID: String) -> Bool {
        guard let moment = moments.first(where: { $0.id == momentID }) else { return false }
        applyPlayhead(moment.capturedAtMs)
        return true
    }

    public func select(playheadMs ms: Int64) {
        applyPlayhead(ms)
    }

    public func select(index: Int) {
        guard let index = RecallGeometry.clampedIndex(index, count: moments.count) else { return }
        applyPlayhead(moments[index].capturedAtMs)
    }

    public func toggleFavorite() async {
        guard let selected = selectedMoment,
              let index = moments.firstIndex(where: { $0.id == selected.id })
        else { return }
        let momentID = selected.id
        let previous = selected.isFavorite
        moments[index].isFavorite.toggle()
        do {
            try await daemon.setFavorite(momentID: momentID, favorite: !previous)
        } catch {
            guard let index = moments.firstIndex(where: { $0.id == momentID }) else { return }
            moments[index].isFavorite = previous
            if Self.isDaemonConnectionError(error) { return }
            loadState = .failed(message: error.localizedDescription)
        }
    }

    public func reportFailure(_ message: String) {
        loadState = .failed(message: message)
    }

    public func clearSensitiveState() {
        sensitiveGeneration &+= 1
        sessions = []
        moments = []
        applyPlayhead(0)
        loadState = .ready
    }

    private func applyPlayhead(_ ms: Int64) {
        playheadMs = RecallPlayhead.clamp(ms, moments: moments)
        selectedIndex = RecallPlayhead.resolveIndex(playheadMs: playheadMs, moments: moments) ?? 0
    }

    private static func isDaemonConnectionError(_ error: Error) -> Bool {
        guard let daemonError = error as? DaemonClientError else { return false }
        if case .connection = daemonError { return true }
        return false
    }
}

public actor RecallImageRepository {
    private let daemon: any RecallDaemonServing
    private let cache = NSCache<NSString, NSData>()
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var cachedArtifactIDs: Set<String> = []
    private var generation: UInt64 = 0

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
        cache.countLimit = 128
        cache.totalCostLimit = 512 * 1_024 * 1_024
    }

    public func data(artifactID: String) async throws -> Data {
        if let cached = cache.object(forKey: artifactID as NSString) { return cached as Data }
        if let existing = inFlight[artifactID] { return try await existing.value }
        let daemon = daemon
        let requestGeneration = generation
        let task = Task<Data, Error> {
            try await Self.fetch(daemon: daemon, artifactID: artifactID)
        }
        inFlight[artifactID] = task
        do {
            let bytes = try await task.value
            inFlight[artifactID] = nil
            guard generation == requestGeneration else { return bytes }
            cache.setObject(
                NSMutableData(data: bytes),
                forKey: artifactID as NSString,
                cost: bytes.count
            )
            cachedArtifactIDs.insert(artifactID)
            return bytes
        } catch {
            inFlight[artifactID] = nil
            throw error
        }
    }

    /// Filmstrip pixels. Cached alongside stills because the daemon may answer
    /// with a full IVF frame for moments packed before thumbnails existed, and
    /// re-fetching one of those is the expensive case worth avoiding.
    public func thumbnail(momentID: String) async throws -> ArtifactPayload {
        try await daemon.thumbnail(momentID: momentID, maxEdge: nil)
    }

    public func ocrEvidence(momentID: String) async throws -> OcrEvidence {
        try await daemon.evidenceOcr(momentID: momentID)
    }

    public func prefetch(artifactIDs: [String]) async {
        for id in artifactIDs where cache.object(forKey: id as NSString) == nil {
            _ = try? await data(artifactID: id)
        }
    }

    public func clearSensitiveData() {
        generation &+= 1
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        for artifactID in cachedArtifactIDs {
            guard let data = cache.object(forKey: artifactID as NSString) as? NSMutableData else {
                continue
            }
            data.resetBytes(in: NSRange(location: 0, length: data.length))
        }
        cachedArtifactIDs.removeAll()
        cache.removeAllObjects()
    }

    private static func fetch(daemon: any RecallDaemonServing, artifactID: String) async throws -> Data {
        if artifactID.hasPrefix("gop:") {
            let body = artifactID.dropFirst(4)
            let parts = body.split(separator: "#", maxSplits: 1)
            guard parts.count == 2, let index = UInt16(parts[1]) else {
                throw DaemonClientError.invalidResponse
            }
            return try await daemon.gopFrame(
                segmentID: String(parts[0]),
                index: index,
                mode: "exact"
            ).bytes
        }
        return try await daemon.artifact(id: artifactID).bytes
    }
}

@MainActor
public protocol RecallAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var isBuffering: Bool { get }
    var playingArtifactID: String? { get }
    func toggle(moment: RecallMoment)
    func play(moment: RecallMoment)
    func pause()
    func stop()
}
