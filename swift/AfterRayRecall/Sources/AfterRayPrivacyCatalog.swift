import AppKit
import Foundation

/// Human-readable labels for daemon-owned privacy exclusions. The daemon is
/// the authority for which identifiers are protected; this catalogue only
/// keeps an uninstalled app from appearing as an opaque reverse-DNS string.
public enum AfterRayPrivacyCatalog {
    private static let protectedNames = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.apple.Passwords": "Apple Passwords",
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.loginwindow": "macOS Login Window",
        "com.bitwarden.desktop": "Bitwarden",
        "com.callpod.keepermac.lite": "Keeper (legacy)",
        "com.dashlane.Dashlane": "Dashlane",
        "com.keepassium.intune": "KeePassium for Intune",
        "com.keepassium.ios": "KeePassium",
        "com.keepassium.ios.pro": "KeePassium Pro",
        "com.keepersecurity.passwordmanager": "Keeper",
        "com.lastpass.LastPass": "LastPass (legacy)",
        "com.lastpass.lastpassforsafari": "LastPass for Safari",
        "com.markmcguill.strongbox": "Strongbox",
        "com.markmcguill.strongbox.mac.pro": "Strongbox Pro (legacy)",
        "com.markmcguill.strongbox.pro": "Strongbox Pro",
        "com.nordsec.nordpass": "NordPass",
        "com.siber.roboform": "RoboForm",
        "com.sibersystems.RoboForm": "RoboForm",
        "dev.afterray.app": "AfterRay",
        "in.sinew.Enpass-Desktop": "Enpass",
        "me.proton.pass.electron": "Proton Pass",
        "org.keepassxc.keepassxc": "KeePassXC",
    ]

    public static func protectedName(for bundleID: String) -> String? {
        protectedNames[bundleID]
    }

    /// Turns the daemon's complete protection catalogue into the subset that
    /// is meaningful in the UI. The daemon still blocks every identifier; the
    /// onboarding list only shows apps Launch Services can find on this Mac.
    @MainActor
    public static func installedBundleIDs(
        from candidates: [String],
        locate: (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) -> [String] {
        candidates.filter { bundleID in
            bundleID != "dev.afterray.app" && locate(bundleID) != nil
        }
    }
}
