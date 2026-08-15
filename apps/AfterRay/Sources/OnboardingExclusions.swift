import AfterRayRecall
import AppKit
import Foundation

/// Exclusion list backing the onboarding privacy step.
///
/// Onboarding runs before the settings panel exists, so it talks to the daemon
/// directly. It holds a local copy of both lists because the panel needs to
/// redraw the moment something is added — waiting for a settings refresh would
/// make the choice look like it did not take.
@MainActor
final class OnboardingExclusions: ObservableObject {
    @Published private(set) var bundleIds: [String] = []
    @Published private(set) var protectedBundleIds: Set<String> = []
    @Published private(set) var domains: [String] = []
    @Published private(set) var message: String?

    private var daemon: UnixSocketDaemonClient {
        UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
    }

    func load() async {
        do {
            _ = try await DaemonSupervisor.shared.startIfNeeded()
            apply(try await daemon.settings())
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// A file picker rather than "exclude the frontmost app": during onboarding
    /// the frontmost app is AfterRay itself.
    func pickApp() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app to skip."
        let response = await present(panel)
        guard response == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            message = "Could not read that app's identifier."
            return
        }
        guard bundleID != "dev.afterray.app" else {
            message = "AfterRay already excludes its own windows."
            return
        }
        guard !bundleIds.contains(bundleID) else {
            message = "That app is already excluded."
            return
        }
        await save(bundleIds: bundleIds + [bundleID], domains: nil)
    }

    func removeApp(_ bundleID: String) async {
        guard !protectedBundleIds.contains(bundleID) else {
            message = "Password apps are always skipped."
            return
        }
        await save(bundleIds: bundleIds.filter { $0 != bundleID }, domains: nil)
    }

    func addDomain(_ typed: String) async {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The daemon normalises and dedupes, so a pasted URL and a typed host
        // converge without this side having to know the rules.
        await save(bundleIds: nil, domains: domains + [trimmed])
    }

    func removeDomain(_ domain: String) async {
        await save(bundleIds: nil, domains: domains.filter { $0 != domain })
    }

    private func save(bundleIds newBundleIds: [String]?, domains newDomains: [String]?) async {
        do {
            _ = try await DaemonSupervisor.shared.startIfNeeded()
            let settings = try await daemon.updateSettings(
                recordAudio: nil,
                excludedBundleIds: newBundleIds,
                excludedDomains: newDomains,
                llmProvider: nil,
                llmBaseUrl: nil,
                llmModel: nil,
                llmApiKey: nil
            )
            apply(settings)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func apply(_ settings: AppSettings) {
        protectedBundleIds = Set(settings.protectedBundleIds)
        let installedProtected = AfterRayPrivacyCatalog.installedBundleIDs(
            from: settings.protectedBundleIds
        )
        bundleIds = Array(Set(settings.excludedBundleIds + installedProtected))
            .sorted { Self.displayName(for: $0) < Self.displayName(for: $1) }
        domains = settings.excludedDomains
    }

    /// The onboarding panel floats at modal-panel level. Attaching the picker
    /// as its sheet keeps the chooser visibly tied to the button and avoids a
    /// synchronous nested modal loop that can appear behind that panel.
    private func present(_ panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            if let parent = NSApp.keyWindow {
                panel.beginSheetModal(for: parent) { response in
                    continuation.resume(returning: response)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
    }

    /// Falls back to the identifier when the app is not installed — a stale
    /// exclusion is still worth showing, and worth being able to remove.
    static func displayName(for bundleID: String) -> String {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            let name = Bundle(url: url)?
                .object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
        else {
            return AfterRayPrivacyCatalog.protectedName(for: bundleID) ?? bundleID
        }
        return name
    }

    static func iconPath(for bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
    }
}
