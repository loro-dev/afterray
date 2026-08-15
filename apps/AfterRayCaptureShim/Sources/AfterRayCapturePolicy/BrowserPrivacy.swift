import Foundation

package enum BrowserPrivacyEvidence: String, Equatable, Sendable {
    case notBrowser = "not_browser"
    case browserAutomation = "browser_automation"
    case firefoxWindowTitle = "firefox_window_title"
    case accessibilityIdentifier = "accessibility_identifier"
    case accessibilityLabel = "accessibility_label"
}

package enum BrowserPrivacyState: Equatable, Sendable {
    case privateBrowsing(BrowserPrivacyEvidence)
    case regular(BrowserPrivacyEvidence)
    case unknown
}

/// A fixed AppleScript query for a supported Chromium browser.
///
/// Bundle identifiers come from a closed allowlist, so no AX or page text is
/// ever interpolated into source code. The query returns only one of three
/// sentinels and never reads a tab URL or title.
package struct BrowserPrivacyAutomationQuery: Equatable, Sendable {
    package let bundleIdentifier: String
    package let script: String

    package static func make(bundleIdentifier: String?) -> Self? {
        guard let browser = BrowserKind(bundleIdentifier: bundleIdentifier) else { return nil }
        switch browser {
        case let .chromium(bundleIdentifier):
            return Self(
                bundleIdentifier: bundleIdentifier,
                script: modeScript(bundleIdentifier: bundleIdentifier)
            )
        case let .arc(bundleIdentifier):
            return Self(
                bundleIdentifier: bundleIdentifier,
                script: booleanScript(bundleIdentifier: bundleIdentifier)
            )
        case .firefox, .safari, .other:
            return nil
        }
    }

    package func parse(output: String) -> BrowserPrivacyState {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "afterray:private": .privateBrowsing(.browserAutomation)
        case "afterray:regular": .regular(.browserAutomation)
        default: .unknown
        }
    }

    private static func modeScript(bundleIdentifier: String) -> String {
        """
        if application id "\(bundleIdentifier)" is running then
            tell application id "\(bundleIdentifier)"
                if (count of windows) is 0 then return "afterray:unknown"
                try
                    set window_mode to mode of front window as text
                    if window_mode is "incognito" then return "afterray:private"
                    if window_mode is "normal" then return "afterray:regular"
                end try
            end tell
        end if
        return "afterray:unknown"
        """
    }

    private static func booleanScript(bundleIdentifier: String) -> String {
        """
        if application id "\(bundleIdentifier)" is running then
            tell application id "\(bundleIdentifier)"
                if (count of windows) is 0 then return "afterray:unknown"
                try
                    if incognito of front window then
                        return "afterray:private"
                    else
                        return "afterray:regular"
                    end if
                end try
            end tell
        end if
        return "afterray:unknown"
        """
    }
}

/// Resolves a browser's private-window state from increasingly weaker signals.
///
/// macOS has no cross-browser Accessibility attribute for private browsing.
/// Browser automation is authoritative for supported Chromium windows;
/// Firefox's documented title suffix and browser-owned AX chrome are positive
/// fallbacks. Absence of a fallback marker remains `unknown`, not `regular`.
package struct BrowserPrivacyDetector {
    private let browser: BrowserKind?
    private var accessibilityEvidence: BrowserPrivacyEvidence?

    package init(bundleIdentifier: String?) {
        browser = BrowserKind(bundleIdentifier: bundleIdentifier)
    }

    package var isKnownBrowser: Bool { browser != nil }

    package mutating func observe(
        role: String?,
        title: String?,
        nodeDescription: String?,
        identifier: String?,
        insideBrowserWindow: Bool,
        insideWebContent: Bool
    ) {
        guard
            browser != nil,
            insideBrowserWindow,
            !insideWebContent,
            !Self.isMenuRole(role),
            accessibilityEvidence == nil
        else { return }

        if let identifier, Self.isStablePrivateIdentifier(identifier) {
            accessibilityEvidence = .accessibilityIdentifier
            return
        }

        let labels = [title, nodeDescription].compactMap { $0 }
        if labels.contains(where: Self.containsPrivateMarker) {
            accessibilityEvidence = .accessibilityLabel
        }
    }

    package func resolve(
        automationState: BrowserPrivacyState = .unknown,
        windowTitle: String?
    ) -> BrowserPrivacyState {
        guard let browser else { return .regular(.notBrowser) }

        // A positive signal always fails closed, even if another source says
        // regular. This protects against focus races and stale browser chrome.
        if case .privateBrowsing = automationState { return automationState }
        if browser.isFirefox, Self.isFirefoxPrivateWindowTitle(windowTitle) {
            return .privateBrowsing(.firefoxWindowTitle)
        }
        if let accessibilityEvidence {
            return .privateBrowsing(accessibilityEvidence)
        }
        if case .regular = automationState { return automationState }
        return .unknown
    }

    package static func redactedURL(_ value: String?, privateBrowsing: Bool) -> String? {
        guard privateBrowsing, let value, !looksLikeFileLocation(value) else { return value }
        return nil
    }

    package static func redactedBrowserChromeValue(
        _ value: String?,
        role: String?,
        insideWebContent: Bool,
        privateBrowsing: Bool
    ) -> String? {
        guard
            privateBrowsing,
            !insideWebContent,
            isLocationField(role),
            let value,
            looksLikeWebLocation(value)
        else { return value }
        return nil
    }

    package static func looksLikeWebLocation(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !looksLikeFileLocation(value) else { return false }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return true
        }
        if let scheme = URLComponents(string: value)?.scheme,
           !scheme.isEmpty,
           scheme.lowercased() != "file"
        {
            return true
        }
        return !value.contains(where: { $0.isWhitespace })
            && !value.hasPrefix("/")
            && value.contains(".")
    }

    private static func isFirefoxPrivateWindowTitle(_ value: String?) -> Bool {
        guard let value else { return false }
        let title = normalized(value)
        return privateBrowsingMarkers.contains { title.hasSuffix($0) }
    }

    private static func isStablePrivateIdentifier(_ value: String) -> Bool {
        let identifier = normalized(value).filter(\.isLetter)
        return stablePrivateIdentifierTokens.contains { identifier.contains($0) }
    }

    private static func containsPrivateMarker(_ value: String) -> Bool {
        let label = normalized(value)
        if label == "private" { return true }
        return privateBrowsingMarkers.contains { label.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func isMenuRole(_ role: String?) -> Bool {
        ["AXMenu", "AXMenuBar", "AXMenuItem"].contains(role)
    }

    private static func looksLikeFileLocation(_ value: String) -> Bool {
        value.hasPrefix("file://") || (value.hasPrefix("/") && !value.hasPrefix("//"))
    }

    private static func isLocationField(_ role: String?) -> Bool {
        ["AXTextField", "AXSearchField", "AXComboBox"].contains(role)
    }

    private static let stablePrivateIdentifierTokens = [
        "incognito",
        "inprivate",
        "privatebrowsing",
        "privatemode",
    ]

    /// Browser-owned labels and Firefox window-title suffixes. These strings
    /// are deliberately positive-only: missing or changed localization yields
    /// `unknown`, never a false `regular` result.
    private static let privateBrowsingMarkers = [
        "incognito",
        "inprivate",
        "private browsing",
        "private window",
        "private mode",
        "privatebrowsing",
        "privatemode",
        "navigation privee",
        "navegacion privada",
        "navegacao privada",
        "navigazione privata",
        "navigazione anonima",
        "privater modus",
        "privenavigatie",
        "tryb prywatny",
        "gizli gezinti",
        "приватный просмотр",
        "приватний перегляд",
        "التصفح الخاص",
        "निजी ब्राउज़िंग",
        "การท่องเว็บแบบส่วนตัว",
        "duyet web rieng tu",
        "anonymni prohlizeni",
        "navigare privata",
        "privat bongeszes",
        "privat surfning",
        "privat nettlesing",
        "privat browsing",
        "yksityinen selaus",
        "ιδιωτικη περιηγηση",
        "גלישה פרטית",
        "无痕",
        "無痕",
        "隐私浏览",
        "隱私瀏覽",
        "隱私視窗",
        "シークレット",
        "プライベートブラウズ",
        "プライベートブラウジング",
        "시크릿",
        "개인정보 보호 브라우징",
        "사생활 보호 모드",
    ].map(normalized)
}

private enum BrowserKind: Equatable, Sendable {
    case chromium(bundleIdentifier: String)
    case arc(bundleIdentifier: String)
    case firefox
    case safari
    case other

    init?(bundleIdentifier: String?) {
        guard let bundleIdentifier, Self.isSafeBundleIdentifier(bundleIdentifier) else { return nil }
        let bundle = bundleIdentifier.lowercased()
        if Self.matches(bundle, prefixes: Self.chromiumBundlePrefixes) {
            self = .chromium(bundleIdentifier: bundleIdentifier)
        } else if Self.matches(bundle, prefixes: Self.arcBundlePrefixes) {
            self = .arc(bundleIdentifier: bundleIdentifier)
        } else if Self.matches(bundle, prefixes: Self.firefoxBundlePrefixes) {
            self = .firefox
        } else if Self.matches(bundle, prefixes: Self.safariBundlePrefixes) {
            self = .safari
        } else if Self.matches(bundle, prefixes: Self.otherBrowserBundlePrefixes) {
            self = .other
        } else {
            return nil
        }
    }

    var isFirefox: Bool {
        if case .firefox = self { return true }
        return false
    }

    private static func matches(_ bundle: String, prefixes: [String]) -> Bool {
        prefixes.contains { prefix in bundle == prefix || bundle.hasPrefix(prefix + ".") }
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 65 ... 90, 97 ... 122: true
            default: false
            }
        }
    }

    private static let chromiumBundlePrefixes = [
        "com.brave.browser",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "com.operasoftware.opera",
        "com.vivaldi.vivaldi",
        "org.chromium.chromium",
    ]
    private static let arcBundlePrefixes = ["company.thebrowser.browser"]
    private static let firefoxBundlePrefixes = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]
    private static let safariBundlePrefixes = ["com.apple.safari"]
    private static let otherBrowserBundlePrefixes = [
        "com.duckduckgo.macos.browser",
        "company.thebrowser.dia",
    ]
}
