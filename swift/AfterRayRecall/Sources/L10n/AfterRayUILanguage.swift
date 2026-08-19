import Foundation

/// UI languages AfterRay ships strings for. Summary output still uses the
/// daemon's 17-language catalogue; this is only the chrome.
public enum AfterRayUILanguage: String, CaseIterable, Equatable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case german = "de"
    case french = "fr"

    public static let autoCode = "auto"

    /// Codes the interface picker offers, in display order.
    public static var pickerCodes: [String] {
        [autoCode] + allCases.map(\.rawValue)
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public var copy: AfterRayCopy {
        switch self {
        case .english: .english
        case .simplifiedChinese: .simplifiedChinese
        case .traditionalChinese: .traditionalChinese
        case .japanese: .japanese
        case .korean: .korean
        case .spanish: .spanish
        case .german: .german
        case .french: .french
        }
    }

    public var nativeName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        }
    }

    public var englishName: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "Chinese (Simplified)"
        case .traditionalChinese: "Chinese (Traditional)"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .spanish: "Spanish"
        case .german: "German"
        case .french: "French"
        }
    }

    public var languageOption: LanguageOption {
        LanguageOption(code: rawValue, nativeName: nativeName, englishName: englishName)
    }

    public static var pickerLanguageOptions: [LanguageOption] {
        [.followSystem] + allCases.map(\.languageOption)
    }

    /// Maps a stored preference onto a shipped UI language.
    ///
    /// `auto` / empty / unknown follow AppleLanguages, then collapse to a
    /// language we actually have strings for.
    public static func resolve(
        stored: String,
        preferred: [String] = Locale.preferredLanguages
    ) -> AfterRayUILanguage {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           trimmed.compare(autoCode, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        {
            return match(tag: trimmed) ?? .english
        }
        return matchSystem(preferred: preferred)
    }

    public static func matchSystem(preferred: [String] = Locale.preferredLanguages) -> AfterRayUILanguage {
        for tag in preferred {
            if let matched = match(tag: tag) { return matched }
        }
        return .english
    }

    /// Best shipped language for a BCP-47 tag. `nil` if we should keep looking
    /// (or fall back to English at the call site).
    public static func match(tag: String) -> AfterRayUILanguage? {
        let folded = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if folded == autoCode { return nil }
        if folded.hasPrefix("zh") {
            if folded.contains("hant") || folded.contains("-tw") || folded.contains("-hk")
                || folded.contains("-mo")
            {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }
        if folded == "ja" || folded.hasPrefix("ja-") { return .japanese }
        if folded == "ko" || folded.hasPrefix("ko-") { return .korean }
        if folded == "es" || folded.hasPrefix("es-") { return .spanish }
        if folded == "de" || folded.hasPrefix("de-") { return .german }
        if folded == "fr" || folded.hasPrefix("fr-") { return .french }
        if folded == "en" || folded.hasPrefix("en-") { return .english }
        return nil
    }
}
