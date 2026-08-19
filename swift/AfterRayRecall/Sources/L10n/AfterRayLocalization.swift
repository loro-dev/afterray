import SwiftUI

extension Notification.Name {
    public static let afterRayLocalizationDidChange = Notification.Name(
        "dev.afterray.localization-did-change"
    )
}

/// Process-wide UI language. Onboarding reads this before the daemon exists;
/// Settings later calls `apply(stored:)` so an explicit pin wins.
@MainActor
public final class AfterRayLocalization: ObservableObject {
    public static let shared = AfterRayLocalization()

    @Published public private(set) var language: AfterRayUILanguage
    @Published public private(set) var copy: AfterRayCopy
    @Published public private(set) var locale: Locale
    /// The stored preference last applied (`auto`, `en`, `zh-Hans`, …).
    public private(set) var storedCode: String

    public init(stored: String = AfterRayUILanguage.autoCode) {
        let resolved = AfterRayUILanguage.resolve(stored: stored)
        storedCode = stored
        language = resolved
        copy = resolved.copy
        locale = resolved.locale
    }

    public func bootstrapFromSystem() {
        apply(stored: AfterRayUILanguage.autoCode)
    }

    public func apply(stored: String) {
        let resolved = AfterRayUILanguage.resolve(stored: stored)
        let changed = resolved != language || stored != storedCode
        storedCode = stored
        guard changed else { return }
        language = resolved
        copy = resolved.copy
        locale = resolved.locale
        NotificationCenter.default.post(name: .afterRayLocalizationDidChange, object: nil)
    }
}

private struct AfterRayCopyKey: EnvironmentKey {
    static let defaultValue = AfterRayCopy.english
}

private struct AfterRayLocaleKey: EnvironmentKey {
    static let defaultValue = Locale(identifier: "en")
}

extension EnvironmentValues {
    public var afterRayCopy: AfterRayCopy {
        get { self[AfterRayCopyKey.self] }
        set { self[AfterRayCopyKey.self] = newValue }
    }

    public var afterRayLocale: Locale {
        get { self[AfterRayLocaleKey.self] }
        set { self[AfterRayLocaleKey.self] = newValue }
    }
}

/// Re-injects the live catalog whenever the user (or first-launch bootstrap)
/// changes the interface language.
public struct AfterRayLocalizedModifier: ViewModifier {
    @ObservedObject private var localization = AfterRayLocalization.shared

    public init() {}

    public func body(content: Content) -> some View {
        content
            .environment(\.afterRayCopy, localization.copy)
            .environment(\.afterRayLocale, localization.locale)
            .environment(\.locale, localization.locale)
    }
}

extension View {
    public func afterRayLocalized() -> some View {
        modifier(AfterRayLocalizedModifier())
    }
}
