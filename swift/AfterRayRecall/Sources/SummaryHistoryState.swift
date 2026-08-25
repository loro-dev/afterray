import Foundation

/// One history document and its single legal bottom state.
public struct SummaryHistoryState: Equatable, Sendable {
    public var days: [DaySummary]
    public var totalDays: Int?
    public var boundary: SummaryHistoryBoundary

    public init(
        days: [DaySummary],
        totalDays: Int? = nil,
        boundary: SummaryHistoryBoundary
    ) {
        self.days = days
        self.totalDays = totalDays
        self.boundary = boundary
    }

    public static let initial = SummaryHistoryState(
        days: [],
        boundary: .loadable(.newest)
    )

    public static let empty = SummaryHistoryState(days: [], boundary: .end)

    public static func complete(days: [DaySummary], totalDays: Int? = nil) -> Self {
        SummaryHistoryState(days: days, totalDays: totalDays, boundary: .end)
    }
}
