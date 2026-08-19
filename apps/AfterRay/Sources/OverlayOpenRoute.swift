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

/// Esc / ⌘W while recall is up. The query bar is often first responder, so
/// SwiftUI's `onExitCommand` is not enough — AppKit must consume the key
/// before a text field eats it.
enum OverlayCloseKey {
    static let escapeKeyCode: UInt16 = 53

    static func shouldDismiss(
        keyCode: UInt16,
        isCommandW: Bool,
        overlayVisible: Bool,
        overlayIsKey: Bool,
        permissionGuideVisible: Bool
    ) -> Bool {
        if permissionGuideVisible { return keyCode == escapeKeyCode }
        guard overlayVisible, overlayIsKey else { return false }
        return keyCode == escapeKeyCode || isCommandW
    }
}
