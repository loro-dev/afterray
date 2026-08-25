import Foundation

/// Everything the bottom of the history document is allowed to be.
public enum SummaryHistoryBoundary: Equatable, Sendable {
    case loadable(SummaryHistoryCursor)
    case loading(SummaryHistoryCursor, requestID: UInt64)
    case failed(SummaryHistoryCursor, message: String)
    case end

    public var isLoading: Bool {
        if case .loading = self { true } else { false }
    }

    public var canLoad: Bool {
        switch self {
        case .loadable, .failed: true
        case .loading, .end: false
        }
    }

    public var isFailure: Bool {
        if case .failed = self { true } else { false }
    }

    var cursorForLoad: SummaryHistoryCursor? {
        switch self {
        case let .loadable(cursor), let .failed(cursor, _): cursor
        case .loading, .end: nil
        }
    }
}
