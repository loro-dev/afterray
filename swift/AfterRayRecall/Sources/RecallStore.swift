import Foundation

@MainActor
public final class RecallStore: ObservableObject {
    @Published public private(set) var sessions: [RecallSession] = []
    @Published public private(set) var moments: [RecallMoment] = []
    @Published public private(set) var playheadMs: Int64 = 0
    /// Kept for API compatibility, but not published separately: `playheadMs`
    /// is the observable source of truth and publishing both doubled updates.
    public private(set) var selectedIndex: Int = 0
    @Published public private(set) var loadState: RecallLoadState = .ready
    @Published public private(set) var daySummary: DaySummary = .empty
    @Published public private(set) var summaryHistory: [DaySummary] = []
    @Published public private(set) var summaryHistoryHasMore = false
    @Published public private(set) var isLoadingSummaryHistory = false

    private let daemon: any RecallDaemonServing
    private var sensitiveGeneration: UInt64 = 0
    private var timelineRevision: UInt64 = 0
    /// Rebuilt with `moments`; see `selectLoaded`.
    private var capturedAtMsByMomentID: [String: Int64] = [:]
    /// Prepared with the timeline off-main. Recomputing the median capture
    /// interval inside every selection made the final scrub commit O(n log n).
    private var timelineBounds: (startMs: Int64, endMs: Int64) = (0, 1)
    private var loadedDayKey: String?
    private var summaryHistoryCursorMs: Int64?
    private var summaryHistoryGeneration: UInt64 = 0

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
            let rawMoments = try await daemon.timeline()
            let prepared = await Self.prepareTimeline(rawMoments)
            guard sensitiveGeneration == requestGeneration else { return }
            sessions = loadedSessions
            apply(prepared, preservingSelection: preservingSelection)
            await loadDaySummary(dayMs: playheadMs, force: true)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) {
                return
            }
            moments = []
            timelineRevision &+= 1
            capturedAtMsByMomentID = [:]
            timelineBounds = (0, 1)
            applyPlayhead(0)
            daySummary = .empty
            loadedDayKey = nil
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
        let requestRevision = timelineRevision
        let requestGeneration = sensitiveGeneration
        do {
            let rawUpdated = try await daemon.timeline(sinceMs: sinceMs)
            guard sensitiveGeneration == requestGeneration,
                  timelineRevision == requestRevision
            else { return }
            guard !rawUpdated.isEmpty else { return }
            let current = moments
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                Self.mergeTimeline(current: current, sinceMs: sinceMs, updated: rawUpdated)
            }).value else { return }
            guard sensitiveGeneration == requestGeneration,
                  timelineRevision == requestRevision
            else { return }
            apply(prepared, preservingSelection: preservingSelection)
            await loadDaySummary(dayMs: playheadMs, force: true)
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
        let rawMoments = try await daemon.moments(sessionID: id)
        let prepared = await Self.prepareTimeline(rawMoments)
        guard sensitiveGeneration == requestGeneration else { return }
        apply(prepared, selecting: momentID, preservingSelection: preservingSelection)
        await loadDaySummary(dayMs: playheadMs, force: true)
    }

    private func apply(
        _ prepared: PreparedTimeline,
        selecting momentID: String? = nil,
        preservingSelection: Bool = false
    ) {
        // Read the selection after the daemon request returns. The user may
        // continue scrubbing while that request is in flight, and the refresh
        // must preserve their newest position rather than a stale snapshot.
        let preservedMomentID = preservingSelection ? selectedMoment?.id : nil
        let preservedPlayheadMs = playheadMs
        let loaded = prepared.moments
        moments = loaded
        timelineRevision &+= 1
        // Walking search results asks "where is this id?" on every scroll tick,
        // and the timeline is the whole archive — scanning it per tick is the
        // one part of stepping that grew with how long AfterRay had been
        // recording.
        capturedAtMsByMomentID = prepared.capturedAtMsByMomentID
        timelineBounds = prepared.bounds
        if let targetID = momentID, let capturedAtMs = prepared.capturedAtMsByMomentID[targetID] {
            applyPlayhead(capturedAtMs)
        } else if preservingSelection {
            let bounds = prepared.bounds
            if !loaded.isEmpty, preservedPlayheadMs >= bounds.startMs, preservedPlayheadMs <= bounds.endMs {
                applyPlayhead(preservedPlayheadMs)
            } else if let preservedMomentID,
                      let capturedAtMs = prepared.capturedAtMsByMomentID[preservedMomentID]
            {
                applyPlayhead(capturedAtMs)
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
            let rawMoments = try await daemon.timeline()
            let prepared = await Self.prepareTimeline(rawMoments)
            guard sensitiveGeneration == requestGeneration else { return }
            apply(prepared, selecting: momentID)
            await loadDaySummary(dayMs: playheadMs, force: true)
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
        guard let capturedAtMs = capturedAtMsByMomentID[momentID] else { return false }
        applyPlayhead(capturedAtMs)
        return true
    }

    public func select(playheadMs ms: Int64) {
        applyPlayhead(ms)
    }

    public func loadDaySummary(dayMs: Int64, force: Bool = false) async {
        let key = DaySummaryLayout.localDayKey(ms: dayMs)
        if !force, key == loadedDayKey { return }
        let requestGeneration = sensitiveGeneration
        do {
            let loaded = try await daemon.daySummary(dayMs: dayMs)
            guard sensitiveGeneration == requestGeneration else { return }
            daySummary = loaded
            loadedDayKey = key

            let initializesHistory = summaryHistory.isEmpty
            upsertSummaryHistory(loaded)
            guard initializesHistory else { return }

            summaryHistoryGeneration &+= 1
            summaryHistoryCursorMs = loaded.dayStartMs
            summaryHistoryHasMore = true
            isLoadingSummaryHistory = false
            await loadOlderSummaryHistory()
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) { return }
        }
    }

    /// Fetches one small page when the history-summary panel reaches its
    /// bottom. Keeping this cursor in the store avoids virtual-list rows ever
    /// querying the daemon on their own.
    public func loadOlderSummaryHistory() async {
        guard summaryHistoryHasMore,
              !isLoadingSummaryHistory,
              let beforeMs = summaryHistoryCursorMs
        else { return }

        isLoadingSummaryHistory = true
        let requestGeneration = summaryHistoryGeneration
        let sensitiveRequestGeneration = sensitiveGeneration
        do {
            let page = try await daemon.summaryHistory(beforeMs: beforeMs, limit: 7)
            guard sensitiveGeneration == sensitiveRequestGeneration,
                  summaryHistoryGeneration == requestGeneration
            else { return }
            let knownDays = Set(summaryHistory.map(\.dayStartMs))
            summaryHistory.append(contentsOf: page.days.filter { !knownDays.contains($0.dayStartMs) })
            // A direct playhead jump can insert a day older than this cursor
            // before pagination fills the gap. Keep display order independent
            // of the order in which those two request paths finish.
            summaryHistory.sort { $0.dayStartMs > $1.dayStartMs }
            summaryHistoryCursorMs = page.nextBeforeMs
            summaryHistoryHasMore = page.hasMore && page.nextBeforeMs != nil
        } catch {
            guard sensitiveGeneration == sensitiveRequestGeneration,
                  summaryHistoryGeneration == requestGeneration
            else { return }
            if !Self.isDaemonConnectionError(error) {
                summaryHistoryHasMore = false
            }
        }
        if summaryHistoryGeneration == requestGeneration {
            isLoadingSummaryHistory = false
        }
    }

    /// Refresh the selected day without replacing the history around it.
    /// Pagination owns the cursor; moving the playhead must not rewind it.
    private func upsertSummaryHistory(_ loaded: DaySummary) {
        if let index = summaryHistory.firstIndex(where: { $0.dayStartMs == loaded.dayStartMs }) {
            summaryHistory[index] = loaded
        } else {
            summaryHistory.append(loaded)
            summaryHistory.sort { $0.dayStartMs > $1.dayStartMs }
        }
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
        timelineRevision &+= 1
        capturedAtMsByMomentID = [:]
        timelineBounds = (0, 1)
        applyPlayhead(0)
        daySummary = .empty
        summaryHistory = []
        summaryHistoryHasMore = false
        summaryHistoryCursorMs = nil
        summaryHistoryGeneration &+= 1
        isLoadingSummaryHistory = false
        loadedDayKey = nil
        loadState = .ready
    }

    private func applyPlayhead(_ ms: Int64) {
        playheadMs = moments.isEmpty
            ? 0
            : min(max(ms, timelineBounds.startMs), timelineBounds.endMs)
        selectedIndex = RecallPlayhead.resolveIndex(playheadMs: playheadMs, moments: moments) ?? 0
    }

    private struct PreparedTimeline: Sendable {
        let moments: [RecallMoment]
        let capturedAtMsByMomentID: [String: Int64]
        let bounds: (startMs: Int64, endMs: Int64)
    }

    nonisolated private static func prepareTimeline(
        _ moments: [RecallMoment]
    ) async -> PreparedTimeline {
        await Task.detached(priority: .userInitiated) {
            prepareTimelineSync(moments)
        }.value
    }

    nonisolated private static func prepareTimelineSync(
        _ moments: [RecallMoment]
    ) -> PreparedTimeline {
        let sorted = moments.sorted { left, right in
            if left.capturedAtMs == right.capturedAtMs { return left.id < right.id }
            return left.capturedAtMs < right.capturedAtMs
        }
        return prepareSortedTimeline(sorted)
    }

    nonisolated private static func prepareSortedTimeline(
        _ sorted: [RecallMoment]
    ) -> PreparedTimeline {
        return PreparedTimeline(
            moments: sorted,
            capturedAtMsByMomentID: Dictionary(
                sorted.lazy.map { ($0.id, $0.capturedAtMs) },
                uniquingKeysWith: { first, _ in first }
            ),
            bounds: TimelineLayout.timeBounds(moments: sorted)
        )
    }

    nonisolated private static func mergeTimeline(
        current: [RecallMoment],
        sinceMs: Int64,
        updated: [RecallMoment]
    ) -> PreparedTimeline? {
        let sortedUpdate = prepareTimelineSync(updated).moments
        let prefixCount = current.partitioningIndex { $0.capturedAtMs >= sinceMs }
        guard Array(current.dropFirst(prefixCount)) != sortedUpdate else { return nil }
        var merged = Array(current.prefix(prefixCount))
        merged.append(contentsOf: sortedUpdate)
        return prepareSortedTimeline(merged)
    }

    private static func isDaemonConnectionError(_ error: Error) -> Bool {
        guard let daemonError = error as? DaemonClientError else { return false }
        if case .connection = daemonError { return true }
        return false
    }
}

private extension RandomAccessCollection {
    /// First index whose element satisfies `belongsInSecondPartition`.
    func partitioningIndex(
        where belongsInSecondPartition: (Element) -> Bool
    ) -> Index {
        var lower = startIndex
        var upper = endIndex
        while lower != upper {
            let distance = distance(from: lower, to: upper)
            let middle = index(lower, offsetBy: distance / 2)
            if belongsInSecondPartition(self[middle]) {
                upper = middle
            } else {
                lower = index(after: middle)
            }
        }
        return lower
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
        if artifactID.hasPrefix("gop-poster:") {
            let body = artifactID.dropFirst("gop-poster:".count)
            let parts = body.split(separator: "#", maxSplits: 1)
            guard parts.count == 2, let index = UInt16(parts[1]) else {
                throw DaemonClientError.invalidResponse
            }
            return try await daemon.gopFrame(
                segmentID: String(parts[0]),
                index: index,
                mode: "poster"
            ).bytes
        }
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
