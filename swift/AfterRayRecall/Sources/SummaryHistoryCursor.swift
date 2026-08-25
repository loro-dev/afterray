import Foundation

/// An opaque pagination position. It is deliberately not a display date.
public enum SummaryHistoryCursor: Equatable, Sendable {
    case newest
    case before(Int64)

    var beforeMs: Int64? {
        switch self {
        case .newest: nil
        case let .before(value): value
        }
    }
}
