import AfterRayMockData
import AfterRayRecall
import SwiftUI

@main
struct AfterRayVisualLabApp: App {
    var body: some Scene {
        WindowGroup("AfterRay Visual Lab") {
            VisualLabView()
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_320, height: 820)
    }
}

private enum LabSurface: String, CaseIterable, Identifiable {
    case recall
    case settings
    case onboarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: "Recall"
        case .settings: "Settings"
        case .onboarding: "Welcome"
        }
    }

    static var launchArgument: LabSurface {
        if CommandLine.arguments.contains("--onboarding") { return .onboarding }
        if CommandLine.arguments.contains("--settings") { return .settings }
        return .recall
    }
}

private struct VisualLabView: View {
    @State private var surface: LabSurface = LabSurface.launchArgument
    @State private var settingsPage: AfterRaySettingsPage = CommandLine.arguments.contains("--models") ? .models : .general
    @State private var settingsModel = SettingsPreviewModel()
    @State private var scenario: RecallScenario = .long
    @State private var playheadMs = RecallScenario.long.moments[12].capturedAtMs
    @State private var tuning = RecallVisualTuning.standard
    @State private var favoriteOverrides: Set<String> = []
    /// A lab-only store so tinkering never rebinds the shipping shortcut.
    @State private var labHotKeys: RecallHotKeyStore
    @State private var onboardingModel: AfterRayOnboardingModel
    @State private var labGreeting = "Good evening."

    @MainActor
    init() {
        let hotKeys = RecallHotKeyStore(storageKey: "dev.afterray.visual-lab.hotkey")
        _labHotKeys = State(initialValue: hotKeys)
        _onboardingModel = State(initialValue: Self.makeOnboardingModel(hotKeys: hotKeys))
    }

    private var moments: [RecallMoment] {
        scenario.moments.map { moment in
            guard favoriteOverrides.contains(moment.id) else { return moment }
            var copy = moment
            copy.isFavorite.toggle()
            return copy
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Surface", selection: $surface) {
                ForEach(LabSurface.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            switch surface {
            case .recall:
                recallLab
            case .settings:
                settingsLab
            case .onboarding:
                onboardingLab
            }
        }
        .onChange(of: scenario) { _, newScenario in
            favoriteOverrides = []
            let moments = newScenario.moments
            let index = min(max(moments.count / 2, 0), max(moments.count - 1, 0))
            playheadMs = moments.indices.contains(index) ? moments[index].capturedAtMs : 0
        }
    }

    private var recallLab: some View {
        HSplitView {
            RecallView(
                moments: moments,
                playheadMs: $playheadMs,
                loadState: scenario.loadState,
                tuning: tuning,
                imageLoader: MockArtifactFactory.loader,
                onToggleFavorite: toggleFavorite,
                onToggleAudio: { _ in }
            )
            .frame(minWidth: 760)

            tuningPanel
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
        }
    }

    /// Practising the shortcut needs the real Carbon hot key, which only the
    /// app installs — the lab exercises everything else, including recording.
    private var onboardingLab: some View {
        ZStack {
            Color(red: 0.025, green: 0.022, blue: 0.026).ignoresSafeArea()
            VStack(spacing: 18) {
                AfterRayOnboardingView(model: onboardingModel, greeting: labGreeting) {
                    replayOnboarding()
                }
                .id(ObjectIdentifier(onboardingModel))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 18)

                HStack(spacing: 10) {
                    Button("Simulate the press") { onboardingModel.registerPractice() }
                    Picker("", selection: $labGreeting) {
                        ForEach(Self.labGreetings, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Button("Replay", action: replayOnboarding)
                }
            }
        }
    }

    private static let labGreetings = ["Good morning.", "Good afternoon.", "Good evening.", "Still up?"]

    private func replayOnboarding() {
        onboardingModel = Self.makeOnboardingModel(hotKeys: labHotKeys)
    }

    @MainActor
    private static func makeOnboardingModel(hotKeys: RecallHotKeyStore) -> AfterRayOnboardingModel {
        let models = PreviewOnboardingModels()
        return AfterRayOnboardingModel(
            hotKeys: hotKeys,
            cliActions: AfterRayOnboardingCliActions(
                status: { "Preview CLI is ready." },
                isInstalled: { true },
                install: {}
            ),
            modelActions: AfterRayOnboardingModelActions(
                status: { models.library },
                download: { packID in models.install(packID) }
            )
        )
    }

    @MainActor
    private final class PreviewOnboardingModels {
        var library = ModelLibrary(
            directory: "/Users/demo/Library/Application Support/AfterRay/Models",
            packs: [
                ModelPack(
                    id: "asr",
                    name: "Qwen3 ASR",
                    capability: "asr",
                    path: "/tmp/Qwen3-ASR-1.7B",
                    present: false,
                    bytes: 0,
                    required: true,
                    expectedBytes: 4_200_000_000
                ),
                ModelPack(
                    id: "embedding",
                    name: "Text embeddings",
                    capability: "embedding",
                    path: "/tmp/nomic.gguf",
                    present: true,
                    bytes: 274_000_000,
                    required: true,
                    expectedBytes: 274_000_000
                ),
                ModelPack(
                    id: "llm",
                    name: "Qwen3.6 27B",
                    capability: "llm",
                    path: "/tmp/qwen.gguf",
                    present: false,
                    bytes: 0,
                    required: false,
                    expectedBytes: 16_817_244_384
                ),
            ]
        )

        func install(_ packID: String) -> ModelLibrary {
            library = ModelLibrary(
                directory: library.directory,
                packs: library.packs.map { pack in
                    guard pack.id == packID else { return pack }
                    return ModelPack(
                        id: pack.id,
                        name: pack.name,
                        capability: pack.capability,
                        path: pack.path,
                        present: true,
                        bytes: pack.expectedBytes ?? pack.bytes,
                        required: pack.required,
                        note: pack.note,
                        expectedBytes: pack.expectedBytes
                    )
                }
            )
            return library
        }
    }

    private var settingsLab: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            AfterRaySettingsView(
                model: settingsModel,
                onClose: { settingsModel.message = "Close is a no-op in Visual Lab." },
                initialPage: settingsPage
            )
        }
        .background(Color(red: 0.025, green: 0.022, blue: 0.026))
    }

    private var tuningPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VISUAL LAB")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.red)
                    Text("Recall tuning")
                        .font(.title2.weight(.semibold))
                }

                Picker("Scene", selection: $scenario) {
                    ForEach(RecallScenario.allCases) { scene in
                        Text(scene.title).tag(scene)
                    }
                }
                .pickerStyle(.menu)

                VStack(spacing: 18) {
                    TuneSlider(title: "Top scrim", value: $tuning.topScrimOpacity, range: 0...1)
                    TuneSlider(title: "Bottom scrim", value: $tuning.bottomScrimOpacity, range: 0...1)
                    TuneSlider(title: "Timeline density", value: $tuning.timelineDensity, range: 0.04...0.36)
                    TuneSlider(title: "Segment height", value: $tuning.timelineSegmentHeight, range: 30...72)
                    TuneSlider(title: "Segment gap", value: $tuning.timelineSegmentGap, range: 0...8)
                    TuneSlider(title: "Drag sensitivity", value: $tuning.dragPointsPerMoment, range: 20...120)
                }

                Button("Reset tuning") { tuning = .standard }
                    .buttonStyle(.bordered)
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func toggleFavorite() {
        guard let selected = RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments) else { return }
        let id = selected.id
        if favoriteOverrides.contains(id) { favoriteOverrides.remove(id) }
        else { favoriteOverrides.insert(id) }
    }
}

private struct TuneSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
