import Foundation

/// The only daemon capability needed by the history panel.
public protocol SummaryHistoryPageLoading: Sendable {
    func summaryHistory(beforeMs: Int64?, limit: Int) async throws -> SummaryHistoryPage
}
