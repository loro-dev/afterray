import AfterRayRecall

/// Why the overlay is being ordered in. Posted as
/// `afterRayRecallDidOpen`'s object so a citation from the standalone chat
/// window can land on a moment without going live first.
enum OverlayOpenIntent: Equatable {
    case summary(DaySlotSummary)
    case moment(String)
}

enum OverlayOpenRoute: Equatable {
    case summary(DaySlotSummary)
    case moment(String)
    case selectedSearch
    case live

    static func resolve(intent: OverlayOpenIntent?, hasSelectedSearch: Bool) -> Self {
        switch intent {
        case .summary(let slot):
            return .summary(slot)
        case .moment(let momentID) where !momentID.isEmpty:
            return .moment(momentID)
        case .moment, .none:
            if hasSelectedSearch { return .selectedSearch }
            return .live
        }
    }
}
