/// Which landing point a keystroke belongs to (decision 4 of
/// docs/input-events-and-t1-acts-plan.md).
///
/// System focus is the obvious answer and is right whenever the app gives a
/// real answer. The apps this pipeline exists for do not: measured on the
/// 2026-08-17 vault, Feishu reports `AXWebArea` for its entire web view and
/// Zed reports `AXWindow`. Attributing a typing burst to a landing point that
/// coarse drags the run's engaged scope up to the whole window through the
/// LCA, which re-creates the sidebar-noise bug this branch exists to remove —
/// and does it precisely in the case the user is typing, the strongest
/// evidence of engagement there is.
///
/// A click, by contrast, resolves to a real element (measured depth 21–39 in
/// Feishu), so when focus declines to be specific the last click is the better
/// evidence of where the caret is.
///
/// This is a role decision, never an application decision: `AXWebArea` and
/// `AXWindow` are generic accessibility roles, and no bundle identifier
/// reaches this file. Kept in the pure target because the executable needs
/// live Accessibility permission to run at all.
package enum TypingTarget {
    /// A click older than this no longer describes where the caret is: the
    /// user may have moved on with ⌘-Tab, a shortcut, or arrow keys.
    package static let lastClickMaxAgeMs: Int64 = 120_000

    /// Roles a person can type into. The list is the definition of "the app
    /// answered specifically"; anything outside it is the app declining to say.
    package static let typeableRoles: Set<String> = [
        "AXTextArea",
        "AXTextField",
        "AXSecureTextField",
        "AXComboBox",
        "AXSearchField",
    ]

    package enum Choice: Equatable {
        /// Focus named something typeable; use it.
        case focus
        /// Focus was coarse or absent and a recent click resolved precisely.
        case lastClick
    }

    /// `lastClickAgeMs` is `nil` when no click has been resolved yet.
    package static func choose(focusedRole: String?, lastClickAgeMs: Int64?) -> Choice {
        if let focusedRole, typeableRoles.contains(focusedRole) {
            return .focus
        }
        guard let lastClickAgeMs, lastClickAgeMs <= lastClickMaxAgeMs else {
            // Nothing better to offer: report the coarse focus honestly rather
            // than inventing a scope. The join fails open on a scope it cannot
            // resolve, which is the correct outcome.
            return .focus
        }
        return .lastClick
    }
}
