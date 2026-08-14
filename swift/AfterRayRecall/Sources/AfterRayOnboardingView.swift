import SwiftUI

public enum AfterRayOnboardingStage: Equatable, Sendable {
    case hotKey
    case cli
    case models
}

/// Optional PATH install hooks. The app host fills these; previews can omit them.
public struct AfterRayOnboardingCliActions: Sendable {
    public var status: @MainActor @Sendable () -> String
    public var isInstalled: @MainActor @Sendable () -> Bool
    public var install: @MainActor @Sendable () async throws -> Void
    public var pathExportLine: @MainActor @Sendable () -> String

    public init(
        status: @escaping @MainActor @Sendable () -> String,
        isInstalled: @escaping @MainActor @Sendable () -> Bool,
        install: @escaping @MainActor @Sendable () async throws -> Void,
        pathExportLine: @escaping @MainActor @Sendable () -> String = {
            #"export PATH="$HOME/.local/bin:$PATH""#
        }
    ) {
        self.status = status
        self.isInstalled = isInstalled
        self.install = install
        self.pathExportLine = pathExportLine
    }
}

/// Model-library hooks supplied by the app host. Keeping the daemon client out
/// of this view makes onboarding usable in previews and tests.
public struct AfterRayOnboardingModelActions: Sendable {
    public var status: @MainActor @Sendable () async throws -> ModelLibrary
    public var download: @MainActor @Sendable (_ packID: String) async throws -> ModelLibrary

    public init(
        status: @escaping @MainActor @Sendable () async throws -> ModelLibrary,
        download: @escaping @MainActor @Sendable (_ packID: String) async throws -> ModelLibrary
    ) {
        self.status = status
        self.download = download
    }
}

/// First-run state. The app owns one of these so the global hotkey handler can
/// tell the window "they just pressed it" while the lesson is on screen.
@MainActor
public final class AfterRayOnboardingModel: ObservableObject {
    @Published public private(set) var didPractice = false
    @Published public private(set) var stage: AfterRayOnboardingStage = .hotKey
    @Published public private(set) var cliStatus = "Not installed yet."
    @Published public private(set) var cliInstalled = false
    @Published public private(set) var isInstallingCli = false
    @Published public var cliMessage: String?
    @Published public private(set) var modelLibrary: ModelLibrary?
    @Published public private(set) var isLoadingModels = false
    @Published public private(set) var isDownloadingModels = false
    @Published public private(set) var downloadingPackID: String?
    @Published public var modelMessage: String?

    public let hotKeys: RecallHotKeyStore
    public let cliActions: AfterRayOnboardingCliActions?
    public let modelActions: AfterRayOnboardingModelActions?

    public init(
        hotKeys: RecallHotKeyStore,
        cliActions: AfterRayOnboardingCliActions? = nil,
        modelActions: AfterRayOnboardingModelActions? = nil
    ) {
        self.hotKeys = hotKeys
        self.cliActions = cliActions
        self.modelActions = modelActions
        refreshCli()
    }

    /// Called when the shortcut fires while the welcome window is up. Returns
    /// false when the press should fall through to the overlay as usual.
    @discardableResult
    public func registerPractice() -> Bool {
        guard stage == .hotKey, !didPractice, !hotKeys.isRecording else { return false }
        didPractice = true
        return true
    }

    public func advanceFromHotKey() {
        guard stage == .hotKey else { return }
        hotKeys.cancelRecording()
        if cliActions != nil {
            stage = .cli
            refreshCli()
        } else if modelActions != nil {
            stage = .models
            Task { await refreshModels() }
        }
    }

    public func advanceFromCli() {
        guard stage == .cli else { return }
        guard modelActions != nil else { return }
        stage = .models
        Task { await refreshModels() }
    }

    public func refreshCli() {
        guard let cliActions else { return }
        cliStatus = cliActions.status()
        cliInstalled = cliActions.isInstalled()
    }

    public func installCli() async {
        guard let cliActions else { return }
        isInstallingCli = true
        cliMessage = nil
        defer {
            isInstallingCli = false
            refreshCli()
        }
        do {
            try await cliActions.install()
            refreshCli()
            cliMessage = cliInstalled
                ? "CLI is ready for other agents."
                : "Installed. Add ~/.local/bin to your PATH if needed."
        } catch {
            cliMessage = error.localizedDescription
        }
    }

    public var pathExportLine: String {
        cliActions?.pathExportLine() ?? #"export PATH="$HOME/.local/bin:$PATH""#
    }

    public var requiredModelPacks: [ModelPack] {
        modelLibrary?.packs.filter(\.required) ?? []
    }

    public var missingRequiredModelPacks: [ModelPack] {
        requiredModelPacks.filter { !$0.present }
    }

    public var requiredModelsReady: Bool {
        guard modelLibrary != nil else { return false }
        return missingRequiredModelPacks.isEmpty
    }

    public var modelDownloadProgress: Double? {
        modelLibrary?.download?.fraction
    }

    public func refreshModels() async {
        guard let modelActions else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            modelLibrary = try await modelActions.status()
            modelMessage = nil
        } catch {
            modelMessage = error.localizedDescription
        }
    }

    public func downloadRequiredModels() async {
        guard let modelActions, !isDownloadingModels else { return }
        if modelLibrary == nil { await refreshModels() }
        let packIDs = missingRequiredModelPacks.map(\.id)
        guard !packIDs.isEmpty else { return }

        isDownloadingModels = true
        modelMessage = nil
        defer {
            isDownloadingModels = false
            downloadingPackID = nil
        }

        do {
            for packID in packIDs {
                downloadingPackID = packID
                let progress = Task { @MainActor in
                    while !Task.isCancelled {
                        if let next = try? await modelActions.status() {
                            modelLibrary = next
                        }
                        try? await Task.sleep(for: .milliseconds(350))
                    }
                }
                do {
                    modelLibrary = try await modelActions.download(packID)
                } catch {
                    progress.cancel()
                    _ = await progress.result
                    throw error
                }
                progress.cancel()
                _ = await progress.result
            }
            modelLibrary = try await modelActions.status()
            modelMessage = "Required models are ready."
        } catch {
            modelMessage = error.localizedDescription
        }
    }
}

/// Greets by hour rather than by name — AfterRay never asks who you are.
public enum AfterRayGreeting {
    public static func text(hour: Int) -> String {
        switch hour {
        case 5 ..< 12: "Good morning."
        case 12 ..< 17: "Good afternoon."
        case 17 ..< 22: "Good evening."
        default: "Still up?"
        }
    }

    public static func now(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        text(hour: calendar.component(.hour, from: date))
    }
}

public struct AfterRayOnboardingView: View {
    @ObservedObject private var model: AfterRayOnboardingModel
    @ObservedObject private var hotKeys: RecallHotKeyStore

    private let greeting: String
    private let onFinish: () -> Void

    @State private var hasAppeared = false
    @State private var isClosing = false

    public init(
        model: AfterRayOnboardingModel,
        greeting: String = AfterRayGreeting.now(),
        onFinish: @escaping () -> Void
    ) {
        self.model = model
        hotKeys = model.hotKeys
        self.greeting = greeting
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
            Spacer(minLength: 20)
            headline
            Spacer(minLength: 22)
            stageBody
                .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            Spacer(minLength: 20)
            footer
        }
        .padding(28)
        .frame(width: 460, alignment: .leading)
        .background(backdrop)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .opacity(isClosing ? 0 : 1)
        .animation(.easeOut(duration: 0.22), value: isClosing)
        .animation(.easeOut(duration: 0.22), value: model.stage)
        .task { hasAppeared = true }
        .task(id: model.didPractice) { await advanceAfterPractice() }
    }

    // MARK: Pieces

    private var eyebrow: some View {
        HStack(spacing: 9) {
            Rectangle()
                .fill(RecallPalette.ray)
                .frame(width: 18, height: 2)
            Text(eyebrowTitle)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.1)
        }
        .foregroundStyle(RecallPalette.ray)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(greeting)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(RecallPalette.textTertiary)
            Text(headlineTitle)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(RecallPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headlineTitle: String {
        switch model.stage {
        case .hotKey:
            return "Press this to open AfterRay."
        case .cli:
            return "Let other agents use your history."
        case .models:
            return "Prepare AfterRay's local models."
        }
    }

    private var eyebrowTitle: String {
        switch model.stage {
        case .hotKey: "LOCAL ONLY / AFTERRAY"
        case .cli: "LOCAL ONLY / CLI"
        case .models: "LOCAL ONLY / MODELS"
        }
    }

    @ViewBuilder
    private var stageBody: some View {
        switch model.stage {
        case .hotKey:
            hotKeyStage
        case .cli:
            cliStage
        case .models:
            modelsStage
        }
    }

    private var hotKeyStage: some View {
        VStack(spacing: 16) {
            RecallHotKeyField(
                store: hotKeys,
                size: .hero,
                isHighlighted: model.didPractice
            )
            hotKeyHint
        }
        // Fixed so recording, praise and warnings never resize the window
        // under the reader's eyes.
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                }
                .overlay {
                    // The glow only arrives once they have actually pressed it,
                    // so the reward reads as a response and not as decoration.
                    RadialGradient(
                        colors: [RecallPalette.ray.opacity(model.didPractice ? 0.20 : 0), .clear],
                        center: .center,
                        startRadius: 4,
                        endRadius: 210
                    )
                    .animation(.easeOut(duration: 0.45), value: model.didPractice)
                }
        }
    }

    private var cliStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Install the `afterray` CLI so Claude Code, Codex, Cursor, and similar tools can search your encrypted vault. Read-only."
            )
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(RecallPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: model.cliInstalled ? "checkmark.circle.fill" : "terminal")
                        .foregroundStyle(model.cliInstalled ? .white.opacity(0.9) : RecallPalette.ray)
                    Text(model.cliInstalled ? "Installed" : "Not on PATH yet")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(RecallPalette.textPrimary)
                    Spacer(minLength: 8)
                    if model.isInstallingCli {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text(model.cliStatus)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(RecallPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let cliMessage = model.cliMessage {
                    Text(cliMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(RecallPalette.ray)
                }
                Text(model.pathExportLine)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(RecallPalette.textTertiary)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
    }

    private var modelsStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcription and search need two on-device model packs. They stay on this Mac and can be removed later in Settings.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(RecallPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isLoadingModels, model.modelLibrary == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking installed models…")
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(RecallPalette.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.requiredModelPacks.enumerated()), id: \.element.id) { index, pack in
                        if index > 0 { Divider().overlay(.white.opacity(0.08)) }
                        modelPackRow(pack)
                    }
                }
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if model.isDownloadingModels {
                ProgressView(value: model.modelDownloadProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(RecallPalette.ray)
            }

            Text(model.modelMessage ?? "The optional local assistant is about 17 GB and can be installed later in Settings.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(model.modelMessage == nil ? RecallPalette.textTertiary : RecallPalette.ray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func modelPackRow(_ pack: ModelPack) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pack.present ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(pack.present ? .white.opacity(0.9) : RecallPalette.ray)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(RecallPalette.textPrimary)
                Text(pack.present ? "Installed" : "Download · \(modelSize(pack.expectedBytes))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(RecallPalette.textTertiary)
            }
            Spacer()
            if model.downloadingPackID == pack.id {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func modelSize(_ bytes: UInt64?) -> String {
        guard let bytes else { return "size unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    @ViewBuilder
    private var hotKeyHint: some View {
        if let failure = hotKeys.failure {
            hintLabel(failure, icon: "exclamationmark.circle", tone: RecallPalette.ray)
        } else if hotKeys.isRecording {
            hintLabel(
                "Anything with ⌘, ⌥ or ⌃ · esc to cancel",
                icon: "dot.radiowaves.left.and.right",
                tone: RecallPalette.textTertiary
            )
        } else if model.didPractice {
            // The lit keys already carry the "yes"; a green tick next to them
            // would be a second, louder signal in a colour AfterRay never uses.
            hintLabel("That's it. See you soon.", icon: "checkmark.circle.fill", tone: .white.opacity(0.9))
                .transition(.opacity)
        } else if let note = hotKeys.hotKey.systemConflictNote {
            hintLabel(note, icon: "exclamationmark.triangle", tone: Color(red: 0.98, green: 0.74, blue: 0.34))
        } else {
            hintLabel("Try it — I'll wait.", icon: "hand.point.up.left", tone: RecallPalette.textTertiary)
        }
    }

    private func hintLabel(_ text: String, icon: String, tone: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .multilineTextAlignment(.leading)
                .lineLimit(2)
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 28)
        .frame(height: 32)
        .animation(.easeOut(duration: 0.18), value: text)
    }

    @ViewBuilder
    private var footer: some View {
        switch model.stage {
        case .hotKey:
            hotKeyFooter
        case .cli:
            cliFooter
        case .models:
            modelsFooter
        }
    }

    private var hotKeyFooter: some View {
        HStack(spacing: 10) {
            if hotKeys.isRecording {
                Button("Never mind", action: hotKeys.cancelRecording)
                    .buttonStyle(OnboardingQuietButtonStyle())
            } else {
                Button("Change shortcut") { hotKeys.beginRecording() }
                    .buttonStyle(OnboardingQuietButtonStyle())
                if !hotKeys.isDefault {
                    Button("Reset", action: hotKeys.restoreDefault)
                        .buttonStyle(OnboardingQuietButtonStyle())
                }
            }

            Spacer(minLength: 8)

            Button(model.didPractice ? "Continue" : "Got it", action: continueFromHotKey)
                .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: model.didPractice))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var cliFooter: some View {
        HStack(spacing: 10) {
            Button("Skip CLI") { continueFromCli() }
                .buttonStyle(OnboardingQuietButtonStyle())
            Spacer(minLength: 8)
            if !model.cliInstalled {
                Button(model.isInstallingCli ? "Installing…" : "Install CLI") {
                    Task { await model.installCli() }
                }
                .buttonStyle(OnboardingQuietButtonStyle())
                .disabled(model.isInstallingCli)
            }
            Button("Continue", action: continueFromCli)
                .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: model.cliInstalled))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var modelsFooter: some View {
        HStack(spacing: 10) {
            if !model.requiredModelsReady {
                Button("Skip for now", action: finish)
                    .buttonStyle(OnboardingQuietButtonStyle())
                    .disabled(model.isDownloadingModels)
            }
            Spacer(minLength: 8)
            if model.modelLibrary == nil, !model.isLoadingModels {
                Button("Check again") { Task { await model.refreshModels() } }
                    .buttonStyle(OnboardingQuietButtonStyle())
            }
            if model.requiredModelsReady {
                Button("Start using AfterRay", action: finish)
                    .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: true))
                    .keyboardShortcut(.defaultAction)
            } else if model.modelLibrary != nil {
                Button(model.isDownloadingModels ? "Downloading…" : "Download required models") {
                    Task { await model.downloadRequiredModels() }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: true))
                .disabled(model.isDownloadingModels)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(red: 0.055, green: 0.052, blue: 0.060)
            LinearGradient(
                colors: [RecallPalette.ray.opacity(0.16), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
        }
    }

    // MARK: Behaviour

    /// After they press the shortcut, step into the CLI lesson (or finish when
    /// the host did not wire install actions).
    private func advanceAfterPractice() async {
        guard model.stage == .hotKey, model.didPractice, !isClosing else { return }
        try? await Task.sleep(for: .milliseconds(1_150))
        guard !Task.isCancelled, !hotKeys.isRecording, model.stage == .hotKey else { return }
        continueFromHotKey()
    }

    private func continueFromHotKey() {
        guard model.stage == .hotKey, !isClosing else { return }
        if model.cliActions != nil || model.modelActions != nil {
            model.advanceFromHotKey()
        } else {
            finish()
        }
    }

    private func continueFromCli() {
        guard model.stage == .cli, !isClosing else { return }
        if model.modelActions != nil {
            model.advanceFromCli()
        } else {
            finish()
        }
    }

    private func finish() {
        guard !isClosing else { return }
        isClosing = true
        hotKeys.cancelRecording()
        onFinish()
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    let isKeyAction: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(
                RecallPalette.ray.opacity(opacity(pressed: configuration.isPressed)),
                in: Capsule()
            )
            .shadow(
                color: RecallPalette.ray.opacity(isKeyAction ? 0.38 : 0),
                radius: 12,
                y: 3
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.24), value: isKeyAction)
    }

    private func opacity(pressed: Bool) -> Double {
        if pressed { return 0.66 }
        return isKeyAction ? 0.94 : 0.74
    }
}

private struct OnboardingQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.55 : 0.78))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.white.opacity(configuration.isPressed ? 0.05 : 0.08), in: Capsule())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
