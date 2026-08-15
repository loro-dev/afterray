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
    @Published private(set) var domains: [String] = []

    private var daemon: UnixSocketDaemonClient {
        UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
    }

    init() {
        Task { await load() }
    }

    func load() async {
        guard let settings = try? await daemon.settings() else { return }
        bundleIds = settings.excludedBundleIds
        domains = settings.excludedDomains
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
        panel.message = "Choose an app AfterRay should never record."
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier,
              bundleID != "dev.afterray.app",
              !bundleIds.contains(bundleID)
        else { return }
        await save(bundleIds: bundleIds + [bundleID], domains: nil)
    }

    func removeApp(_ bundleID: String) async {
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
        guard let settings = try? await daemon.updateSettings(
            recordAudio: nil,
            excludedBundleIds: newBundleIds,
            excludedDomains: newDomains,
            llmProvider: nil,
            llmBaseUrl: nil,
            llmModel: nil,
            llmApiKey: nil
        ) else { return }
        bundleIds = settings.excludedBundleIds
        domains = settings.excludedDomains
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
            return bundleID
        }
        return name
    }
}
