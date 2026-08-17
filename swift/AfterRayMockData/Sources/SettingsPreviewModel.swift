import AfterRayRecall
import AppKit
import Foundation

@MainActor
public final class SettingsPreviewModel: ObservableObject, AfterRaySettingsModeling {
    @Published public var settings: AppSettings? = AppSettings(
        dataDir: "/Users/demo/.afterray/v0-data",
        modelDir: "/Users/demo/.afterray/models",
        recordAudio: true,
        captureIntervalSeconds: 10
    )
    @Published public var library: ModelLibrary?
    @Published public var storage = AfterRayStorageSnapshot(
        vaultBytes: 1_800_000_000,
        modelBytes: 2_460_000_000,
        runtimeBytes: 420_000_000,
        volumeTotal: 1_000_000_000_000,
        volumeFree: 214_000_000_000
    )
    @Published public var message: String?
    @Published public var isRefreshing = false
    @Published public var downloadRateBytesPerSecond: Double?
    @Published public var isControllingDownload = false
    @Published public var isUpdatingAudio = false
    @Published public var isUpdatingStorageLimit = false
    @Published public var isUpdatingLanguage = false
    @Published public var isUpdatingExclusions = false
    @Published public var isClearingHistory = false
    @Published public var recordAudio = true
    @Published public var excludedBundleIds: [String] = []
    @Published public var excludedDomains: [String] = []
    @Published public var llmProbe: LlmEndpointStatus? = LlmEndpointStatus(
        reachable: true,
        models: [
            LlmRemoteModel(id: "qwen3.6:latest"),
            LlmRemoteModel(id: "qwen2.5vl:3b"),
        ],
        recommendedModel: "qwen3.6:latest"
    )
    @Published public var isProbingLlm = false
    @Published public var isUpdatingLlm = false
    @Published public var draftLlmBaseUrl = ""
    @Published public var draftLlmModel = "qwen3.6:latest"
    @Published public var draftLlmApiKey = ""
    @Published public var cliStatus = "Not installed. Other AI agents cannot call `afterray` yet."
    @Published public var isInstallingCli = false
    @Published public var isUpdatingCliEvidence = false
    @Published public var cliInstalled = false
    @Published public var updatesSupported = true
    @Published public var automaticUpdates = true
    @Published public var updateStatus = "You are on 0.0.1 (build 1). AfterRay checks once a day."
    @Published public var developerOptionsUnlocked = false
    @Published public var developerOptionsEnabled = false
    @Published public var recentJobs: [ModelJob] = [
        ModelJob(
            id: "job-asr",
            capability: "asr",
            adapter: "qwen3-asr",
            state: "failed",
            lastError: "model asset is missing"
        ),
        ModelJob(
            id: "job-ocr",
            capability: "ocr",
            adapter: "vision-ocr",
            state: "done"
        ),
    ]

    private var previewDownloadTask: Task<Void, Never>?

    public var dataDirectoryPath: String { settings?.dataDir ?? "/tmp/afterray-data" }
    public var modelDirectoryPath: String { settings?.modelDir ?? "/tmp/afterray-models" }
    public var logDirectoryPath: String { AfterRayLog.directory.path }
    public var logFilePath: String { AfterRayLog.fileURL.path }

    public init(missingASR: Bool = true) {
        library = ModelLibrary(
            directory: modelDirectoryPath,
            packs: [
                ModelPack(
                    id: "llm_qwen35_4b_mlx4",
                    name: "Qwen3.5-4B MLX 4-bit",
                    capability: "llm_vlm",
                    path: "\(modelDirectoryPath)/Qwen3.5-4B-MLX-4bit",
                    present: false,
                    bytes: 0,
                    required: false,
                    note: "Recommended local model · mlx-community · Apache 2.0",
                    expectedBytes: 3_061_129_077,
                    state: .notDownloaded,
                    revision: "32f3e8ecf65426fc3306969496342d504bfa13f3"
                ),
                ModelPack(
                    id: "llm_qwen35_9b_mlx4",
                    name: "Qwen3.5-9B MLX 4-bit",
                    capability: "llm_vlm",
                    path: "\(modelDirectoryPath)/Qwen3.5-9B-MLX-4bit",
                    present: false,
                    bytes: 0,
                    required: false,
                    note: "Higher-quality local assistant · approximately 5.97 GB",
                    expectedBytes: 5_977_071_067,
                    state: .notDownloaded,
                    revision: "938d8919941c6e7efd3c7150eff7fe9d12afa631"
                ),
                ModelPack(
                    id: "asr",
                    name: "Qwen3 ASR",
                    capability: "asr",
                    path: "\(modelDirectoryPath)/Qwen3-ASR-1.7B",
                    present: !missingASR,
                    bytes: missingASR ? 0 : 4_200_000_000,
                    required: true,
                    note: "Qwen/Qwen3-ASR-1.7B · Rust/Candle",
                    expectedBytes: 4_200_000_000
                ),
                ModelPack(
                    id: "embedding",
                    name: "Text embeddings",
                    capability: "embedding",
                    path: "\(modelDirectoryPath)/nomic-embed-text-v1.5.Q4_K_M.gguf",
                    present: true,
                    bytes: 84_000_000,
                    required: true,
                    note: "nomic-embed-text v1.5 Q4 · llama.cpp",
                    expectedBytes: 84_000_000
                ),
            ]
        )
    }

    public func refresh() async {
        isRefreshing = true
        try? await Task.sleep(for: .milliseconds(180))
        isRefreshing = false
        message = nil
    }

    public func setRecordAudio(_ enabled: Bool) async {
        recordAudio = enabled
        message = enabled ? "Audio recording is on." : "Audio recording is off."
    }

    public func setStorageLimitBytes(_ bytes: UInt64) async {
        guard let current = settings else { return }
        isUpdatingStorageLimit = true
        settings = replacing(current, storageLimitBytes: bytes)
        isUpdatingStorageLimit = false
        message = "Preview memory limit updated."
    }

    public func setUiLanguage(_ code: String) async {
        guard let current = settings else { return }
        isUpdatingLanguage = true
        settings = replacing(current, uiLanguage: code)
        isUpdatingLanguage = false
        message = "Preview interface language updated."
    }

    public func setSummaryLanguage(_ code: String) async {
        guard let current = settings else { return }
        isUpdatingLanguage = true
        settings = replacing(current, summaryLanguage: code)
        isUpdatingLanguage = false
        message = "Preview summary language updated."
    }

    public func excludeBundle(_ bundleID: String) async {
        if !excludedBundleIds.contains(bundleID) {
            excludedBundleIds.append(bundleID)
        }
    }

    public func includeBundle(_ bundleID: String) async {
        excludedBundleIds.removeAll { $0 == bundleID }
    }

    /// No file picker in a preview — the lab stands in with the next app that
    /// is not already on the list, so the button still visibly does something.
    public func excludeChosenApp() async {
        let samples = ["com.tinyspeck.slackmacgap", "com.apple.mail", "com.figma.Desktop"]
        guard let next = samples.first(where: { !excludedBundleIds.contains($0) }) else { return }
        await excludeBundle(next)
    }

    /// The preview stands in for the daemon's normaliser, so a pasted URL in
    /// the lab lands as the same host it would in production.
    public func excludeDomain(_ input: String) async {
        guard let host = SettingsPreviewModel.previewHost(input),
              !excludedDomains.contains(host)
        else { return }
        excludedDomains.append(host)
        excludedDomains.sort()
    }

    public func includeDomain(_ domain: String) async {
        excludedDomains.removeAll { $0 == domain }
    }

    private static func previewHost(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutScheme = trimmed.components(separatedBy: "://").last ?? trimmed
        let host = withoutScheme
            .components(separatedBy: CharacterSet(charactersIn: "/?#"))
            .first?
            .components(separatedBy: ":").first?
            .lowercased()
        guard let host, host.contains("."), !host.isEmpty else { return nil }
        return host
    }

    public func clearHistory(_: HistoryScope) async {
        message = "Deleted preview history."
    }

    public func reveal(_ path: String) {
        message = "Would reveal \(path)"
    }

    /// Queues packs the way the daemon does — one transferring, the rest
    /// waiting — so the lab exercises the real queue instead of a lone bar.
    public func download(packID: String?) async {
        guard let current = library else { return }
        let wanted = packID.map { [$0] } ?? current.packs.filter { !$0.present }.map(\.id)
        var active = current.download
        var queued = active?.queuedPackIds ?? []
        for id in wanted where id != active?.packId && !queued.contains(id) {
            if active == nil {
                active = progress(packID: id, state: .downloading, bytes: 0)
            } else {
                queued.append(id)
            }
        }
        guard let active else {
            message = "Preview has every pack installed."
            return
        }
        library = ModelLibrary(
            directory: current.directory,
            packs: current.packs,
            download: replacing(active, queuedPackIds: queued)
        )
        downloadRateBytesPerSecond = 12_400_000
        message = nil
        startPreviewDownload()
    }

    public func pauseModelDownloads() async {
        guard let current = library, let active = current.download else { return }
        library = ModelLibrary(
            directory: current.directory,
            packs: current.packs,
            download: replacing(active, state: .paused)
        )
        downloadRateBytesPerSecond = nil
    }

    public func resumeModelDownloads() async {
        guard let current = library, let active = current.download else { return }
        library = ModelLibrary(
            directory: current.directory,
            packs: current.packs,
            download: replacing(active, state: .downloading)
        )
        downloadRateBytesPerSecond = 12_400_000
        startPreviewDownload()
    }

    public func cancelModelDownloads() async {
        previewDownloadTask?.cancel()
        previewDownloadTask = nil
        downloadRateBytesPerSecond = nil
        guard let current = library else { return }
        library = ModelLibrary(directory: current.directory, packs: current.packs)
        message = "Preview cancelled every download."
    }

    public func cancelModelDownload(packID: String) async {
        guard let current = library, let active = current.download else { return }
        if active.packId == packID {
            // Promote whatever was waiting behind it, exactly as the daemon does.
            guard let next = active.queuedPackIds.first else {
                await cancelModelDownloads()
                message = "Preview cancelled the \(name(of: packID)) download."
                return
            }
            library = ModelLibrary(
                directory: current.directory,
                packs: current.packs,
                download: progress(
                    packID: next,
                    state: .downloading,
                    bytes: 0,
                    queuedPackIds: Array(active.queuedPackIds.dropFirst())
                )
            )
        } else {
            library = ModelLibrary(
                directory: current.directory,
                packs: current.packs,
                download: replacing(
                    active,
                    queuedPackIds: active.queuedPackIds.filter { $0 != packID }
                )
            )
        }
        message = "Preview cancelled the \(name(of: packID)) download."
    }

    public func updateModelDownloadEndpoint(_ endpoint: String) async {
        guard let current = settings else { return }
        let cleaned = endpoint.trimmingCharacters(in: .whitespaces)
        settings = AppSettings(
            dataDir: current.dataDir,
            modelDir: current.modelDir,
            recordAudio: current.recordAudio,
            captureIntervalSeconds: current.captureIntervalSeconds,
            storageLimitBytes: current.storageLimitBytes,
            excludedBundleIds: current.excludedBundleIds,
            protectedBundleIds: current.protectedBundleIds,
            excludedDomains: current.excludedDomains,
            llmProvider: current.llmProvider,
            llmBaseUrl: current.llmBaseUrl,
            llmModel: current.llmModel,
            llmApiKeySet: current.llmApiKeySet,
            uiLanguage: current.uiLanguage,
            summaryLanguage: current.summaryLanguage,
            languageOptions: current.languageOptions,
            modelDownloadEndpoint: cleaned
        )
        message = cleaned.isEmpty
            ? "Preview: downloads use huggingface.co."
            : "Preview: downloads use \(cleaned)."
    }

    // MARK: Preview download simulation

    private func startPreviewDownload() {
        guard previewDownloadTask == nil else { return }
        previewDownloadTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled, stepPreviewDownload() else { break }
            }
            self?.previewDownloadTask = nil
        }
    }

    /// Advances the transfer one tick. Returns false when there is nothing left
    /// to drive, which retires the task.
    private func stepPreviewDownload() -> Bool {
        guard let current = library, let active = current.download else { return false }
        guard active.state == .downloading else { return true }
        let expected = active.expectedBytes ?? 1
        let next = min(active.bytes + UInt64(Double(expected) * 0.05), expected)
        guard next >= expected else {
            library = ModelLibrary(
                directory: current.directory,
                packs: current.packs,
                download: replacing(active, bytes: next)
            )
            return true
        }
        let packs = current.packs.map { pack -> ModelPack in
            guard pack.id == active.packId else { return pack }
            return ModelPack(
                id: pack.id,
                name: pack.name,
                capability: pack.capability,
                path: pack.path,
                present: true,
                bytes: pack.expectedBytes ?? pack.bytes,
                required: pack.required,
                note: pack.note,
                expectedBytes: pack.expectedBytes,
                state: .ready,
                revision: pack.revision
            )
        }
        guard let following = active.queuedPackIds.first else {
            library = ModelLibrary(directory: current.directory, packs: packs)
            downloadRateBytesPerSecond = nil
            message = "Preview finished every download."
            return false
        }
        library = ModelLibrary(
            directory: current.directory,
            packs: packs,
            download: progress(
                packID: following,
                state: .downloading,
                bytes: 0,
                queuedPackIds: Array(active.queuedPackIds.dropFirst())
            )
        )
        return true
    }

    private func name(of packID: String) -> String {
        library?.packs.first { $0.id == packID }?.name ?? packID
    }

    private func progress(
        packID: String,
        state: ModelPackState,
        bytes: UInt64,
        queuedPackIds: [String] = []
    ) -> ModelDownloadProgress {
        ModelDownloadProgress(
            packId: packID,
            queuedPackIds: queuedPackIds,
            state: state,
            bytes: bytes,
            expectedBytes: library?.packs.first { $0.id == packID }?.expectedBytes,
            completedFiles: 0,
            totalFiles: 10
        )
    }

    private func replacing(
        _ progress: ModelDownloadProgress,
        state: ModelPackState? = nil,
        bytes: UInt64? = nil,
        queuedPackIds: [String]? = nil
    ) -> ModelDownloadProgress {
        ModelDownloadProgress(
            packId: progress.packId,
            queuedPackIds: queuedPackIds ?? progress.queuedPackIds,
            state: state ?? progress.state,
            bytes: bytes ?? progress.bytes,
            expectedBytes: progress.expectedBytes,
            completedFiles: progress.completedFiles,
            totalFiles: progress.totalFiles,
            error: progress.error
        )
    }

    public func remove(packID: String) async {
        guard let current = library else { return }
        library = ModelLibrary(
            directory: current.directory,
            packs: current.packs.map { pack in
                guard pack.id == packID else { return pack }
                return ModelPack(
                    id: pack.id,
                    name: pack.name,
                    capability: pack.capability,
                    path: pack.path,
                    present: false,
                    bytes: 0,
                    required: pack.required,
                    note: pack.note,
                    expectedBytes: pack.expectedBytes,
                    state: .notDownloaded,
                    revision: pack.revision
                )
            }
        )
        message = "Preview removed \(packID)."
    }

    public func revealLogs() {
        message = "Would reveal \(logDirectoryPath)"
    }

    public func copyDiagnostics() {
        message = "Preview diagnostics copied."
    }

    public func setLlmProvider(_ provider: LlmProvider) async {
        let current = settings
        settings = AppSettings(
            dataDir: current?.dataDir ?? dataDirectoryPath,
            modelDir: current?.modelDir ?? modelDirectoryPath,
            recordAudio: recordAudio,
            captureIntervalSeconds: 10,
            storageLimitBytes: current?.storageLimitBytes ?? AppSettings.defaultStorageLimitBytes,
            excludedBundleIds: current?.excludedBundleIds ?? excludedBundleIds,
            protectedBundleIds: current?.protectedBundleIds ?? [],
            llmProvider: provider,
            llmBaseUrl: draftLlmBaseUrl,
            llmModel: draftLlmModel,
            llmApiKeySet: current?.llmApiKeySet ?? false,
            uiLanguage: current?.uiLanguage ?? AppSettings.defaultLanguage,
            summaryLanguage: current?.summaryLanguage ?? AppSettings.defaultLanguage,
            languageOptions: current?.languageOptions ?? []
        )
        message = "Preview switched assistant source to \(provider.title)."
    }

    private func replacing(
        _ current: AppSettings,
        storageLimitBytes: UInt64? = nil,
        uiLanguage: String? = nil,
        summaryLanguage: String? = nil
    ) -> AppSettings {
        AppSettings(
            dataDir: current.dataDir,
            modelDir: current.modelDir,
            recordAudio: current.recordAudio,
            captureIntervalSeconds: current.captureIntervalSeconds,
            storageLimitBytes: storageLimitBytes ?? current.storageLimitBytes,
            excludedBundleIds: current.excludedBundleIds,
            protectedBundleIds: current.protectedBundleIds,
            llmProvider: current.llmProvider,
            llmBaseUrl: current.llmBaseUrl,
            llmModel: current.llmModel,
            llmApiKeySet: current.llmApiKeySet,
            uiLanguage: uiLanguage ?? current.uiLanguage,
            summaryLanguage: summaryLanguage ?? current.summaryLanguage,
            languageOptions: current.languageOptions
        )
    }

    public func saveLlmConnection() async {
        message = "Preview saved assistant connection."
    }

    public func probeLlm() async {
        isProbingLlm = true
        try? await Task.sleep(for: .milliseconds(120))
        isProbingLlm = false
    }

    public func setCliEvidenceAccess(_ enabled: Bool) async {
        isUpdatingCliEvidence = true
        try? await Task.sleep(for: .milliseconds(80))
        isUpdatingCliEvidence = false
        let until = enabled ? Int64(Date().timeIntervalSince1970 * 1000) + 30 * 60 * 1000 : nil
        if let current = settings {
            settings = AppSettings(
                dataDir: current.dataDir,
                modelDir: current.modelDir,
                recordAudio: current.recordAudio,
                captureIntervalSeconds: current.captureIntervalSeconds,
                storageLimitBytes: current.storageLimitBytes,
                excludedBundleIds: current.excludedBundleIds,
                protectedBundleIds: current.protectedBundleIds,
                excludedDomains: current.excludedDomains,
                llmProvider: current.llmProvider,
                llmBaseUrl: current.llmBaseUrl,
                llmModel: current.llmModel,
                llmApiKeySet: current.llmApiKeySet,
                uiLanguage: current.uiLanguage,
                summaryLanguage: current.summaryLanguage,
                languageOptions: current.languageOptions,
                modelDownloadEndpoint: current.modelDownloadEndpoint,
                cliEvidenceUntilMs: until
            )
        }
        message = enabled
            ? "Preview opened a 30-minute CLI evidence window."
            : "Preview turned CLI evidence off."
    }

    public func installCli() async {
        isInstallingCli = true
        try? await Task.sleep(for: .milliseconds(200))
        isInstallingCli = false
        cliInstalled = true
        cliStatus = "Installed at ~/.local/bin/afterray and available on PATH."
        message = "Preview installed afterray CLI."
    }

    public func setAutomaticUpdates(_ enabled: Bool) {
        automaticUpdates = enabled
        updateStatus = enabled
            ? "You are on 0.0.1 (build 1). AfterRay checks once a day."
            : "You are on 0.0.1 (build 1). Automatic checks are off."
    }

    public func checkForUpdates() {
        message = "Preview checked for updates."
    }

    public func unlockDeveloperOptions() {
        developerOptionsUnlocked = true
        message = "Developer options unlocked."
    }

    public func setDeveloperOptionsEnabled(_ enabled: Bool) {
        guard developerOptionsUnlocked else { return }
        developerOptionsEnabled = enabled
    }

    public func replayOnboarding() {
        message = "Preview would replay onboarding."
    }
}
