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
    case chat
    case onboarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: "Recall"
        case .settings: "Settings"
        case .chat: "Chat"
        case .onboarding: "Welcome"
        }
    }

    static var launchArgument: LabSurface {
        if CommandLine.arguments.contains("--onboarding") { return .onboarding }
        if CommandLine.arguments.contains("--settings") { return .settings }
        if CommandLine.arguments.contains("--chat") { return .chat }
        return .recall
    }
}

private struct VisualLabView: View {
    @State private var surface: LabSurface = LabSurface.launchArgument
    @State private var settingsPage: AfterRaySettingsPage = CommandLine.arguments.contains("--models") ? .models : .general
    @State private var settingsModel = SettingsPreviewModel()
    @State private var scenario: RecallScenario = .long
    @State private var daySummaryKind: DaySummaryLabKind = .matching
    @State private var playheadMs = RecallScenario.long.moments[12].capturedAtMs
    /// Clicking the status capsule walks the states so every label and dot
    /// colour is reachable without a daemon.
    @State private var labRecordingState: DaemonRecordingState = .recording
    @State private var tuning = RecallVisualTuning.standard
    @State private var favoriteOverrides: Set<String> = []
    @State private var searchSession: RecallSearchSession?
    /// A lab-only store so tinkering never rebinds the shipping shortcut.
    @State private var labHotKeys: RecallHotKeyStore
    @State private var onboardingModel: AfterRayOnboardingModel
    @State private var labGreeting = "Good evening."
    @State private var chatScenario: ChatScenario = CommandLine.arguments.contains("--stream")
        ? .streaming
        : .markdown
    @StateObject private var chat = ChatPreviewModel(scenario: CommandLine.arguments.contains("--stream")
        ? .streaming
        : .markdown)

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
            case .chat:
                chatLab
            case .onboarding:
                onboardingLab
            }
        }
        .onChange(of: scenario, initial: true) { _, newScenario in
            favoriteOverrides = []
            searchSession = newScenario.searchSession
            let moments = newScenario.moments
            // Search mode opens on its newest match, exactly as the app does.
            if let frame = searchSession?.selectedFrame,
               let match = moments.first(where: { $0.id == frame.momentId })
            {
                playheadMs = match.capturedAtMs
                return
            }
            let index = min(max(moments.count / 2, 0), max(moments.count - 1, 0))
            playheadMs = moments.indices.contains(index) ? moments[index].capturedAtMs : 0
        }
    }

    /// Mirrors the app: selecting a filmstrip cell moves the playhead, which
    /// re-runs the crossfade and re-arms the OCR highlight.
    private func selectSearchFrame(_ index: Int) {
        guard var session = searchSession, session.frames.indices.contains(index) else { return }
        session.selectedIndex = index
        searchSession = session
        if let match = moments.first(where: { $0.id == session.frames[index].momentId }) {
            playheadMs = match.capturedAtMs
        }
    }

    private static func nextLabRecordingState(
        _ state: DaemonRecordingState
    ) -> DaemonRecordingState {
        switch state {
        case .recording: .idle
        case .idle: .waiting
        case .waiting: .stopping
        case .stopping: .failed
        case .failed: .recording
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
                onToggleAudio: { _ in },
                onOpenSettings: {},
                recordingState: labRecordingState,
                onToggleRecording: { labRecordingState = Self.nextLabRecordingState(labRecordingState) },
                daySummary: labDaySummary,
                searchSession: searchSession,
                thumbnailLoader: MockSearchData.thumbnailLoader,
                ocrLoader: MockSearchData.ocrLoader,
                onSelectSearchFrame: selectSearchFrame
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
        let exclusions = PreviewOnboardingExclusions()
        return AfterRayOnboardingModel(
            hotKeys: hotKeys,
            privacyActions: AfterRayOnboardingPrivacyActions(
                excludedApps: { exclusions.apps },
                excludedDomains: { exclusions.domains },
                addApp: { exclusions.addSampleApp() },
                removeApp: { bundleID in exclusions.remove(app: bundleID) },
                addDomain: { typed in exclusions.add(domain: typed) },
                removeDomain: { domain in exclusions.remove(domain: domain) },
                displayName: { PreviewOnboardingExclusions.name(for: $0) }
            ),
            cliActions: AfterRayOnboardingCliActions(
                status: { "Preview CLI is ready." },
                isInstalled: { true },
                install: {}
            ),
            modelActions: AfterRayOnboardingModelActions(
                status: { models.library },
                download: { packIDs in models.install(packIDs) }
            )
        )
    }

    /// Stands in for the daemon so the privacy step can be exercised in the lab
    /// — including the normalisation, since a step that silently drops a pasted
    /// URL would look fine here and fail in production.
    @MainActor
    private final class PreviewOnboardingExclusions {
        var apps: [String] = ["com.tencent.xinWeChat"]
        var domains: [String] = []

        private let samples = [
            "com.apple.Safari",
            "com.tinyspeck.slackmacgap",
            "com.apple.mail",
        ]

        func addSampleApp() {
            guard let next = samples.first(where: { !apps.contains($0) }) else { return }
            apps.append(next)
        }

        func remove(app bundleID: String) {
            apps.removeAll { $0 == bundleID }
        }

        func add(domain typed: String) {
            guard let host = Self.host(typed), !domains.contains(host) else { return }
            domains.append(host)
            domains.sort()
        }

        func remove(domain: String) {
            domains.removeAll { $0 == domain }
        }

        static func name(for bundleID: String) -> String {
            switch bundleID {
            case "com.tencent.xinWeChat": "WeChat"
            case "com.apple.Safari": "Safari"
            case "com.tinyspeck.slackmacgap": "Slack"
            case "com.apple.mail": "Mail"
            default: bundleID
            }
        }

        private static func host(_ input: String) -> String? {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutScheme = trimmed.components(separatedBy: "://").last ?? trimmed
            let host = withoutScheme
                .components(separatedBy: CharacterSet(charactersIn: "/?#"))
                .first?
                .components(separatedBy: ":").first?
                .lowercased()
            guard let host, host.contains(".") else { return nil }
            return host
        }
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
                    id: "llm_qwen35_4b_mlx4",
                    name: "Qwen3.5 4B · MLX 4-bit",
                    capability: "llm_vlm",
                    path: "/tmp/Qwen3.5-4B-MLX-4bit",
                    present: false,
                    bytes: 0,
                    required: false,
                    expectedBytes: 3_061_129_077
                ),
            ]
        )

        func install(_ packIDs: [String]) -> ModelLibrary {
            library = ModelLibrary(
                directory: library.directory,
                packs: library.packs.map { pack in
                    guard packIDs.contains(pack.id) else { return pack }
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

    private var chatLab: some View {
        HSplitView {
            ZStack {
                Color(red: 0.025, green: 0.022, blue: 0.026).ignoresSafeArea()
                AfterRayChatView(
                    model: chat,
                    onClose: {},
                    fillsAvailableSpace: true
                )
                .padding(28)
            }
            .frame(minWidth: 760)

            chatTuningPanel
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
        }
        .task(id: chatScenario) {
            chat.apply(chatScenario)
            if chatScenario == .streaming {
                await chat.simulateStream()
            }
        }
    }

    private var chatTuningPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VISUAL LAB")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.red)
                    Text("Chat fixtures")
                        .font(.title2.weight(.semibold))
                }

                Picker("Scene", selection: $chatScenario) {
                    ForEach(ChatScenario.allCases) { scene in
                        Text(scene.title).tag(scene)
                    }
                }
                .pickerStyle(.menu)

                Text("Mock conversations only. Send still streams a canned reply so you can watch markdown land line by line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Replay stream") {
                    Task { await chat.simulateStream() }
                }
                .buttonStyle(.bordered)
                .disabled(chatScenario == .empty)
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

                Picker("Day summary", selection: $daySummaryKind) {
                    ForEach(DaySummaryLabKind.allCases) { kind in
                        Text(kind.title).tag(kind)
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

    private var labDaySummary: DaySummary {
        let origin = scenario.moments.first?.capturedAtMs ?? playheadMs
        // A getter with a preceding statement does not treat the switch as an
        // implicit return, so both the keyword and the explicit type are
        // needed for the branches to type-check.
        return switch daySummaryKind {
        case .matching:
            scenario.daySummary
        case .rich:
            DaySummary.mockRich(around: origin)
        case .facts:
            DaySummary.mockFactsOnly(around: origin)
        case .empty:
            DaySummary(
                day: DaySummaryLayout.localDayKey(ms: origin),
                dayStartMs: DaySummaryLayout.dayBounds(ms: origin).start,
                dayEndMs: DaySummaryLayout.dayBounds(ms: origin).end,
                slots: []
            )
        }
    }

    private func toggleFavorite() {
        guard let selected = RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments) else { return }
        let id = selected.id
        if favoriteOverrides.contains(id) { favoriteOverrides.remove(id) }
        else { favoriteOverrides.insert(id) }
    }
}

private enum DaySummaryLabKind: String, CaseIterable, Identifiable {
    case matching
    case rich
    case facts
    case empty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matching: "Match scene"
        case .rich: "T2 titles"
        case .facts: "Facts only"
        case .empty: "Empty day"
        }
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
