import Foundation

/// Which end of the loaded playhead window to grow.
public enum TimelineExtendDirection: Hashable, Sendable {
    case older
    case newer
}

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
    @Published public private(set) var summaryHistoryTotalDays: Int?
    @Published public private(set) var isLoadingSummaryHistory = false
    /// Detail-only fields for the current selection. Evidence must never be
    /// written back into the 26K-row timeline array: doing so invalidates its
    /// prepared spine and turns one `moment_get` into an O(n) search plus a
    /// full layout rebuild just before the next scrub.
    @Published private var selectedMomentDetail: RecallMoment? = nil

    private let daemon: any RecallDaemonServing
    private var sensitiveGeneration: UInt64 = 0
    /// Changes exactly when the timeline rows change. The view uses this
    /// scalar instead of comparing a 20K-element array after every publish.
    public private(set) var timelineRevision: UInt64 = 0
    /// Geometry derived from `moments` on a worker before the rows publish.
    /// Nil means a rare in-place timeline mutation (currently favorite state)
    /// invalidated the prepared value and the view should rebuild it once.
    public private(set) var timelineSpine: TimelineSpine?
    /// Replacing or recentering the local-day window invalidates an adjacent
    /// fetch. A routine refresh does not: it only enriches the same window,
    /// and must not make a neighbour disappear while a scrub is in flight.
    private var timelineWindowGeneration: UInt64 = 0
    /// Rebuilt with `moments`; see `selectLoaded`.
    private var capturedAtMsByMomentID: [String: Int64] = [:]
    /// Prepared with the timeline off-main. Recomputing the median capture
    /// interval inside every selection made the final scrub commit O(n log n).
    private var timelineBounds: (startMs: Int64, endMs: Int64) = (0, 1)
    /// Inclusive-start / exclusive-end span of local days currently represented
    /// by `moments`, including probed empty days. Unlike `timelineBounds`, this
    /// must not collapse to `(0, 1)` when there are no captures because the
    /// live poll still needs a bounded query.
    private var loadedTimelineDayBounds: (start: Int64, end: Int64)?
    private var timelineHasOlder = true
    private var timelineHasNewer = true
    private struct InFlightTimelineExtend {
        let id: UInt64
        let direction: TimelineExtendDirection
        let windowGeneration: UInt64
        let task: Task<Bool, Never>
    }
    private var nextTimelineExtendID: UInt64 = 0
    private var inFlightExtend: InFlightTimelineExtend?
    private var loadedDayKey: String?
    private var summaryHistoryCursorMs: Int64?
    private var summaryHistoryGeneration: UInt64 = 0

    /// Occupied local-day data in the normal warm window. Sparse empty-day
    /// spans may cover more calendar days without adding timeline rows.
    public static let maxLoadedTimelineDays = TimelineWarmWindow.preloadRadiusDays * 2 + 1
    /// Empty local days to walk through when the previous/next calendar day
    /// has no captures.
    public static let emptyDaySkipLimit = 31

    public init(daemon: any RecallDaemonServing) {
        self.daemon = daemon
    }

    public var selectedMoment: RecallMoment? {
        guard let base = RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments)
        else { return nil }
        guard let detail = selectedMomentDetail, detail.id == base.id else { return base }
        // Timeline geometry and favorite state remain authoritative in `base`.
        // Only fields intentionally omitted from or optional in the lean index
        // are overlaid from the selected-detail read model.
        // Audio is atomic: transcript, artifact, and bounds all come from the
        // same selected segment rather than being merged field by field.
        let audioOwner = detail.audioSegmentId == nil ? base : detail
        return RecallMoment(
            id: base.id,
            sessionId: base.sessionId,
            capturedAtMs: base.capturedAtMs,
            imageArtifactId: base.imageArtifactId ?? detail.imageArtifactId,
            isFavorite: base.isFavorite,
            gop: base.gop ?? detail.gop,
            stillOrigin: base.stillOrigin,
            ocrText: detail.ocrText,
            transcriptText: audioOwner.transcriptText,
            transcriptCues: audioOwner.transcriptCues,
            audioSegmentId: audioOwner.audioSegmentId,
            audioArtifactId: audioOwner.audioArtifactId,
            audioStartedAtMs: audioOwner.audioStartedAtMs,
            audioEndedAtMs: audioOwner.audioEndedAtMs,
            accessibilityArtifactId: detail.accessibilityArtifactId
                ?? base.accessibilityArtifactId,
            applicationName: base.applicationName ?? detail.applicationName,
            bundleIdentifier: base.bundleIdentifier ?? detail.bundleIdentifier,
            windowTitle: base.windowTitle ?? detail.windowTitle,
            url: base.url ?? detail.url,
            document: base.document ?? detail.document
        )
    }

    public var timelineDayCoverage: TimelineDayCoverage? {
        loadedTimelineDayBounds.map { TimelineDayCoverage(start: $0.start, end: $0.end) }
    }

    // @dec:pointer-centered-timeline-day-window — docs/decisions/active/architecture/2026-08-22-pointer-centered-timeline-day-window.md
    public func loadTimeline(
        containingMs requestedMs: Int64? = nil,
        preservingSelection: Bool = false
    ) async {
        let requestGeneration = sensitiveGeneration
        timelineWindowGeneration &+= 1
        let requestWindowGeneration = timelineWindowGeneration
        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let anchorMs = requestedMs
            ?? (playheadMs > 0 ? playheadMs : nowMs)
        // Publish the first usable timeline only after the pointer's whole
        // seven-day preload window is present. The inner two days on either
        // side are the interaction invariant; the outer day is refill reserve.
        // Loading one day first made yesterday an edge-path dependency even
        // when prefetch started immediately afterwards.
        let bounds = TimelineWarmWindow.bounds(containingMs: anchorMs)
        // History cards are an independent read model. Start them before the
        // playhead request so a slow/failed range cannot hold the panel empty.
        async let summaryLoad: Void = loadDaySummary(dayMs: anchorMs, force: true)
        do {
            let loadedSessions = (try? await daemon.sessions())?.sorted { $0.startedAtMs < $1.startedAtMs } ?? []
            let rawMoments = try await daemon.timeline(fromMs: bounds.start, toMs: bounds.end - 1)
            let prepared = await Self.prepareTimeline(rawMoments)
            guard sensitiveGeneration == requestGeneration,
                  timelineWindowGeneration == requestWindowGeneration
            else { return }
            sessions = loadedSessions
            loadedTimelineDayBounds = bounds
            timelineHasOlder = true
            timelineHasNewer = bounds.end < DaySummaryLayout.dayBounds(ms: nowMs).end
            apply(prepared, preservingSelection: preservingSelection)
        } catch {
            guard sensitiveGeneration == requestGeneration,
                  timelineWindowGeneration == requestWindowGeneration
            else { return }
            if Self.isDaemonConnectionError(error), case .failed = loadState {
                await summaryLoad
                return
            }
            if !Self.isDaemonConnectionError(error) {
                timelineRevision &+= 1
                timelineSpine = nil
                moments = []
                capturedAtMsByMomentID = [:]
                timelineBounds = (0, 1)
                applyPlayhead(0)
                loadedTimelineDayBounds = nil
                timelineHasOlder = true
                timelineHasNewer = true
                loadedDayKey = nil
            }
            loadState = .failed(message: error.localizedDescription)
        }
        await summaryLoad
    }

    /// Refreshes the newest loaded captures so recently completed OCR/AX work
    /// can replace existing moments without scanning the vault. Older days
    /// already in the window stay in memory.
    public func refreshTimeline(preservingSelection: Bool = true) async {
        guard !moments.isEmpty else {
            guard let bounds = loadedTimelineDayBounds else {
                await loadTimeline(preservingSelection: preservingSelection)
                return
            }
            await refreshTimeline(
                fromMs: bounds.start,
                toMs: bounds.end - 1,
                replacingFromMs: bounds.start,
                preservingSelection: preservingSelection
            )
            return
        }

        let overlapStart = max(moments.count - 20, 0)
        let sinceMs = moments[overlapStart].capturedAtMs
        let bounds = loadedTimelineDayBounds
            ?? DaySummaryLayout.dayBounds(ms: moments[overlapStart].capturedAtMs)
        await refreshTimeline(
            fromMs: sinceMs,
            toMs: bounds.end - 1,
            replacingFromMs: sinceMs,
            preservingSelection: preservingSelection
        )
    }

    private func refreshTimeline(
        fromMs: Int64,
        toMs: Int64,
        replacingFromMs: Int64,
        preservingSelection: Bool
    ) async {
        let requestRevision = timelineRevision
        let requestGeneration = sensitiveGeneration
        do {
            let rawUpdated = try await daemon.timeline(fromMs: fromMs, toMs: toMs)
            guard sensitiveGeneration == requestGeneration,
                  timelineRevision == requestRevision
            else { return }
            let current = moments
            guard let prepared = await Task.detached(priority: .userInitiated, operation: {
                Self.mergeTimeline(current: current, sinceMs: replacingFromMs, updated: rawUpdated)
            }).value else { return }
            guard sensitiveGeneration == requestGeneration,
                  timelineRevision == requestRevision
            else { return }
            apply(prepared, preservingSelection: preservingSelection)
            let summaryMs = playheadMs > 0 ? playheadMs : fromMs
            await loadDaySummary(dayMs: summaryMs, force: true)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) {
                if case .failed = loadState { return }
                loadState = .failed(message: error.localizedDescription)
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
        timelineWindowGeneration &+= 1
        let requestWindowGeneration = timelineWindowGeneration
        let rawMoments = try await daemon.moments(sessionID: id)
        let prepared = await Self.prepareTimeline(rawMoments)
        guard sensitiveGeneration == requestGeneration,
              timelineWindowGeneration == requestWindowGeneration
        else { return }
        if let first = prepared.moments.first, let last = prepared.moments.last {
            let start = DaySummaryLayout.dayBounds(ms: first.capturedAtMs).start
            let end = DaySummaryLayout.dayBounds(ms: last.capturedAtMs).end
            loadedTimelineDayBounds = (start, end)
            let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
            timelineHasOlder = true
            timelineHasNewer = end < DaySummaryLayout.dayBounds(ms: nowMs).end
        } else {
            loadedTimelineDayBounds = nil
        }
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
        timelineSpine = prepared.spine
        timelineRevision &+= 1
        moments = loaded
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

    /// Loads the warm window that contains `momentID` and parks the playhead on it.
    public func openMoment(id momentID: String) async {
        guard !Task.isCancelled else { return }
        if selectLoaded(momentID: momentID) {
            await hydrateSelectedEvidence()
            return
        }
        let requestGeneration = sensitiveGeneration
        do {
            let detail = try await daemon.moment(id: momentID)
            guard !Task.isCancelled else { return }
            await ensureTimelineContains(ms: detail.capturedAtMs)
            guard !Task.isCancelled,
                  sensitiveGeneration == requestGeneration
            else { return }
            if selectLoaded(momentID: momentID) {
                patchEvidence(detail)
                await loadDaySummary(dayMs: detail.capturedAtMs, force: true)
                guard !Task.isCancelled else { return }
                await hydrateSelectedEvidence()
                return
            }
            let bounds = DaySummaryLayout.dayBounds(ms: detail.capturedAtMs)
            let rawMoments = try await daemon.timeline(fromMs: bounds.start, toMs: bounds.end - 1)
            guard !Task.isCancelled else { return }
            let prepared = await Self.prepareTimeline(rawMoments)
            guard !Task.isCancelled,
                  sensitiveGeneration == requestGeneration
            else { return }
            loadedTimelineDayBounds = bounds
            let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
            timelineHasOlder = true
            timelineHasNewer = bounds.end < DaySummaryLayout.dayBounds(ms: nowMs).end
            apply(prepared, selecting: momentID)
            patchEvidence(detail)
            await loadDaySummary(dayMs: detail.capturedAtMs, force: true)
        } catch {
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) {
                loadState = .failed(message: error.localizedDescription)
                return
            }
            loadState = .failed(message: error.localizedDescription)
        }
    }

    /// Grows the playhead window by one occupied neighbour in `direction`.
    /// Empty local days are skipped so a gap between captures is still one
    /// scrub, not a dead end.
    @discardableResult
    public func extendTimeline(
        direction: TimelineExtendDirection,
        aroundMs anchorMs: Int64? = nil
    ) async -> Bool {
        let requestSensitiveGeneration = sensitiveGeneration
        let windowGeneration = timelineWindowGeneration
        let resolvedAnchorMs = anchorMs ?? (playheadMs > 0 ? playheadMs : loadedTimelineDayBounds?.start ?? 0)
        if let existing = inFlightExtend,
           existing.windowGeneration == windowGeneration
        {
            let result = await existing.task.value
            if inFlightExtend?.id == existing.id {
                inFlightExtend = nil
            }
            let required = TimelineDayCoverage.warmWindow(containingMs: resolvedAnchorMs)
            if let coverage = timelineDayCoverage {
                let stillMissing = direction == .older
                    ? coverage.start > required.start
                    : coverage.end < required.end
                if existing.direction != direction || stillMissing {
                    return await extendTimeline(direction: direction, aroundMs: resolvedAnchorMs)
                }
            }
            return result
        }
        nextTimelineExtendID &+= 1
        let requestID = nextTimelineExtendID
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performTimelineExtend(
                direction: direction,
                anchorMs: resolvedAnchorMs,
                requestGeneration: requestSensitiveGeneration,
                requestWindowGeneration: windowGeneration
            )
        }
        inFlightExtend = InFlightTimelineExtend(
            id: requestID,
            direction: direction,
            windowGeneration: windowGeneration,
            task: task
        )
        let result = await task.value
        if inFlightExtend?.id == requestID {
            inFlightExtend = nil
        }
        return result
    }

    private func performTimelineExtend(
        direction: TimelineExtendDirection,
        anchorMs: Int64,
        requestGeneration: UInt64,
        requestWindowGeneration: UInt64
    ) async -> Bool {
        guard sensitiveGeneration == requestGeneration,
              timelineWindowGeneration == requestWindowGeneration
        else { return false }
        guard let range = loadedTimelineDayBounds else { return false }

        let nowMs = Int64(Date.now.timeIntervalSince1970 * 1_000)
        let today = DaySummaryLayout.dayBounds(ms: nowMs)
        let required = TimelineDayCoverage.warmWindow(containingMs: anchorMs)
        var nextBounds: TimelineDayCoverage
        switch direction {
        case .older:
            guard timelineHasOlder else { return false }
            if range.start > required.start {
                nextBounds = TimelineDayCoverage(start: required.start, end: range.start)
            } else {
                let day = DaySummaryLayout.dayBounds(ms: range.start - 1)
                nextBounds = TimelineDayCoverage(start: day.start, end: day.end)
            }
        case .newer:
            guard timelineHasNewer else { return false }
            if range.end >= today.end {
                timelineHasNewer = false
                return false
            }
            let requiredEnd = min(required.end, today.end)
            if range.end < requiredEnd {
                nextBounds = TimelineDayCoverage(start: range.end, end: requiredEnd)
            } else {
                let day = DaySummaryLayout.dayBounds(ms: range.end)
                nextBounds = TimelineDayCoverage(start: day.start, end: day.end)
            }
        }

        var probedCoverage = nextBounds
        var skippedEmpty = 0
        while skippedEmpty <= Self.emptyDaySkipLimit {
            guard sensitiveGeneration == requestGeneration,
                  timelineWindowGeneration == requestWindowGeneration
            else { return false }
            let bounds = nextBounds
            if let covered = loadedTimelineDayBounds,
               bounds.start >= covered.start,
               bounds.end <= covered.end
            {
                return false
            }
            if direction == .newer, bounds.start >= today.end {
                timelineHasNewer = false
                return false
            }
            do {
                let raw = try await daemon.timeline(fromMs: bounds.start, toMs: bounds.end - 1)
                guard sensitiveGeneration == requestGeneration,
                      timelineWindowGeneration == requestWindowGeneration
                else { return false }
                probedCoverage = TimelineDayCoverage(
                    start: min(probedCoverage.start, bounds.start),
                    end: max(probedCoverage.end, bounds.end)
                )
                if raw.isEmpty {
                    skippedEmpty += 1
                    switch direction {
                    case .older:
                        let day = DaySummaryLayout.dayBounds(ms: bounds.start - 1)
                        nextBounds = TimelineDayCoverage(start: day.start, end: day.end)
                    case .newer:
                        let day = DaySummaryLayout.dayBounds(ms: bounds.end)
                        nextBounds = TimelineDayCoverage(start: day.start, end: day.end)
                    }
                    continue
                }
                let added = await Self.sortedMoments(raw)
                guard sensitiveGeneration == requestGeneration,
                      timelineWindowGeneration == requestWindowGeneration
                else { return false }
                // A recording refresh may finish while the detached merge is
                // running. Rebase on its newest rows instead of treating that
                // harmless revision as a failed neighbouring-day fetch.
                while true {
                    let current = moments
                    let mergeRevision = timelineRevision
                    let currentCoverage = timelineDayCoverage ?? probedCoverage
                    let availableCoverage = TimelineDayCoverage(
                        start: min(currentCoverage.start, probedCoverage.start),
                        end: max(currentCoverage.end, probedCoverage.end)
                    )
                    let retainedCoverage = TimelineWarmWindow.retainedCoverage(
                        available: availableCoverage,
                        containingMs: anchorMs,
                        including: TimelineDayCoverage(start: bounds.start, end: bounds.end)
                    )
                    let merged = await Task.detached(priority: .userInitiated, operation: {
                        Self.mergeAndTrimPrepared(
                            current: current,
                            added: added,
                            retaining: retainedCoverage
                        )
                    }).value
                    guard sensitiveGeneration == requestGeneration,
                          timelineWindowGeneration == requestWindowGeneration
                    else { return false }
                    guard timelineRevision == mergeRevision else { continue }
                    loadedTimelineDayBounds = (
                        retainedCoverage.start,
                        retainedCoverage.end
                    )
                    if retainedCoverage.start > availableCoverage.start {
                        timelineHasOlder = true
                    }
                    if retainedCoverage.end < availableCoverage.end {
                        timelineHasNewer = true
                    }
                    apply(merged, preservingSelection: true)
                    return true
                }
            } catch {
                guard sensitiveGeneration == requestGeneration else { return false }
                if Self.isDaemonConnectionError(error), case .failed = loadState {
                    return false
                }
                loadState = .failed(message: error.localizedDescription)
                return false
            }
        }
        guard sensitiveGeneration == requestGeneration,
              timelineWindowGeneration == requestWindowGeneration
        else { return false }
        // Every probe was empty. Coverage still advances: otherwise the same
        // known-empty calendar span looks cold again on the next gesture even
        // though there are no rows (and therefore no layout) to publish.
        if let currentCoverage = timelineDayCoverage {
            loadedTimelineDayBounds = (
                min(currentCoverage.start, probedCoverage.start),
                max(currentCoverage.end, probedCoverage.end)
            )
        } else {
            loadedTimelineDayBounds = (probedCoverage.start, probedCoverage.end)
        }
        switch direction {
        case .older: timelineHasOlder = false
        case .newer: timelineHasNewer = false
        }
        return false
    }

    /// Replenishes the outer reserve around the settled playhead while the
    /// inner two-calendar-day interaction cushion is still present.
    /// `loadTimeline` establishes all seven days atomically; later calls
    /// normally add one outer day after the pointer crosses midnight.
    public func prefetchAdjacentTimelineDays() async {
        guard !Task.isCancelled else { return }
        guard let range = loadedTimelineDayBounds else { return }
        let anchorMs = playheadMs > 0 ? playheadMs : range.start
        let required = TimelineWarmWindow.bounds(containingMs: anchorMs)

        while let loaded = loadedTimelineDayBounds, loaded.start > required.start {
            guard !Task.isCancelled else { return }
            let previousStart = loaded.start
            _ = await extendTimeline(direction: .older)
            guard !Task.isCancelled else { return }
            guard let expanded = loadedTimelineDayBounds, expanded.start < previousStart else {
                break
            }
        }
        while let loaded = loadedTimelineDayBounds, loaded.end < required.end {
            guard !Task.isCancelled else { return }
            let previousEnd = loaded.end
            _ = await extendTimeline(direction: .newer)
            guard !Task.isCancelled else { return }
            guard let expanded = loadedTimelineDayBounds, expanded.end > previousEnd else {
                break
            }
        }
    }

    /// Makes sure `ms` is inside the loaded span. Adjacent days merge;
    /// a jump of more than one local day recentres the window.
    public func ensureTimelineContains(ms: Int64) async {
        let bounds = DaySummaryLayout.dayBounds(ms: ms)
        if covers(ms: ms) { return }
        if let range = loadedTimelineDayBounds, isCalendarAdjacent(bounds, to: range) {
            let direction: TimelineExtendDirection = bounds.end <= range.start ? .older : .newer
            while !covers(ms: ms) {
                let progressed = await extendTimeline(direction: direction)
                if !progressed { break }
            }
            if covers(ms: ms) { return }
        }
        await loadTimeline(containingMs: ms, preservingSelection: false)
    }

    /// Fills OCR/transcript for the selected read model via `moment_get`.
    /// The timeline array and prepared spine remain unchanged.
    public func hydrateSelectedEvidence() async {
        guard let selected = RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments)
        else { return }
        if selectedMomentDetail?.id == selected.id { return }
        let requestGeneration = sensitiveGeneration
        let momentID = selected.id
        do {
            let detail = try await daemon.moment(id: momentID)
            guard !Task.isCancelled,
                  sensitiveGeneration == requestGeneration,
                  RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments)?.id == momentID
            else { return }
            patchEvidence(detail)
        } catch {
            guard !Task.isCancelled else { return }
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) { return }
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

    /// Selects the newest captured moment already loaded in the timeline.
    /// The app pairs this with its `isLive` state in one UI transaction when
    /// returning to NOW.
    @discardableResult
    public func selectLatestMoment() -> Bool {
        guard let latest = moments.last else { return false }
        applyPlayhead(latest.capturedAtMs)
        return true
    }

    public func loadDaySummary(dayMs: Int64, force: Bool = false) async {
        let key = DaySummaryLayout.localDayKey(ms: dayMs)
        if !force, key == loadedDayKey { return }
        let requestGeneration = sensitiveGeneration
        do {
            let loaded = try await daemon.daySummary(dayMs: dayMs)
            guard !Task.isCancelled, sensitiveGeneration == requestGeneration else { return }
            daySummary = loaded
            loadedDayKey = key
            guard !loaded.day.isEmpty else { return }

            let initializesHistory = summaryHistory.isEmpty
            upsertSummaryHistory(loaded)
            guard initializesHistory else { return }

            summaryHistoryGeneration &+= 1
            summaryHistoryCursorMs = loaded.dayStartMs
            summaryHistoryHasMore = true
            isLoadingSummaryHistory = false
            guard !Task.isCancelled else { return }
            await loadOlderSummaryHistory()
        } catch {
            guard !Task.isCancelled else { return }
            guard sensitiveGeneration == requestGeneration else { return }
            if Self.isDaemonConnectionError(error) { return }
        }
    }

    /// Fetches one small page when the history-summary panel reaches its
    /// bottom. This cursor is the only thing that walks the vault, so a
    /// row never queries the daemon on its own.
    public func loadOlderSummaryHistory() async {
        guard summaryHistoryHasMore,
              !isLoadingSummaryHistory,
              let beforeMs = summaryHistoryCursorMs
        else { return }

        isLoadingSummaryHistory = true
        let requestGeneration = summaryHistoryGeneration
        let sensitiveRequestGeneration = sensitiveGeneration
        defer {
            if summaryHistoryGeneration == requestGeneration {
                isLoadingSummaryHistory = false
            }
        }
        do {
            let page = try await daemon.summaryHistory(beforeMs: beforeMs, limit: 7)
            guard !Task.isCancelled,
                  sensitiveGeneration == sensitiveRequestGeneration,
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
            if let totalDays = page.totalDays {
                summaryHistoryTotalDays = totalDays
            }
        } catch {
            guard !Task.isCancelled else { return }
            guard sensitiveGeneration == sensitiveRequestGeneration,
                  summaryHistoryGeneration == requestGeneration
            else { return }
            if !Self.isDaemonConnectionError(error) {
                summaryHistoryHasMore = false
            }
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
        timelineSpine = nil
        timelineRevision &+= 1
        moments[index].isFavorite.toggle()
        do {
            try await daemon.setFavorite(momentID: momentID, favorite: !previous)
        } catch {
            guard let index = moments.firstIndex(where: { $0.id == momentID }) else { return }
            timelineSpine = nil
            timelineRevision &+= 1
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
        selectedMomentDetail = nil
        sessions = []
        timelineSpine = nil
        timelineRevision &+= 1
        moments = []
        capturedAtMsByMomentID = [:]
        timelineBounds = (0, 1)
        loadedTimelineDayBounds = nil
        timelineHasOlder = true
        timelineHasNewer = true
        applyPlayhead(0)
        daySummary = .empty
        summaryHistory = []
        summaryHistoryHasMore = false
        summaryHistoryTotalDays = nil
        summaryHistoryCursorMs = nil
        summaryHistoryGeneration &+= 1
        isLoadingSummaryHistory = false
        loadedDayKey = nil
        loadState = .ready
    }

    private func covers(ms: Int64) -> Bool {
        guard let range = loadedTimelineDayBounds else { return false }
        return ms >= range.start && ms < range.end
    }

    private func isCalendarAdjacent(
        _ bounds: (start: Int64, end: Int64),
        to range: (start: Int64, end: Int64)
    ) -> Bool {
        bounds.end == range.start || bounds.start == range.end
    }

    private func applyPlayhead(_ ms: Int64) {
        let next = moments.isEmpty
            ? 0
            : min(max(ms, timelineBounds.startMs), timelineBounds.endMs)
        let nextIndex = RecallPlayhead.resolveIndex(playheadMs: next, moments: moments) ?? 0
        // Opening the overlay calls `selectLatestMoment` even when the
        // playhead is already there. Writing `@Published playheadMs` would
        // rebuild the whole recall tree on the same turn as `orderFront`.
        if next == playheadMs {
            selectedIndex = nextIndex
            return
        }
        playheadMs = next
        selectedIndex = nextIndex
    }

    private struct PreparedTimeline: Sendable {
        let moments: [RecallMoment]
        let capturedAtMsByMomentID: [String: Int64]
        let bounds: (startMs: Int64, endMs: Int64)
        let spine: TimelineSpine
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
        let sorted = sortMomentsSync(moments)
        return prepareSortedTimeline(sorted)
    }

    nonisolated private static func sortedMoments(
        _ moments: [RecallMoment]
    ) async -> [RecallMoment] {
        await Task.detached(priority: .userInitiated) {
            sortMomentsSync(moments)
        }.value
    }

    nonisolated private static func sortMomentsSync(
        _ moments: [RecallMoment]
    ) -> [RecallMoment] {
        moments.sorted { left, right in
            if left.capturedAtMs == right.capturedAtMs { return left.id < right.id }
            return left.capturedAtMs < right.capturedAtMs
        }
    }

    nonisolated private static func prepareSortedTimeline(
        _ sorted: [RecallMoment]
    ) -> PreparedTimeline {
        let bounds = TimelineLayout.timeBounds(moments: sorted)
        return PreparedTimeline(
            moments: sorted,
            capturedAtMsByMomentID: Dictionary(
                sorted.lazy.map { ($0.id, $0.capturedAtMs) },
                uniquingKeysWith: { first, _ in first }
            ),
            bounds: bounds,
            spine: TimelineSpine(moments: sorted, bounds: bounds)
        )
    }

    /// Adjacent day rows are already sorted and disjoint from the current
    /// window, so the common path is two filters plus one ordered append: O(n),
    /// with the median interval and spine then prepared on this worker. The
    /// overlap fallback keeps refresh/extension races correct without putting
    /// a dictionary and sort back on the MainActor.
    nonisolated private static func mergeAndTrimPrepared(
        current: [RecallMoment],
        added: [RecallMoment],
        retaining coverage: TimelineDayCoverage
    ) -> PreparedTimeline {
        let retainedCurrent = current.filter {
            $0.capturedAtMs >= coverage.start && $0.capturedAtMs < coverage.end
        }
        let retainedAdded = added.filter {
            $0.capturedAtMs >= coverage.start && $0.capturedAtMs < coverage.end
        }
        if retainedCurrent.isEmpty { return prepareSortedTimeline(retainedAdded) }
        if retainedAdded.isEmpty { return prepareSortedTimeline(retainedCurrent) }
        if let addedLast = retainedAdded.last,
           let currentFirst = retainedCurrent.first,
           addedLast.capturedAtMs < currentFirst.capturedAtMs
        {
            return prepareSortedTimeline(retainedAdded + retainedCurrent)
        }
        if let currentLast = retainedCurrent.last,
           let addedFirst = retainedAdded.first,
           currentLast.capturedAtMs < addedFirst.capturedAtMs
        {
            return prepareSortedTimeline(retainedCurrent + retainedAdded)
        }

        var byID: [String: RecallMoment] = Dictionary(
            uniqueKeysWithValues: retainedCurrent.map { ($0.id, $0) }
        )
        for moment in retainedAdded {
            byID[moment.id] = moment
        }
        return prepareTimelineSync(Array(byID.values))
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

    private func patchEvidence(_ detail: RecallMoment) {
        guard RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments)?.id == detail.id
        else { return }
        selectedMomentDetail = detail
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

    public func moment(id: String) async throws -> RecallMoment {
        try await daemon.moment(id: id)
    }

    /// Chat-card pixels: the hot still when it is still on disk, otherwise the
    /// exact GOP frame. Never the 360px filmstrip JPEG.
    public func chatPreviewBytes(for moment: RecallMoment) async throws -> Data {
        if let stillID = moment.imageArtifactId {
            do {
                return try await data(artifactID: stillID)
            } catch {
                if moment.gop == nil { throw error }
            }
        }
        if moment.gop != nil {
            return try await data(artifactID: moment.displayCacheKey)
        }
        throw DaemonClientError.missingData
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
    var playingMomentID: String? { get }
    func toggle(moment: RecallMoment)
    func play(moment: RecallMoment)
    func pause()
    func stop()
}
