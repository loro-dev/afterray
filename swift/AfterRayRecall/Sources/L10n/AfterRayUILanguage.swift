import Foundation

/// UI languages AfterRay ships strings for. Summary output still uses the
/// daemon's 17-language catalogue; this is only the chrome.
public enum AfterRayUILanguage: String, CaseIterable, Equatable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public static let autoCode = "auto"

    /// Codes the interface picker offers, in display order.
    public static let pickerCodes = [autoCode, english.rawValue, simplifiedChinese.rawValue]

    public var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }

    public var copy: AfterRayCopy {
        switch self {
        case .english: .english
        case .simplifiedChinese: .simplifiedChinese
        }
    }

    /// Maps a stored preference onto a shipped UI language.
    ///
    /// `auto` / empty / unknown follow the same AppleLanguages walk the daemon
    /// uses for model replies (`agent::resolve_language`), then collapse to a
    /// language we actually have strings for. Traditional Chinese tags share
    /// the Simplified catalog until a separate set exists.
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
        if folded.hasPrefix("zh") { return .simplifiedChinese }
        if folded == "en" || folded.hasPrefix("en-") { return .english }
        return nil
    }
}
