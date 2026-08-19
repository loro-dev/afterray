import AfterRayRecall
import AppKit
import Foundation

/// Sparkle installs an update by replacing the application bundle in place.
/// That is impossible on the read-only volume a DMG mounts, so an app the user
/// never moved out of the disk image can never update itself — and would never
/// say why. This runs once at launch, before anything else is wired up.
@MainActor
enum AfterRayInstallLocation {
    private static let declinedKey = "AfterRayDeclinedMoveToApplications"

    /// Returns true when a relocated copy is starting up and the caller should
    /// stop initialising this one.
    static func relocateIfNeeded() -> Bool {
        // A development build lives in .afterray-dev and updates itself by
        // being rebuilt.
        guard DaemonSupervisor.shared.repositoryRoot == nil else { return false }

        let bundle = Bundle.main.bundleURL
        guard !isInInstallLocation(bundle) else { return false }

        let readOnly = isOnReadOnlyVolume(bundle)
        // A DMG mounts fresh every time, so remembering a refusal there would
        // strand the user on a build that can never update. Elsewhere the
        // choice is theirs to keep.
        if !readOnly, UserDefaults.standard.bool(forKey: declinedKey) { return false }

        switch askToMove(readOnly: readOnly) {
        case .decline:
            if !readOnly { UserDefaults.standard.set(true, forKey: declinedKey) }
            return false
        case .move:
            break
        }

        do {
            let moved = try move(bundle, copying: readOnly)
            relaunch(at: moved)
            return true
        } catch {
            presentFailure(error)
            return false
        }
    }

    static func isInInstallLocation(_ bundle: URL) -> Bool {
        let path = bundle.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/")
    }

    static func isOnReadOnlyVolume(_ bundle: URL) -> Bool {
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly ?? false
    }

    private enum Choice {
        case move
        case decline
    }

    private static func askToMove(readOnly: Bool) -> Choice {
        let copy = AfterRayLocalization.shared.copy
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.settings.moveToApplicationsQuestion
        alert.informativeText = readOnly
            ? copy.settings.moveFromDiskImage
            : copy.settings.moveFromElsewhere
        alert.addButton(withTitle: copy.settings.moveToApplications)
        alert.addButton(withTitle: readOnly ? copy.settings.notNow : copy.settings.keepWhereItIs)
        return alert.runModal() == .alertFirstButtonReturn ? .move : .decline
    }

    private static func move(_ bundle: URL, copying: Bool) throws -> URL {
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(bundle.lastPathComponent)
        let manager = FileManager.default

        if manager.fileExists(atPath: destination.path) {
            // Replacing a copy that is running would leave the user with two
            // daemons fighting over one socket.
            if isRunningElsewhere(at: destination) {
                throw InstallLocationError.destinationRunning(
                    AfterRayLocalization.shared.copy.settings.alreadyRunningInApplications
                )
            }
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }

        if copying {
            try manager.copyItem(at: bundle, to: destination)
        } else {
            try manager.moveItem(at: bundle, to: destination)
        }
        return destination
    }

    private static func isRunningElsewhere(at destination: URL) -> Bool {
        let target = destination.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.contains { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return false
            }
            guard let url = app.bundleURL?.resolvingSymlinksInPath() else { return false }
            return url == target
        }
    }

    private static func relaunch(at destination: URL) {
        AfterRayLog.info("relocated the app to \(destination.path); relaunching")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in
                // Terminate directly: the relocated copy owns the daemon now,
                // and the regular shutdown path would race it for the socket.
                exit(0)
            }
        }
    }

    private static func presentFailure(_ error: Error) {
        AfterRayLog.info("could not relocate the app: \(error)")
        let copy = AfterRayLocalization.shared.copy
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.settings.couldNotMove
        alert.informativeText = """
        \(error.localizedDescription)

        \(copy.settings.dragToApplicationsManually)
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum InstallLocationError: LocalizedError {
    case destinationRunning(String)

    var errorDescription: String? {
        switch self {
        case .destinationRunning(let message):
            message
        }
    }
}
