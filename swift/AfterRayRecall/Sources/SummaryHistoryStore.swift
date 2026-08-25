import Foundation

// @dec:independent-summary-history-pager — docs/decisions/active/architecture/2026-08-25-independent-summary-history-pager.md
/// Owns the history document. Timeline selection cannot seed or move it.
@MainActor
public final class SummaryHistoryStore: ObservableObject {
    @Published public private(set) var state: SummaryHistoryState = .initial

    private let loader: any SummaryHistoryPageLoading
    private let pageSize: Int
    private var nextRequestID: UInt64 = 0
    private var newestRefreshID: UInt64 = 0
    private var acceptsLoads = true

    public init(loader: any SummaryHistoryPageLoading, pageSize: Int = 7) {
        self.loader = loader
        self.pageSize = pageSize
    }

    /// Loads exactly the cursor named by the current boundary. Repeated calls
    /// while a request is active are no-ops; the boundary is the de-duplication.
    public func loadNext() async {
        guard acceptsLoads,
              !Task.isCancelled,
              let initialCursor = state.boundary.cursorForLoad
        else { return }

        nextRequestID &+= 1
        let requestID = nextRequestID
        var cursor = initialCursor
        state.boundary = .loading(cursor, requestID: requestID)

        while acceptsLoads {
            guard !Task.isCancelled else {
                restoreLoadableIfCurrent(cursor: cursor, requestID: requestID)
                return
            }
            do {
                let page = try await loader.summaryHistory(
                    beforeMs: cursor.beforeMs,
                    limit: pageSize
                )
                guard isCurrentRequest(cursor: cursor, requestID: requestID) else { return }
                guard !Task.isCancelled else {
                    state.boundary = .loadable(cursor)
                    return
                }

                let visibleDays = page.days.filter { day in
                    day.slots.contains(where: DaySummaryLayout.isVisibleInPanel)
                }
                state.days = Self.merging(state.days, with: visibleDays)
                if let totalDays = page.totalDays {
                    state.totalDays = totalDays
                }

                guard page.hasMore else {
                    state.boundary = .end
                    return
                }
                guard let nextBeforeMs = page.nextBeforeMs else {
                    state.boundary = .failed(
                        cursor,
                        message: "History page did not provide its next cursor."
                    )
                    return
                }
                let nextCursor = SummaryHistoryCursor.before(nextBeforeMs)
                guard nextCursor != cursor else {
                    state.boundary = .failed(
                        cursor,
                        message: "History page did not advance its cursor."
                    )
                    return
                }

                if visibleDays.isEmpty {
                    cursor = nextCursor
                    state.boundary = .loading(cursor, requestID: requestID)
                    continue
                }
                state.boundary = .loadable(nextCursor)
                return
            } catch is CancellationError {
                guard isCurrentRequest(cursor: cursor, requestID: requestID) else { return }
                state.boundary = .loadable(cursor)
                return
            } catch {
                guard isCurrentRequest(cursor: cursor, requestID: requestID) else { return }
                state.boundary = .failed(cursor, message: error.localizedDescription)
                return
            }
        }
    }

    /// Refreshes only the newest page while preserving the tail cursor and
    /// every older page already loaded. This keeps live summaries current
    /// without coupling pagination to the timeline's selected day.
    public func refreshNewest() async {
        guard acceptsLoads else {
            await reload()
            return
        }
        guard !state.days.isEmpty else {
            await loadNext()
            return
        }
        guard !state.boundary.isLoading else { return }

        newestRefreshID &+= 1
        let refreshID = newestRefreshID
        do {
            let page = try await loader.summaryHistory(beforeMs: nil, limit: pageSize)
            guard acceptsLoads,
                  newestRefreshID == refreshID,
                  !Task.isCancelled
            else { return }

            let refreshedStarts = Set(page.days.map(\.dayStartMs))
            let retained = state.days.filter { !refreshedStarts.contains($0.dayStartMs) }
            let visibleDays = page.days.filter { day in
                day.slots.contains(where: DaySummaryLayout.isVisibleInPanel)
            }
            state.days = Self.merging(retained, with: visibleDays)
            if let totalDays = page.totalDays {
                state.totalDays = totalDays
            }
        } catch {
            // A head refresh never changes the tail boundary. Existing data
            // remains truthful and the next visible refresh can retry.
        }
    }

    /// Starts a new cursor chain at the daemon-owned newest boundary.
    public func reload() async {
        acceptsLoads = true
        invalidateRequests()
        state = .initial
        await loadNext()
    }

    /// Invalidates in-flight decrypted data without allowing the still-mounted
    /// overlay tree to repopulate it while the machine is locked.
    public func clearSensitiveState() {
        acceptsLoads = false
        invalidateRequests()
        state = .initial
    }

    private func invalidateRequests() {
        nextRequestID &+= 1
        newestRefreshID &+= 1
    }

    private func isCurrentRequest(cursor: SummaryHistoryCursor, requestID: UInt64) -> Bool {
        guard acceptsLoads else { return false }
        guard case let .loading(activeCursor, activeRequestID) = state.boundary else {
            return false
        }
        return activeCursor == cursor && activeRequestID == requestID
    }

    private func restoreLoadableIfCurrent(
        cursor: SummaryHistoryCursor,
        requestID: UInt64
    ) {
        guard isCurrentRequest(cursor: cursor, requestID: requestID) else { return }
        state.boundary = .loadable(cursor)
    }

    private static func merging(
        _ existing: [DaySummary],
        with incoming: [DaySummary]
    ) -> [DaySummary] {
        var byStart = Dictionary(uniqueKeysWithValues: existing.map { ($0.dayStartMs, $0) })
        for day in incoming {
            byStart[day.dayStartMs] = day
        }
        return byStart.values.sorted { $0.dayStartMs > $1.dayStartMs }
    }
}
