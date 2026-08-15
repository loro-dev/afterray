import XCTest
@testable import AfterRayRecall

@MainActor
final class AfterRayOnboardingModelTests: XCTestCase {
    private final class PrivacyState {
        var apps = ["com.bitwarden.desktop"]
        var refreshes = 0
    }

    func testCliContinuesIntoModelSetup() async {
        let model = makeModel(status: { Self.library(asrPresent: false) }, download: { _ in
            Self.library(asrPresent: true)
        })

        model.advanceFromHotKey()
        XCTAssertEqual(model.stage, .cli)

        model.advanceFromCli()
        XCTAssertEqual(model.stage, .models)
        await model.refreshModels()
        XCTAssertEqual(model.missingRequiredModelPacks.map(\.id), ["asr"])
    }

    func testEveryStageCanNavigateBackToTheShortcut() {
        let model = makeFullModel()

        model.advanceFromHotKey()
        XCTAssertEqual(model.stage, .privacy)
        model.advanceFromPrivacy()
        XCTAssertEqual(model.stage, .cli)
        model.advanceFromCli()
        XCTAssertEqual(model.stage, .models)

        model.goBack()
        XCTAssertEqual(model.stage, .cli)
        model.goBack()
        XCTAssertEqual(model.stage, .privacy)
        model.goBack()
        XCTAssertEqual(model.stage, .hotKey)
    }

    func testShortcutPracticePressesThenKeepsEachKeyHighlighted() {
        let model = AfterRayOnboardingModel(
            hotKeys: RecallHotKeyStore(
                storageKey: "dev.afterray.tests.onboarding.\(UUID().uuidString)"
            )
        )

        model.updatePracticeModifiers([.shift])
        XCTAssertEqual(model.pressedPracticeSegments, ["⇧"])
        XCTAssertEqual(model.highlightedPracticeSegments, ["⇧"])

        model.updatePracticeModifiers([.shift, .command])
        XCTAssertEqual(model.pressedPracticeSegments, ["⇧", "⌘"])
        XCTAssertEqual(model.highlightedPracticeSegments, ["⇧", "⌘"])

        model.updatePracticeModifiers([])
        XCTAssertTrue(model.pressedPracticeSegments.isEmpty)
        XCTAssertEqual(model.highlightedPracticeSegments, ["⇧", "⌘"])

        model.updatePracticeKey(keyCode: 49, isPressed: true)
        XCTAssertEqual(model.pressedPracticeSegments, ["Space"])
        XCTAssertEqual(model.highlightedPracticeSegments, ["⇧", "⌘", "Space"])

        model.updatePracticeKey(keyCode: 49, isPressed: false)
        XCTAssertTrue(model.pressedPracticeSegments.isEmpty)
        XCTAssertEqual(model.highlightedPracticeSegments, ["⇧", "⌘", "Space"])

        model.beginHotKeyRecording()
        XCTAssertTrue(model.highlightedPracticeSegments.isEmpty)
        XCTAssertTrue(model.hotKeys.isRecording)
        model.hotKeys.cancelRecording()
    }

    func testDownloadRequiredModelsDoesNotDownloadOptionalLlm() async {
        var downloaded: [[String]] = []
        var installed = false
        let model = makeModel(
            status: { Self.library(asrPresent: installed, embeddingPresent: installed) },
            download: { packIDs in
                downloaded.append(packIDs)
                installed = true
                return Self.library(asrPresent: true, embeddingPresent: true)
            }
        )

        model.advanceFromHotKey()
        model.advanceFromCli()
        await model.refreshModels()
        await model.downloadRequiredModels()

        XCTAssertEqual(downloaded, [["asr", "embedding"]])
        XCTAssertTrue(model.requiredModelsReady)
        XCTAssertFalse(
            model.modelLibrary?.packs.first(where: { $0.id == "llm_qwen35_4b_mlx4" })?.present ?? true
        )
    }

    func testExistingBackgroundDownloadIsRecoveredAndRequiredPacksCanBeQueued() async {
        var requested: [[String]] = []
        let active = ModelDownloadProgress(
            packId: "llm_qwen35_4b_mlx4",
            bytes: 25,
            expectedBytes: 100
        )
        let model = makeModel(
            status: {
                Self.library(
                    asrPresent: false,
                    embeddingPresent: false,
                    download: active
                )
            },
            download: { packIDs in
                requested.append(packIDs)
                return Self.library(
                    asrPresent: false,
                    embeddingPresent: false,
                    download: ModelDownloadProgress(
                        packId: "llm_qwen35_4b_mlx4",
                        queuedPackIds: packIDs,
                        bytes: 25,
                        expectedBytes: 100
                    )
                )
            }
        )

        model.advanceFromHotKey()
        model.advanceFromCli()
        await model.refreshModels()

        XCTAssertTrue(model.isDownloadingModels)
        XCTAssertEqual(model.modelDownloadPercent, 25)
        XCTAssertTrue(model.hasUnscheduledRequiredModelPacks)

        await model.downloadRequiredModels()
        XCTAssertEqual(requested, [["asr", "embedding"]])
        XCTAssertFalse(model.hasUnscheduledRequiredModelPacks)
        model.stopObservingModelDownloads()
    }

    func testPausedDownloadCanBeResumedFromOnboarding() async {
        var requested: [[String]] = []
        let paused = ModelDownloadProgress(
            packId: "asr",
            state: .paused,
            bytes: 50,
            expectedBytes: 100
        )
        let model = makeModel(
            status: { Self.library(asrPresent: false, embeddingPresent: false, download: paused) },
            download: { packIDs in
                requested.append(packIDs)
                return Self.library(
                    asrPresent: false,
                    embeddingPresent: false,
                    download: ModelDownloadProgress(
                        packId: "asr",
                        queuedPackIds: ["embedding"],
                        bytes: 50,
                        expectedBytes: 100
                    )
                )
            }
        )

        model.advanceFromHotKey()
        model.advanceFromCli()
        await model.refreshModels()

        XCTAssertTrue(model.modelDownloadPaused)
        XCTAssertFalse(model.isDownloadingModels)
        XCTAssertEqual(model.modelDownloadPercent, 50)

        await model.downloadRequiredModels()
        XCTAssertEqual(requested, [["asr", "embedding"]])
        XCTAssertTrue(model.isDownloadingModels)
        model.stopObservingModelDownloads()
    }

    func testPrivacyActionsRefreshAndProtectedAppsCannotBeRemoved() async {
        let privacy = PrivacyState()
        let model = AfterRayOnboardingModel(
            hotKeys: RecallHotKeyStore(
                storageKey: "dev.afterray.tests.onboarding.\(UUID().uuidString)"
            ),
            privacyActions: AfterRayOnboardingPrivacyActions(
                excludedApps: { privacy.apps },
                excludedDomains: { [] },
                protectedApps: { ["com.bitwarden.desktop"] },
                refresh: { privacy.refreshes += 1 },
                addApp: { privacy.apps.append("com.apple.Safari") },
                removeApp: { bundleID in privacy.apps.removeAll { $0 == bundleID } },
                addDomain: { _ in },
                removeDomain: { _ in }
            )
        )

        model.advanceFromHotKey()
        await model.refreshPrivacy()
        XCTAssertGreaterThanOrEqual(privacy.refreshes, 1)

        await model.addPrivacyApp()
        XCTAssertEqual(privacy.apps, ["com.bitwarden.desktop", "com.apple.Safari"])

        await model.removePrivacyApp("com.bitwarden.desktop")
        XCTAssertTrue(privacy.apps.contains("com.bitwarden.desktop"))

        await model.removePrivacyApp("com.apple.Safari")
        XCTAssertFalse(privacy.apps.contains("com.apple.Safari"))
    }

    func testProtectedCatalogOnlyShowsInstalledApps() {
        let installed = Set(["com.bitwarden.desktop", "com.apple.Passwords"])
        let matches = AfterRayPrivacyCatalog.installedBundleIDs(
            from: [
                "com.bitwarden.desktop",
                "com.1password.1password",
                "dev.afterray.app",
                "com.apple.Passwords",
            ],
            locate: { installed.contains($0) ? URL(fileURLWithPath: "/Applications/\($0).app") : nil }
        )

        XCTAssertEqual(matches, ["com.bitwarden.desktop", "com.apple.Passwords"])
    }

    private func makeModel(
        status: @escaping @MainActor @Sendable () async throws -> ModelLibrary,
        download: @escaping @MainActor @Sendable ([String]) async throws -> ModelLibrary
    ) -> AfterRayOnboardingModel {
        AfterRayOnboardingModel(
            hotKeys: RecallHotKeyStore(storageKey: "dev.afterray.tests.onboarding.\(UUID().uuidString)"),
            cliActions: AfterRayOnboardingCliActions(
                status: { "Installed" },
                isInstalled: { true },
                install: {}
            ),
            modelActions: AfterRayOnboardingModelActions(status: status, download: download)
        )
    }

    private func makeFullModel() -> AfterRayOnboardingModel {
        AfterRayOnboardingModel(
            hotKeys: RecallHotKeyStore(
                storageKey: "dev.afterray.tests.onboarding.\(UUID().uuidString)"
            ),
            privacyActions: AfterRayOnboardingPrivacyActions(
                excludedApps: { [] },
                excludedDomains: { [] },
                protectedApps: { [] },
                refresh: {},
                addApp: {},
                removeApp: { _ in },
                addDomain: { _ in },
                removeDomain: { _ in }
            ),
            cliActions: AfterRayOnboardingCliActions(
                status: { "Installed" },
                isInstalled: { true },
                install: {}
            ),
            modelActions: AfterRayOnboardingModelActions(
                status: { Self.library(asrPresent: false) },
                download: { _ in Self.library(asrPresent: true) }
            )
        )
    }

    private static func library(
        asrPresent: Bool,
        embeddingPresent: Bool = true,
        download: ModelDownloadProgress? = nil
    ) -> ModelLibrary {
        ModelLibrary(
            directory: "/tmp/models",
            packs: [
                ModelPack(
                    id: "asr",
                    name: "Qwen3 ASR",
                    capability: "asr",
                    path: "/tmp/models/asr",
                    present: asrPresent,
                    bytes: asrPresent ? 4_200_000_000 : 0,
                    required: true,
                    expectedBytes: 4_200_000_000
                ),
                ModelPack(
                    id: "embedding",
                    name: "Text embeddings",
                    capability: "embedding",
                    path: "/tmp/models/embedding.gguf",
                    present: embeddingPresent,
                    bytes: embeddingPresent ? 84_000_000 : 0,
                    required: true,
                    expectedBytes: 84_000_000
                ),
                ModelPack(
                    id: "llm_qwen35_4b_mlx4",
                    name: "Qwen3.5 4B · MLX 4-bit",
                    capability: "llm_vlm",
                    path: "/tmp/models/Qwen3.5-4B-MLX-4bit",
                    present: false,
                    bytes: 0,
                    required: false,
                    expectedBytes: 3_061_129_077
                ),
            ],
            download: download
        )
    }
}
