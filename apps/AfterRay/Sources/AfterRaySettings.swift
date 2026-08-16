import AfterRayRecall
import AppKit
import SwiftUI

extension Notification.Name {
    static let afterRayPreferencesDidChange = Notification.Name("dev.afterray.preferences-did-change")
}

enum AfterRayPreferences {
    static let recordAudioKey = "dev.afterray.recordAudio"
    static let developerOptionsUnlockedKey = "dev.afterray.developer-options.unlocked"
    static let developerOptionsEnabledKey = "dev.afterray.developer-options.enabled"

    static var recordAudio: Bool {
        get {
            guard UserDefaults.standard.object(forKey: recordAudioKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: recordAudioKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: recordAudioKey)
            NotificationCenter.default.post(name: .afterRayPreferencesDidChange, object: nil)
        }
    }
}

@MainActor
final class AfterRaySettingsController: ObservableObject {
    static let shared = AfterRaySettingsController()

    let model = AfterRaySettingsModel()
    @Published private(set) var isPresented = false

    var isVisible: Bool { isPresented }

    func show() {
        isPresented = true
        if !RecallOverlayController.shared.isVisible {
            RecallOverlayController.shared.show()
        }
        Task { await model.refresh() }
    }

    func hide() {
        isPresented = false
        model.pauseDownloadMonitoring()
    }
}

@MainActor
final class AfterRaySettingsModel: ObservableObject, AfterRaySettingsModeling {
    @Published var settings: AppSettings?
    @Published var library: ModelLibrary?
    @Published var storage = AfterRayStorageSnapshot.measure(
        dataDirectory: DaemonSupervisor.shared.dataDirectory,
        modelDirectory: DaemonSupervisor.shared.modelDirectory,
        runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
    )
    @Published var message: String?
    @Published var isRefreshing = false
    @Published var downloadRateBytesPerSecond: Double?
    @Published var isControllingDownload = false
    @Published var isUpdatingAudio = false
    @Published var isUpdatingStorageLimit = false
    @Published var isUpdatingLanguage = false
    @Published var isUpdatingExclusions = false
    @Published var isClearingHistory = false
    @Published var recentJobs: [ModelJob] = []
    @Published var llmProbe: LlmEndpointStatus?
    @Published var isProbingLlm = false
    @Published var isUpdatingLlm = false
    @Published var draftLlmBaseUrl = ""
    @Published var draftLlmModel = ""
    @Published var draftLlmApiKey = ""
    @Published var isInstallingCli = false
    @Published private(set) var cliStatus = AfterRayCliInstall.statusSummary
    @Published private(set) var cliInstalled = AfterRayCliInstall.isInstalled
    @Published private(set) var developerOptionsUnlocked = UserDefaults.standard.bool(
        forKey: AfterRayPreferences.developerOptionsUnlockedKey
    )
    @Published private(set) var developerOptionsEnabled = UserDefaults.standard.bool(
        forKey: AfterRayPreferences.developerOptionsUnlockedKey
    ) && UserDefaults.standard.bool(
        forKey: AfterRayPreferences.developerOptionsEnabledKey
    )
    private var modelDownloadMonitor: Task<Void, Never>?
    private var downloadRateSample: (packID: String, bytes: UInt64, at: Date)?

    var recordAudio: Bool { settings?.recordAudio ?? AfterRayPreferences.recordAudio }
    var excludedBundleIds: [String] {
        guard let settings else { return [] }
        let installedProtected = AfterRayPrivacyCatalog.installedBundleIDs(
            from: settings.protectedBundleIds
        )
        return Array(Set(settings.excludedBundleIds + installedProtected))
            .sorted { appDisplayName($0) < appDisplayName($1) }
    }
    var excludedDomains: [String] { settings?.excludedDomains ?? [] }
    var dataDirectoryPath: String {
        settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path
    }
    var modelDirectoryPath: String {
        settings?.modelDir ?? DaemonSupervisor.shared.modelDirectory.path
    }
    var logDirectoryPath: String { AfterRayLog.directory.path }
    var logFilePath: String { AfterRayLog.fileURL.path }

    private func appDisplayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AfterRayPrivacyCatalog.protectedName(for: bundleID) ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        refreshCliStatus()
        storage = AfterRayStorageSnapshot.measure(
            dataDirectory: URL(fileURLWithPath: settings?.dataDir ?? DaemonSupervisor.shared.dataDirectory.path, isDirectory: true),
            modelDirectory: URL(fileURLWithPath: settings?.modelDir ?? DaemonSupervisor.shared.modelDirectory.path, isDirectory: true),
            runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
        )
        do {
            let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            async let nextSettings = daemon.settings()
            async let nextLibrary = daemon.modelLibrary()
            async let nextJobs = daemon.jobs()
            let loaded = try await (nextSettings, nextLibrary, nextJobs)
            settings = loaded.0
            library = loaded.1
            message = nil
            applyDownloadState(loaded.1.download)
            recentJobs = Array(loaded.2.suffix(8).reversed())
            applyLlmDrafts(from: loaded.0)
            AfterRayPreferences.recordAudio = loaded.0.recordAudio
            storage = AfterRayStorageSnapshot.measure(
                dataDirectory: URL(fileURLWithPath: loaded.0.dataDir, isDirectory: true),
                modelDirectory: URL(fileURLWithPath: loaded.0.modelDir, isDirectory: true),
                runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
            )
            await probeLlm()
            await persistRecommendedOllamaModelIfNeeded()
        } catch {
            message = error.localizedDescription
        }
    }

    func installCli() async {
        isInstallingCli = true
        defer {
            isInstallingCli = false
            refreshCliStatus()
        }
        do {
            let destination = try AfterRayCliInstall.install()
            message = AfterRayCliInstall.isOnPath
                ? "Installed afterray at \(destination.path)."
                : "Installed afterray at \(destination.path). Add ~/.local/bin to your PATH."
        } catch {
            message = error.localizedDescription
        }
    }

    private func refreshCliStatus() {
        cliStatus = AfterRayCliInstall.statusSummary
        cliInstalled = AfterRayCliInstall.isInstalled
    }

    var updatesSupported: Bool { AfterRayUpdater.shared.isEnabled }

    var automaticUpdates: Bool { AfterRayUpdater.shared.automaticallyChecksForUpdates }

    var updateStatus: String {
        if let staged = AfterRayUpdater.shared.stagedVersion {
            return "Version \(staged) is downloaded and installs when you quit AfterRay."
        }
        let build = AfterRayUpdater.hostDescription
        return AfterRayUpdater.shared.automaticallyChecksForUpdates
            ? "You are on \(build). AfterRay checks once a day."
            : "You are on \(build). Automatic checks are off."
    }

    func setAutomaticUpdates(_ enabled: Bool) {
        objectWillChange.send()
        AfterRayUpdater.shared.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        AfterRayUpdater.shared.checkForUpdates()
    }

    func unlockDeveloperOptions() {
        guard !developerOptionsUnlocked else { return }
        developerOptionsUnlocked = true
        UserDefaults.standard.set(true, forKey: AfterRayPreferences.developerOptionsUnlockedKey)
        message = "Developer options unlocked."
    }

    func setDeveloperOptionsEnabled(_ enabled: Bool) {
        guard developerOptionsUnlocked else { return }
        developerOptionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AfterRayPreferences.developerOptionsEnabledKey)
    }

    func replayOnboarding() {
        AfterRaySettingsController.shared.hide()
        OnboardingController.shared.replay()
    }

    func excludeBundle(_ bundleID: String) async {
        var next = excludedBundleIds
        guard !bundleID.isEmpty, !next.contains(bundleID) else { return }
        next.append(bundleID)
        await saveExclusions(next, message: "Excluded \(bundleID).")
    }

    func includeBundle(_ bundleID: String) async {
        guard settings?.protectedBundleIds.contains(bundleID) != true else {
            message = "Password managers and system credential apps are always excluded."
            return
        }
        await saveExclusions(excludedBundleIds.filter { $0 != bundleID }, message: "Included \(bundleID) again.")
    }

    func excludeDomain(_ input: String) async {
        // The daemon owns normalisation, so a pasted URL and a typed host end
        // up as the same entry no matter which surface added it.
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        await saveDomainExclusions(excludedDomains + [typed], message: "Excluded \(typed).")
    }

    func includeDomain(_ domain: String) async {
        await saveDomainExclusions(
            excludedDomains.filter { $0 != domain },
            message: "Including \(domain) again."
        )
    }

    private func saveDomainExclusions(_ domains: [String], message: String) async {
        isUpdatingExclusions = true
        defer { isUpdatingExclusions = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: domains,
                llmProvider: nil,
                llmBaseUrl: nil,
                llmModel: nil,
                llmApiKey: nil
            )
            self.message = message
        } catch {
            self.message = error.localizedDescription
        }
    }

    /// The frontmost-app shortcut cannot reach an app you are not currently in,
    /// and while Settings is open the frontmost app is AfterRay. A picker is the
    /// only way to exclude something deliberately rather than opportunistically.
    func excludeChosenApp() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app AfterRay should never record."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            message = "Could not read that app's identifier."
            return
        }
        guard bundleID != "dev.afterray.app" else {
            message = "AfterRay does not record its own window."
            return
        }
        await excludeBundle(bundleID)
    }

    func clearHistory(_ scope: HistoryScope) async {
        isClearingHistory = true
        defer { isClearingHistory = false }
        do {
            let result = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).clearHistory(scope: scope)
            message = "Deleted \(result.deleted) moment\(result.deleted == 1 ? "" : "s")."
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveExclusions(_ ids: [String], message: String) async {
        isUpdatingExclusions = true
        defer { isUpdatingExclusions = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: ids,
                excludedDomains: nil,
                llmProvider: nil,
                llmBaseUrl: nil,
                llmModel: nil,
                llmApiKey: nil
            )
            self.message = message
        } catch {
            self.message = error.localizedDescription
        }
    }

    func setRecordAudio(_ enabled: Bool) async {
        guard enabled != recordAudio else { return }
        isUpdatingAudio = true
        defer { isUpdatingAudio = false }
        AfterRayPreferences.recordAudio = enabled
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: enabled,
                excludedBundleIds: nil,
                excludedDomains: nil,
                llmProvider: nil,
                llmBaseUrl: nil,
                llmModel: nil,
                llmApiKey: nil
            )
            message = enabled
                ? "Audio recording is on."
                : "Audio recording is off. Existing recordings stay in your vault."
        } catch {
            AfterRayPreferences.recordAudio = !enabled
            message = error.localizedDescription
        }
    }

    func setUiLanguage(_ code: String) async {
        guard code != settings?.uiLanguage else { return }
        await persistLanguage(uiLanguage: code, summaryLanguage: nil)
    }

    func setSummaryLanguage(_ code: String) async {
        guard code != settings?.summaryLanguage else { return }
        await persistLanguage(uiLanguage: nil, summaryLanguage: code)
    }

    private func persistLanguage(uiLanguage: String?, summaryLanguage: String?) async {
        isUpdatingLanguage = true
        defer { isUpdatingLanguage = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                uiLanguage: uiLanguage,
                summaryLanguage: summaryLanguage
            )
            if let uiLanguage {
                message = "Interface language set to \(languageLabel(uiLanguage))."
            } else if let summaryLanguage {
                message = "Summary language set to \(languageLabel(summaryLanguage))."
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func languageLabel(_ code: String) -> String {
        settings?.languageOptions.first { $0.code == code }?.menuTitle ?? code
    }

    func setStorageLimitBytes(_ bytes: UInt64) async {
        guard bytes != settings?.storageLimitBytes else { return }
        isUpdatingStorageLimit = true
        defer { isUpdatingStorageLimit = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                storageLimitBytes: bytes
            )
            storage = AfterRayStorageSnapshot.measure(
                dataDirectory: URL(fileURLWithPath: dataDirectoryPath, isDirectory: true),
                modelDirectory: URL(fileURLWithPath: modelDirectoryPath, isDirectory: true),
                runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
            )
            message = "Memory limit set to \(AfterRayStorageSnapshot.byteCount(bytes))."
        } catch {
            message = error.localizedDescription
        }
    }

    func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(folder)
    }

    /// Adds packs to the daemon's queue. Deliberately not gated on an existing
    /// download: the daemon queues what it cannot start yet, and the old guard
    /// here silently swallowed the request instead, so a second pack could never
    /// be queued at all.
    func download(packID: String?) async {
        message = nil
        let socket = DaemonSupervisor.shared.socketPath
        do {
            let next = try await UnixSocketDaemonClient(socketPath: socket).startModelDownloads(
                packIDs: packID.map { [$0] } ?? []
            )
            library = next
            applyDownloadState(next.download)
            if next.download == nil {
                message = packID == nil
                    ? "All model packs are ready."
                    : "\(displayName(for: packID)) is ready."
            } else {
                AfterRayLog.info("queued \(packID ?? "missing model") download", source: "download")
                startDownloadMonitor()
            }
        } catch {
            message = error.localizedDescription
            AfterRayLog.error(error.localizedDescription, source: "download")
        }
    }

    func pauseDownloadMonitoring() {
        modelDownloadMonitor?.cancel()
        modelDownloadMonitor = nil
    }

    func pauseModelDownloads() async {
        await controlModelDownloads { try await $0.pauseModelDownloads() }
    }

    func resumeModelDownloads() async {
        await controlModelDownloads { try await $0.resumeModelDownloads() }
        if library?.download?.isActive == true { startDownloadMonitor() }
    }

    func cancelModelDownloads() async {
        await controlModelDownloads { try await $0.cancelModelDownloads() }
    }

    func cancelModelDownload(packID: String) async {
        let name = displayName(for: packID)
        await controlModelDownloads { try await $0.cancelModelDownload(packID: packID) }
        // Cancelling the last item leaves nothing to poll for.
        if library?.download == nil { pauseDownloadMonitoring() }
        if message == nil { message = "Cancelled the \(name) download." }
    }

    func updateModelDownloadEndpoint(_ endpoint: String) async {
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateModelDownloadEndpoint(endpoint)
            let applied = settings?.modelDownloadEndpoint ?? ""
            message = applied.isEmpty
                ? "Model downloads use huggingface.co."
                : "Model downloads use \(applied)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func controlModelDownloads(
        _ operation: (UnixSocketDaemonClient) async throws -> ModelLibrary
    ) async {
        guard !isControllingDownload else { return }
        isControllingDownload = true
        defer { isControllingDownload = false }
        do {
            let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            let next = try await operation(client)
            library = next
            applyDownloadState(next.download)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func remove(packID: String) async {
        // Only this pack's own queue entry blocks removal — the daemon rejects
        // it anyway, and a global gate meant one download froze every Remove.
        guard library?.isQueued(packID: packID) != true else { return }
        do {
            library = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).removeModel(packID: packID)
            message = "Removed \(displayName(for: packID))."
            storage = AfterRayStorageSnapshot.measure(
                dataDirectory: URL(fileURLWithPath: dataDirectoryPath, isDirectory: true),
                modelDirectory: URL(fileURLWithPath: modelDirectoryPath, isDirectory: true),
                runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
            )
        } catch {
            message = error.localizedDescription
        }
    }

    func revealLogs() {
        reveal(AfterRayLog.directory.path)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AfterRayLog.diagnosticsReport(), forType: .string)
        AfterRayLog.info("diagnostics report copied")
    }

    func setLlmProvider(_ provider: LlmProvider) async {
        guard provider != settings?.llmProvider else { return }
        isUpdatingLlm = true
        defer { isUpdatingLlm = false }
        do {
            let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            settings = try await client.updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                llmProvider: provider,
                llmBaseUrl: nil,
                llmModel: nil,
                llmApiKey: nil
            )
            applyLlmDrafts(from: settings)
            message = assistantSourceMessage(provider)
            await probeLlm()
            await persistRecommendedOllamaModelIfNeeded()
        } catch {
            message = error.localizedDescription
        }
    }

    func saveLlmConnection() async {
        isUpdatingLlm = true
        defer { isUpdatingLlm = false }
        do {
            let client = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            let key = draftLlmApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            settings = try await client.updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                llmProvider: settings?.llmProvider,
                llmBaseUrl: draftLlmBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                llmModel: draftLlmModel.trimmingCharacters(in: .whitespacesAndNewlines),
                llmApiKey: key.isEmpty ? nil : key
            )
            draftLlmApiKey = ""
            applyLlmDrafts(from: settings)
            message = "Assistant connection saved."
            await probeLlm()
        } catch {
            message = error.localizedDescription
        }
    }

    func probeLlm() async {
        let provider = settings?.llmProvider ?? .mlxLocal
        guard provider != .mlxLocal else {
            llmProbe = nil
            return
        }
        isProbingLlm = true
        defer { isProbingLlm = false }
        do {
            let probed = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).probeLlm(
                provider: provider,
                baseUrl: draftLlmBaseUrl.isEmpty ? nil : draftLlmBaseUrl
            )
            llmProbe = probed
            if draftLlmModel.isEmpty, let recommended = probed.recommendedModel {
                draftLlmModel = recommended
            }
        } catch {
            llmProbe = LlmEndpointStatus(
                reachable: false,
                error: error.localizedDescription,
                defaultBaseUrl: draftLlmBaseUrl.isEmpty ? "http://127.0.0.1:11434" : draftLlmBaseUrl
            )
        }
    }

    private func applyLlmDrafts(from settings: AppSettings?) {
        guard let settings else { return }
        draftLlmBaseUrl = settings.llmBaseUrl
        draftLlmModel = settings.llmModel
    }

    /// Probe fills the draft picker before we persist. Persist the recommended
    /// Ollama model whenever Settings still has an empty `llm_model`.
    private func persistRecommendedOllamaModelIfNeeded() async {
        guard settings?.llmProvider == .ollama else { return }
        let saved = settings?.llmModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard saved.isEmpty else { return }
        let chosen = [draftLlmModel, llmProbe?.recommendedModel ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !chosen.isEmpty else { return }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                llmProvider: nil,
                llmBaseUrl: nil,
                llmModel: chosen,
                llmApiKey: nil
            )
            applyLlmDrafts(from: settings)
        } catch {
            message = error.localizedDescription
        }
    }

    private func assistantSourceMessage(_ provider: LlmProvider) -> String {
        switch provider {
        case .mlxLocal:
            "Ask will use the selected Qwen3.5 MLX model through AfterRay's signed worker."
        case .ollama:
            "Ask will use a local Ollama model."
        case .openaiCompatible:
            "Ask will use the OpenAI-compatible endpoint you configure."
        }
    }

    private func displayName(for packID: String?) -> String {
        library?.packs.first(where: { $0.id == packID })?.name ?? "model"
    }

    /// The queue view renders the daemon's own state, so all this has to do is
    /// keep the rate estimate fed and the poller running while there is work.
    private func applyDownloadState(_ download: ModelDownloadProgress?) {
        updateDownloadRate(download)
        guard let download else { return }
        if download.state == .failed, let error = download.error, !error.isEmpty {
            message = error
        }
        if download.isActive { startDownloadMonitor() }
    }

    /// Derives a transfer rate from the daemon's byte counter — the wire carries
    /// bytes, never speed, so the queue's ETA has to be measured here.
    private func updateDownloadRate(_ download: ModelDownloadProgress?) {
        guard let download, download.state == .downloading else {
            downloadRateSample = nil
            downloadRateBytesPerSecond = nil
            return
        }
        let now = Date()
        // A different pack, or a byte count that moved backwards (a restarted
        // transfer), invalidates the baseline rather than producing a wild rate.
        guard let previous = downloadRateSample,
              previous.packID == download.packId,
              download.bytes >= previous.bytes
        else {
            downloadRateSample = (download.packId, download.bytes, now)
            downloadRateBytesPerSecond = nil
            return
        }
        let elapsed = now.timeIntervalSince(previous.at)
        // The poller ticks every 350 ms; a shorter gap is mostly jitter, so keep
        // the older baseline and measure across a longer window instead.
        guard elapsed >= 0.3 else { return }
        let sample = Double(download.bytes - previous.bytes) / elapsed
        downloadRateSample = (download.packId, download.bytes, now)
        // Smoothed, because a raw per-tick rate swings the ETA by whole minutes.
        downloadRateBytesPerSecond = downloadRateBytesPerSecond
            .map { $0 * 0.7 + sample * 0.3 } ?? sample
    }

    private func startDownloadMonitor() {
        guard modelDownloadMonitor == nil else { return }
        let socket = DaemonSupervisor.shared.socketPath
        modelDownloadMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { modelDownloadMonitor = nil }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    let next = try await UnixSocketDaemonClient(socketPath: socket).modelLibrary()
                    let wasActive = library?.download?.isActive == true
                    library = next
                    applyDownloadState(next.download)
                    if wasActive, next.download == nil {
                        message = "Model downloads finished."
                        storage = AfterRayStorageSnapshot.measure(
                            dataDirectory: URL(fileURLWithPath: dataDirectoryPath, isDirectory: true),
                            modelDirectory: URL(fileURLWithPath: modelDirectoryPath, isDirectory: true),
                            runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
                        )
                    }
                    guard next.download?.isActive == true else { return }
                } catch is CancellationError {
                    return
                } catch {
                    message = error.localizedDescription
                    return
                }
            }
        }
    }
}
