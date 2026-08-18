/// The one keystroke guard left after CAP-005 was retired
/// (docs/event-capture-v2-plan.md §信任模型变更).
///
/// Typed characters and field values may now be captured: everything is
/// processed locally, the vault is encrypted, and nothing leaves the machine
/// without the user saying so. The password field is the exception that stays,
/// and it is absolute — inside one, neither the keystream nor the field's value
/// is recorded, only the burst count that says *something* was typed.
///
/// Pure because it is the last line: a live-AX test would not run in CI, and a
/// guard nobody can test is a guard nobody can trust.
package enum SecureInputGuard {
    /// The subrole every AppKit password field and every Safari `input
    /// type=password` reports.
    package static let secureSubrole = "AXSecureTextField"

    /// Labels that mean "secret" even when the app never said so.
    ///
    /// Belt and braces for the case the subrole misses: an Electron or web app
    /// can render a password box as a plain `AXTextField` with a label, and a
    /// captured password is not the kind of mistake a later fix repairs. The
    /// cost of a false positive is one field's text — a note labelled "Secret
    /// Santa" keeps its count and loses its content, which is the right way for
    /// this to fail.
    package static let secretLabelMarkers = [
        "password",
        "passwd",
        "passcode",
        "passphrase",
        "secret",
        "密码",
        "密碼",
        "口令",
    ]

    /// Whether text at this element must never be recorded.
    ///
    /// - Parameters:
    ///   - subrole: the element's own AX subrole.
    ///   - label: its title or description.
    ///   - ancestorSubroles: subroles of its resolved ancestors, nearest first.
    ///     A password field wrapped in a group still answers about itself, but
    ///     an app that puts the subrole on the wrapper and not on the field is
    ///     not thereby allowed to leak it.
    package static func isSecure(
        subrole: String?,
        label: String? = nil,
        ancestorSubroles: [String?] = []
    ) -> Bool {
        if subrole == secureSubrole { return true }
        if ancestorSubroles.contains(where: { $0 == secureSubrole }) { return true }
        return looksLikeSecretLabel(label)
    }

    package static func looksLikeSecretLabel(_ label: String?) -> Bool {
        guard let label, !label.isEmpty else { return false }
        let lowered = label.lowercased()
        return secretLabelMarkers.contains { lowered.contains($0) }
    }
}
