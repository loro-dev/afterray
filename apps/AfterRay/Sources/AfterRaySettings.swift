import AfterRayRecall
import AppKit
import SwiftUI

extension Notification.Name {
    static let afterRayPreferencesDidChange = Notification.Name("dev.afterray.preferences-did-change")
}

// @dec:vault-location-relocation — docs/decisions/active/architecture/2026-08-20-vault-location-relocation.md
enum AfterRayPreferences {
    static let recordAudioKey = "dev.afterray.recordAudio"
    static let developerOptionsUnlockedKey = "dev.afterray.developer-options.unlocked"
    static let developerOptionsEnabledKey = "dev.afterray.developer-options.enabled"
    static let computeDashboardKey = "dev.afterray.compute-dashboard.enabled"
    static let memoryDataLocationKey = "dev.afterray.memory-data-location"
    /// Legacy components retained only long enough for a one-way read migration.
    static let memoryDataDirectoryKey = "dev.afterray.memory-data-directory"
    static let memoryDataVolumeRootKey = "dev.afterray.memory-data-volume-root"
    static let memoryDataVolumeUUIDKey = "dev.afterray.memory-data-volume-uuid"

    static var memoryDataLocation: AfterRayDataDirectory.Location? {
        get {
            if UserDefaults.standard.object(forKey: memoryDataLocationKey) != nil {
                // Do not fall back to retired fragments when a canonical value
                // is corrupt; that could reconstruct a different location.
                return canonicalMemoryDataLocation
            }
            guard let path = UserDefaults.standard.string(forKey: memoryDataDirectoryKey),
                  let volumeRoot = UserDefaults.standard.string(forKey: memoryDataVolumeRootKey)
            else {
                return nil
            }
            let legacy = AfterRayDataDirectory.Location(
                url: URL(fileURLWithPath: path, isDirectory: true),
                volumeRoot: URL(fileURLWithPath: volumeRoot, isDirectory: true),
                volumeUUID: UserDefaults.standard.string(forKey: memoryDataVolumeUUIDKey)
            )
            // Write the complete value first. A crash before removing legacy
            // keys still reads this single canonical value, never a mix.
            if storeCanonicalMemoryDataLocation(legacy) {
                removeLegacyMemoryDataLocation()
            }
            return legacy
        }
        set {
            guard let newValue else {
                // Preserve the old canonical value until every legacy fragment
                // is gone, so clearing cannot briefly expose a mixed legacy root.
                removeLegacyMemoryDataLocation()
                UserDefaults.standard.removeObject(forKey: memoryDataLocationKey)
                return
            }
            if storeCanonicalMemoryDataLocation(newValue) {
                removeLegacyMemoryDataLocation()
            }
        }
    }

    /// `nil` distinguishes an unset or malformed canonical value from a legacy
    /// value. Callers that require a post-write proof use this rather than the
    /// compatibility getter above.
    static var canonicalMemoryDataLocation: AfterRayDataDirectory.Location? {
        guard let data = UserDefaults.standard.data(forKey: memoryDataLocationKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AfterRayDataDirectory.Location.self, from: data)
    }

    private static func storeCanonicalMemoryDataLocation(
        _ location: AfterRayDataDirectory.Location
    ) -> Bool {
        // Location contains URLs and optional UUID only, so encoding cannot
        // fail in practice. Do not fall back to independently written keys.
        guard let data = try? JSONEncoder().encode(location) else {
            assertionFailure("could not encode memory data location")
            return false
        }
        UserDefaults.standard.set(data, forKey: memoryDataLocationKey)
        return true
    }

    private static func removeLegacyMemoryDataLocation() {
        UserDefaults.standard.removeObject(forKey: memoryDataDirectoryKey)
        UserDefaults.standard.removeObject(forKey: memoryDataVolumeRootKey)
        UserDefaults.standard.removeObject(forKey: memoryDataVolumeUUIDKey)
    }

    /// Whether the local-computation dashboard is offered at all.
    ///
    /// Off by default. It exposes worker processes, lane assignments, queue
    /// depths and gate thresholds — real answers for someone whose fans are
    /// loud, and implementation detail nobody else asked to see. The controls it
    /// carries all have sane automatic behaviour, so hiding it costs a default
    /// user nothing.
    static var computeDashboardEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: computeDashboardKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: computeDashboardKey)
            NotificationCenter.default.post(name: .afterRayPreferencesDidChange, object: nil)
        }
    }

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

/// Settings as a real window, alongside History, Chat and the compute dashboard.
///
/// It used to render inside the recall overlay and force that overlay open to be
/// reachable, which made changing a setting a full-screen event and left Esc
/// ambiguous between "close settings" and "close AfterRay". A window is also the
/// only way to read a setting while looking at the thing it affects.
@MainActor
final class AfterRaySettingsController: NSObject, NSWindowDelegate {
    static let shared = AfterRaySettingsController()

    let model = AfterRaySettingsModel()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func occupiesActivation(excluding closing: NSWindow?) -> Bool {
        guard let window, window !== closing else { return false }
        return window.isVisible || window.isMiniaturized
    }

    func show(page: AfterRaySettingsPage = .general) {
        RecallOverlayController.shared.dismissForStandardWindow()
        if let window {
            AfterRayStandardWindowPresence.activate()
            window.makeKeyAndOrderFront(nil)
            Task { await model.refresh() }
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AfterRayLocalization.shared.copy.menu.settingsWindow
        // The Settings content already names the active page. Keep a semantic
        // window title for macOS while avoiding a duplicate visual brand line.
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.055, green: 0.05, blue: 0.06, alpha: 1)
        window.contentView = NSHostingView(
            rootView: AfterRaySettingsView(
                model: model,
                onClose: { [weak self] in self?.hide() },
                initialPage: page,
                style: .window
            )
        )
        window.center()
        window.delegate = self
        window.setFrameAutosaveName("dev.afterray.settings-window")
        self.window = window

        AfterRayStandardWindowPresence.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Download progress polling exists for the models page; nothing watches
        // it once the window is gone.
        model.pauseDownloadMonitoring()
        AfterRayStandardWindowPresence.resignIfLast(
            closing: notification.object as? NSWindow
        )
    }
}

@MainActor
final class AfterRaySettingsModel: ObservableObject, AfterRaySettingsModeling {
    @Published var settings: AppSettings?
    @Published var library: ModelLibrary?
    /// The initial window must paint before scanning the vault. `refresh()`
    /// replaces this empty value from a detached filesystem enumeration.
    @Published var storage = AfterRayStorageSnapshot()
    @Published private(set) var excludedBundleDisplayNames: [String: String] = [:]
    @Published var message: String?
    @Published var isRefreshing = false
    @Published var downloadRateBytesPerSecond: Double?
    @Published var isControllingDownload = false
    @Published var isUpdatingAudio = false
    @Published var isUpdatingStorageLimit = false
    @Published var isUpdatingRetention = false
    @Published var isUpdatingGopQuality = false
    @Published var isLoadingGopPreview = false
    @Published var gopQualityPreview: GopQualityPreview?
    @Published var isRelocatingMemory = false
    @Published private(set) var relocationDestinationPath: String?
    @Published var isUpdatingSummarySlot = false
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
    @Published var isUpdatingCliEvidence = false
    @Published private(set) var cliStatus = AfterRayCliInstall.statusSummary(
        copy: AfterRayLocalization.shared.copy
    )
    @Published private(set) var cliInstalled = AfterRayCliInstall.isInstalled
    @Published private(set) var developerOptionsUnlocked = UserDefaults.standard.bool(
        forKey: AfterRayPreferences.developerOptionsUnlockedKey
    )
    @Published private(set) var computeDashboardEnabled = AfterRayPreferences.computeDashboardEnabled
    @Published private(set) var developerOptionsEnabled = UserDefaults.standard.bool(
        forKey: AfterRayPreferences.developerOptionsUnlockedKey
    ) && UserDefaults.standard.bool(
        forKey: AfterRayPreferences.developerOptionsEnabledKey
    )
    private var modelDownloadMonitor: Task<Void, Never>?
    private var downloadRateSample: (packID: String, bytes: UInt64, at: Date)?
    private var gopPreviewGeneration: UInt64 = 0
    private var copy: AfterRayCopy { AfterRayLocalization.shared.copy }

    var recordAudio: Bool { settings?.recordAudio ?? AfterRayPreferences.recordAudio }
    var excludedBundleIds: [String] {
        guard let settings else { return [] }
        let installedProtected = AfterRayPrivacyCatalog.installedBundleIDs(
            from: settings.protectedBundleIds
        )
        let names = excludedBundleDisplayNames
        return Array(Set(settings.excludedBundleIds + installedProtected))
            .sorted { (names[$0] ?? $0) < (names[$1] ?? $1) }
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

    private func measureStorage() async -> AfterRayStorageSnapshot {
        await AfterRayStorageSnapshot.measureOffMain(
            dataDirectory: URL(fileURLWithPath: dataDirectoryPath, isDirectory: true),
            modelDirectory: URL(fileURLWithPath: modelDirectoryPath, isDirectory: true),
            runtimeDirectory: DaemonSupervisor.shared.mlxRuntimeDirectory
        )
    }

    private func appDisplayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AfterRayPrivacyCatalog.protectedName(for: bundleID) ?? bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func refreshExcludedBundleDisplayNames() {
        guard let settings else {
            excludedBundleDisplayNames = [:]
            return
        }
        let installedProtected = AfterRayPrivacyCatalog.installedBundleIDs(
            from: settings.protectedBundleIds
        )
        excludedBundleDisplayNames = Dictionary(
            uniqueKeysWithValues: Set(settings.excludedBundleIds + installedProtected).map {
                ($0, appDisplayName($0))
            }
        )
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        refreshCliStatus()
        do {
            let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            async let nextSettings = daemon.settings()
            async let nextLibrary = daemon.modelLibrary()
            async let nextJobs = daemon.jobs()
            let loaded = try await (nextSettings, nextLibrary, nextJobs)
            settings = loaded.0
            refreshExcludedBundleDisplayNames()
            library = loaded.1
            message = nil
            applyDownloadState(loaded.1.download)
            recentJobs = Array(loaded.2.suffix(8).reversed())
            applyLlmDrafts(from: loaded.0)
            AfterRayPreferences.recordAudio = loaded.0.recordAudio
            AfterRayLocalization.shared.apply(stored: loaded.0.uiLanguage)
            storage = await measureStorage()
        } catch {
            message = error.localizedDescription
        }
    }

    func setCliEvidenceAccess(_ enabled: Bool) async {
        isUpdatingCliEvidence = true
        defer { isUpdatingCliEvidence = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                llmProvider: nil,
                llmBaseUrl: nil,
                llmModel: nil,
                llmApiKey: nil,
                cliEvidenceAccess: enabled
            )
            message = enabled
                ? copy.settings.evidenceOnFor30Minutes
                : copy.settings.evidenceOffToast
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
            let copy = copy
            let destination = try await Task.detached(priority: .utility) {
                try AfterRayCliInstall.install(copy: copy)
            }.value
            message = AfterRayCliInstall.isOnPath
                ? copy.settings.cliInstalledOnPath(destination.path)
                : copy.settings.cliInstalledNeedPath(destination.path)
        } catch {
            message = error.localizedDescription
        }
    }

    private func refreshCliStatus() {
        cliStatus = AfterRayCliInstall.statusSummary(copy: copy)
        cliInstalled = AfterRayCliInstall.isInstalled
    }

    var updatesSupported: Bool { AfterRayUpdater.shared.isEnabled }

    var automaticUpdates: Bool { AfterRayUpdater.shared.automaticallyChecksForUpdates }

    var updateStatus: String {
        if let staged = AfterRayUpdater.shared.stagedVersion {
            return copy.settings.updateReadyOnQuit(staged)
        }
        let build = AfterRayUpdater.hostDescription
        return AfterRayUpdater.shared.automaticallyChecksForUpdates
            ? copy.settings.onVersionChecking(build)
            : copy.settings.onVersionChecksOff(build)
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
        message = copy.settings.developerUnlocked
    }

    func setDeveloperOptionsEnabled(_ enabled: Bool) {
        guard developerOptionsUnlocked else { return }
        developerOptionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AfterRayPreferences.developerOptionsEnabledKey)
    }

    func setComputeDashboardEnabled(_ enabled: Bool) {
        computeDashboardEnabled = enabled
        // The setter posts `afterRayPreferencesDidChange`; the menu bar and the
        // overlay chrome pick the new value up from there.
        AfterRayPreferences.computeDashboardEnabled = enabled
        if !enabled {
            // Take the window away with the switch, and stop the poll it owns:
            // leaving it open would keep sampling for a surface the user just
            // said they do not want.
            ComputeActivityWindowController.shared.close()
        }
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
            message = copy.settings.passwordManagersAlwaysExcluded
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
        panel.prompt = copy.common.exclude
        panel.message = copy.settings.chooseAppNeverRecord
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            message = copy.settings.couldNotReadAppIdentifier
            return
        }
        guard bundleID != "dev.afterray.app" else {
            message = copy.settings.doesNotRecordOwnWindow
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
            message = result.deleted == 1
                ? copy.settings.deletedOneMoment
                : copy.settings.deletedMoments(result.deleted)
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
            refreshExcludedBundleDisplayNames()
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
                ? AfterRayLocalization.shared.copy.settings.audioOn
                : AfterRayLocalization.shared.copy.settings.audioOff
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
                AfterRayLocalization.shared.apply(stored: uiLanguage)
                message = AfterRayLocalization.shared.copy.settings.interfaceSet(languageLabel(uiLanguage))
            } else if let summaryLanguage {
                message = AfterRayLocalization.shared.copy.settings.summarySet(languageLabel(summaryLanguage))
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func languageLabel(_ code: String) -> String {
        let copy = AfterRayLocalization.shared.copy
        return settings?.languageOptions.first { $0.code == code }?.menuTitle(copy) ?? code
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
            storage = await measureStorage()
            message = copy.settings.memoryLimitSet(AfterRayStorageSnapshot.byteCount(bytes))
        } catch {
            message = error.localizedDescription
        }
    }

    func setRetentionDays(_ days: UInt32?) async {
        guard days != settings?.retentionDays else { return }
        isUpdatingRetention = true
        defer { isUpdatingRetention = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                retentionDays: days ?? 0
            )
            storage = await measureStorage()
        } catch {
            message = error.localizedDescription
        }
    }

    func setGopQualityAging(_ enabled: Bool) async {
        guard enabled != settings?.gopQualityAging else { return }
        isUpdatingGopQuality = true
        defer { isUpdatingGopQuality = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                gopQualityAging: enabled
            )
        } catch {
            message = error.localizedDescription
        }
    }

    func previewGopQuality(quantizer: UInt16) async {
        let quantizer = min(max(quantizer, 120), 240)
        gopPreviewGeneration &+= 1
        let generation = gopPreviewGeneration
        isUpdatingGopQuality = true
        isLoadingGopPreview = true
        defer {
            if generation == gopPreviewGeneration {
                isUpdatingGopQuality = false
                isLoadingGopPreview = false
            }
        }
        do {
            let daemon = UnixSocketDaemonClient(socketPath: DaemonSupervisor.shared.socketPath)
            settings = try await daemon.updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                gopWorstQuantizer: quantizer
            )
            let preview = try await daemon.gopQualityPreview(quantizer: quantizer)
            guard generation == gopPreviewGeneration else { return }
            gopQualityPreview = preview
        } catch {
            guard generation == gopPreviewGeneration else { return }
            message = error.localizedDescription
        }
    }

    func clearSensitiveState() {
        gopPreviewGeneration &+= 1
        gopQualityPreview = nil
        isLoadingGopPreview = false
        isUpdatingGopQuality = false
    }

    func chooseMemoryLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = copy.settings.changeMemoryLocation
        guard panel.runModal() == .OK, let selectedDirectory = panel.url else { return }
        do {
            relocationDestinationPath = try DaemonSupervisor.shared
                .relocationDestination(in: selectedDirectory)
                .path
        } catch {
            message = error.localizedDescription
        }
    }

    /// Consume the destination synchronously, before SwiftUI dismisses the
    /// confirmation alert and writes `false` through its presentation binding.
    func confirmMemoryLocation(migrateExistingData: Bool) {
        guard let path = relocationDestinationPath else { return }
        relocationDestinationPath = nil
        isRelocatingMemory = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRelocatingMemory = false }
            do {
                try await DaemonSupervisor.shared.relocateDataDirectory(
                    to: URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent(),
                    migrateExistingData: migrateExistingData
                )
                await self.refresh()
                self.message = self.copy.settings.memoryLocationChanged(self.dataDirectoryPath)
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func cancelMemoryLocationChange() {
        relocationDestinationPath = nil
    }

    func setSummarySlotMinutes(_ minutes: UInt32) async {
        guard minutes != settings?.summarySlotMinutes else { return }
        isUpdatingSummarySlot = true
        defer { isUpdatingSummarySlot = false }
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateSettings(
                recordAudio: nil,
                excludedBundleIds: nil,
                excludedDomains: nil,
                summarySlotMinutes: minutes
            )
            message = copy.settings.newSummariesCover(AppSettings.summaryLengthLabel(minutes, copy: copy))
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
                    ? copy.settings.allPacksInstalled
                    : copy.settings.packReady(displayName(for: packID))
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
        if message == nil { message = copy.settings.cancelledDownload(name) }
    }

    func updateModelDownloadEndpoint(_ endpoint: String) async {
        do {
            settings = try await UnixSocketDaemonClient(
                socketPath: DaemonSupervisor.shared.socketPath
            ).updateModelDownloadEndpoint(endpoint)
            let applied = settings?.modelDownloadEndpoint ?? ""
            message = applied.isEmpty
                ? copy.settings.downloadsUseOfficial
                : copy.settings.downloadsUseEndpoint(applied)
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
            message = copy.settings.removedPack(displayName(for: packID))
            storage = await measureStorage()
        } catch {
            message = error.localizedDescription
        }
    }

    func revealLogs() {
        reveal(AfterRayLog.directory.path)
    }

    func copyDiagnostics() {
        Task { @MainActor in
            let report = await Task.detached(priority: .utility) {
                AfterRayLog.diagnosticsReport()
            }.value
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            AfterRayLog.info("diagnostics report copied")
        }
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
            message = copy.settings.assistantConnectionSaved
            await probeLlm()
        } catch {
            message = error.localizedDescription
        }
    }

    func probeLlm() async {
        guard !isProbingLlm else { return }
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
            await persistRecommendedOllamaModelIfNeeded()
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
            copy.settings.askUsesMlx
        case .ollama:
            copy.settings.askUsesOllama
        case .openaiCompatible:
            copy.settings.askUsesOpenAI
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
                        message = copy.settings.modelDownloadsFinished
                        storage = await measureStorage()
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
