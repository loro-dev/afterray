import AfterRayRecall
import AppKit
import Sparkle

/// Sparkle, wrapped so the rest of the app never imports it and a development
/// tree never checks for updates at all.
@MainActor
final class AfterRayUpdater: NSObject {
    static let shared = AfterRayUpdater()

    private var controller: SPUStandardUpdaterController?
    /// Set once Sparkle has an update staged for the next quit. Drives the
    /// menu item, which is the only place the user learns about it before
    /// they happen to quit.
    private(set) var stagedVersion: String?

    var isEnabled: Bool { controller != nil }
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// "0.0.2 (build 142)" — the marketing version alone is ambiguous once
    /// updates ship, since two builds can share one.
    static var hostDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "an unknown version"
        // One source of truth for the build number: the daemon handshake
        // compares against the same value.
        guard let build = DaemonSupervisor.hostBuild else { return version }
        return "\(version) (build \(build))"
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        // A development build is replaced by rebuilding it, and its bundle
        // sits in .afterray-dev where Sparkle has no business writing.
        guard DaemonSupervisor.shared.repositoryRoot == nil else {
            AfterRayLog.info("development build: automatic updates are disabled")
            return
        }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // Download in the background; Sparkle installs on quit. For an app
        // that records continuously, interrupting to restart is the worst
        // possible default.
        controller?.updater.automaticallyDownloadsUpdates = true
    }

    @objc func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Nil in a development build, where there is nothing to check.
    func makeMenuItem() -> NSMenuItem? {
        guard isEnabled else { return nil }
        let item = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }
}

extension AfterRayUpdater: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Menu validation runs each time the menu opens, which is the only
        // moment the title needs to be right.
        if let stagedVersion {
            menuItem.title = "Update \(stagedVersion) Installs on Quit"
            return false
        }
        menuItem.title = "Check for Updates…"
        return canCheckForUpdates
    }
}

extension AfterRayUpdater: SPUUpdaterDelegate {
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            AfterRayUpdater.shared.stagedVersion = version
            AfterRayLog.info("update \(version) staged; it installs on quit")
        }
        // Intercept without taking control. Returning true would stall
        // Sparkle's scheduler, and a user who leaves AfterRay running for
        // weeks would then never be offered a critical update.
        return false
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        Task { @MainActor in
            // Close the recording session and the daemon before the bundle is
            // swapped, so the replacement does not have to reclaim a socket
            // from a daemon that outlived its own binary.
            RecallOverlayController.shared.stop()
            await DaemonSupervisor.shared.shutdown()
            installHandler()
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        // "No update found" is the ordinary outcome of a scheduled check.
        guard code != Int(SUError.noUpdateError.rawValue) else { return }
        Task { @MainActor in
            AfterRayLog.info("update check failed: \(error.localizedDescription)")
        }
    }
}
