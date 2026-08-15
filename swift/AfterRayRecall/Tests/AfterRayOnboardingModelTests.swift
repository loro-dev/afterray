import XCTest
@testable import AfterRayRecall

@MainActor
final class AfterRayOnboardingModelTests: XCTestCase {
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

    func testDownloadRequiredModelsDoesNotDownloadOptionalLlm() async {
        var downloaded: [String] = []
        var installed = false
        let model = makeModel(
            status: { Self.library(asrPresent: installed) },
            download: { packID in
                downloaded.append(packID)
                installed = true
                return Self.library(asrPresent: true)
            }
        )

        model.advanceFromHotKey()
        model.advanceFromCli()
        await model.refreshModels()
        await model.downloadRequiredModels()

        XCTAssertEqual(downloaded, ["asr"])
        XCTAssertTrue(model.requiredModelsReady)
        XCTAssertFalse(
            model.modelLibrary?.packs.first(where: { $0.id == "llm_qwen35_4b_mlx4" })?.present ?? true
        )
    }

    private func makeModel(
        status: @escaping @MainActor @Sendable () async throws -> ModelLibrary,
        download: @escaping @MainActor @Sendable (String) async throws -> ModelLibrary
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

    private static func library(asrPresent: Bool) -> ModelLibrary {
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
                    id: "llm_qwen35_4b_mlx4",
                    name: "Qwen3.5 4B · MLX 4-bit",
                    capability: "llm_vlm",
                    path: "/tmp/models/Qwen3.5-4B-MLX-4bit",
                    present: false,
                    bytes: 0,
                    required: false,
                    expectedBytes: 3_061_129_077
                ),
            ]
        )
    }
}
