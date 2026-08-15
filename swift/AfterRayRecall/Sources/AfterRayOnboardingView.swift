import AppKit
import SwiftUI

public enum AfterRayOnboardingStage: Equatable, Sendable {
    case hotKey
    case privacy
    case cli
    case models
}

/// Exclusion hooks supplied by the app host. Onboarding is the one moment the
/// user is thinking about what AfterRay will see, so it is where the question
/// gets asked — not buried in Settings after a week of recording.
public struct AfterRayOnboardingPrivacyActions: Sendable {
    public var excludedApps: @MainActor @Sendable () -> [String]
    public var excludedDomains: @MainActor @Sendable () -> [String]
    public var protectedApps: @MainActor @Sendable () -> Set<String>
    public var refresh: @MainActor @Sendable () async -> Void
    public var addApp: @MainActor @Sendable () async -> Void
    public var removeApp: @MainActor @Sendable (_ bundleID: String) async -> Void
    public var addDomain: @MainActor @Sendable (_ typed: String) async -> Void
    public var removeDomain: @MainActor @Sendable (_ domain: String) async -> Void
    public var displayName: @MainActor @Sendable (_ bundleID: String) -> String
    public var iconPath: @MainActor @Sendable (_ bundleID: String) -> String?
    public var message: @MainActor @Sendable () -> String?

    public init(
        excludedApps: @escaping @MainActor @Sendable () -> [String],
        excludedDomains: @escaping @MainActor @Sendable () -> [String],
        protectedApps: @escaping @MainActor @Sendable () -> Set<String> = { [] },
        refresh: @escaping @MainActor @Sendable () async -> Void = {},
        addApp: @escaping @MainActor @Sendable () async -> Void,
        removeApp: @escaping @MainActor @Sendable (_ bundleID: String) async -> Void,
        addDomain: @escaping @MainActor @Sendable (_ typed: String) async -> Void,
        removeDomain: @escaping @MainActor @Sendable (_ domain: String) async -> Void,
        displayName: @escaping @MainActor @Sendable (_ bundleID: String) -> String = { $0 },
        iconPath: @escaping @MainActor @Sendable (_ bundleID: String) -> String? = { _ in nil },
        message: @escaping @MainActor @Sendable () -> String? = { nil }
    ) {
        self.excludedApps = excludedApps
        self.excludedDomains = excludedDomains
        self.protectedApps = protectedApps
        self.refresh = refresh
        self.addApp = addApp
        self.removeApp = removeApp
        self.addDomain = addDomain
        self.removeDomain = removeDomain
        self.displayName = displayName
        self.iconPath = iconPath
        self.message = message
    }
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
    public var download: @MainActor @Sendable (_ packIDs: [String]) async throws -> ModelLibrary

    public init(
        status: @escaping @MainActor @Sendable () async throws -> ModelLibrary,
        download: @escaping @MainActor @Sendable (_ packIDs: [String]) async throws -> ModelLibrary
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
    @Published public private(set) var pressedPracticeSegments: Set<String> = []
    @Published public private(set) var highlightedPracticeSegments: Set<String> = []
    @Published public private(set) var stage: AfterRayOnboardingStage = .hotKey
    @Published public private(set) var cliStatus = "Not installed yet."
    @Published public private(set) var cliInstalled = false
    @Published public private(set) var isInstallingCli = false
    @Published public var cliMessage: String?
    @Published public private(set) var modelLibrary: ModelLibrary?
    @Published public private(set) var isLoadingModels = false
    @Published public private(set) var isDownloadingModels = false
    @Published public private(set) var isStartingModelDownload = false
    @Published public private(set) var downloadingPackID: String?
    @Published public var modelMessage: String?
    @Published public private(set) var isUpdatingPrivacy = false

    public let hotKeys: RecallHotKeyStore
    public let privacyActions: AfterRayOnboardingPrivacyActions?
    public let cliActions: AfterRayOnboardingCliActions?
    public let modelActions: AfterRayOnboardingModelActions?
    private var modelDownloadMonitor: Task<Void, Never>?

    public init(
        hotKeys: RecallHotKeyStore,
        privacyActions: AfterRayOnboardingPrivacyActions? = nil,
        cliActions: AfterRayOnboardingCliActions? = nil,
        modelActions: AfterRayOnboardingModelActions? = nil
    ) {
        self.hotKeys = hotKeys
        self.privacyActions = privacyActions
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
        highlightedPracticeSegments = Set(hotKeys.hotKey.segments)
        let keySegment = hotKeys.hotKey.keyLabel
        pressedPracticeSegments.insert(keySegment)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            self?.pressedPracticeSegments.remove(keySegment)
        }
        return true
    }

    /// Mirrors the physical chord one key at a time. A released key keeps its
    /// highlight, so the lesson visibly accumulates progress instead of
    /// flashing the whole shortcut only after it succeeds.
    public func updatePracticeModifiers(_ modifiers: RecallHotKey.Modifiers) {
        guard stage == .hotKey, !hotKeys.isRecording else { return }
        let heldModifiers = hotKeys.hotKey.modifiers.intersection(modifiers)
        var heldSegments = Set(heldModifiers.glyphs)
        if pressedPracticeSegments.contains(hotKeys.hotKey.keyLabel) {
            heldSegments.insert(hotKeys.hotKey.keyLabel)
        }
        pressedPracticeSegments = heldSegments
        highlightedPracticeSegments.formUnion(heldSegments)
    }

    public func updatePracticeKey(keyCode: UInt16, isPressed: Bool) {
        guard stage == .hotKey, !hotKeys.isRecording, keyCode == hotKeys.hotKey.keyCode else { return }
        let segment = hotKeys.hotKey.keyLabel
        if isPressed {
            pressedPracticeSegments.insert(segment)
            highlightedPracticeSegments.insert(segment)
        } else {
            pressedPracticeSegments.remove(segment)
        }
    }

    public func beginHotKeyRecording() {
        didPractice = false
        pressedPracticeSegments.removeAll()
        highlightedPracticeSegments.removeAll()
        hotKeys.beginRecording()
    }

    public func advanceFromHotKey() {
        guard stage == .hotKey else { return }
        hotKeys.cancelRecording()
        pressedPracticeSegments.removeAll()
        if privacyActions != nil {
            stage = .privacy
            Task { await refreshPrivacy() }
        } else {
            enterStageAfterPrivacy()
        }
    }

    public func advanceFromPrivacy() {
        guard stage == .privacy else { return }
        enterStageAfterPrivacy()
    }

    public func goBack() {
        switch stage {
        case .hotKey:
            return
        case .privacy:
            stage = .hotKey
        case .cli:
            if privacyActions != nil {
                stage = .privacy
                Task { await refreshPrivacy() }
            } else {
                stage = .hotKey
            }
        case .models:
            stopObservingModelDownloads()
            if cliActions != nil {
                stage = .cli
                refreshCli()
            } else if privacyActions != nil {
                stage = .privacy
                Task { await refreshPrivacy() }
            } else {
                stage = .hotKey
            }
        }
    }

    public var protectedPrivacyApps: Set<String> {
        privacyActions?.protectedApps() ?? []
    }

    public var privacyMessage: String? {
        privacyActions?.message()
    }

    public func refreshPrivacy() async {
        guard let privacyActions else { return }
        isUpdatingPrivacy = true
        await privacyActions.refresh()
        isUpdatingPrivacy = false
        objectWillChange.send()
    }

    public func addPrivacyApp() async {
        await performPrivacyUpdate { await $0.addApp() }
    }

    public func removePrivacyApp(_ bundleID: String) async {
        guard !protectedPrivacyApps.contains(bundleID) else { return }
        await performPrivacyUpdate { await $0.removeApp(bundleID) }
    }

    public func addPrivacyDomain(_ typed: String) async {
        await performPrivacyUpdate { await $0.addDomain(typed) }
    }

    public func removePrivacyDomain(_ domain: String) async {
        await performPrivacyUpdate { await $0.removeDomain(domain) }
    }

    private func performPrivacyUpdate(
        _ operation: (AfterRayOnboardingPrivacyActions) async -> Void
    ) async {
        guard let privacyActions, !isUpdatingPrivacy else { return }
        isUpdatingPrivacy = true
        await operation(privacyActions)
        isUpdatingPrivacy = false
        // The action host owns the arrays. Forward its completed mutation to
        // this observable model so SwiftUI actually reads the closures again.
        objectWillChange.send()
    }

    /// A host that supplies no CLI or model hooks leaves onboarding on the
    /// privacy step rather than jumping to a stage it cannot render.
    private func enterStageAfterPrivacy() {
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

    public var modelDownloadPercent: Int? {
        modelLibrary?.download?.percent
    }

    public var modelDownloadPaused: Bool {
        modelLibrary?.download?.isPaused == true
    }

    public var scheduledModelPackIDs: Set<String> {
        guard let download = modelLibrary?.download, download.isActive else { return [] }
        return Set([download.packId] + download.queuedPackIds)
    }

    public var hasUnscheduledRequiredModelPacks: Bool {
        let scheduled = scheduledModelPackIDs
        return missingRequiredModelPacks.contains { !scheduled.contains($0.id) }
    }

    public func refreshModels() async {
        guard let modelActions else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            applyModelLibrary(try await modelActions.status())
            if modelLibrary?.download?.state != .failed {
                modelMessage = nil
            }
        } catch {
            modelMessage = error.localizedDescription
        }
    }

    public func downloadRequiredModels() async {
        guard let modelActions, !isStartingModelDownload else { return }
        if modelLibrary == nil { await refreshModels() }
        let scheduled = scheduledModelPackIDs
        let packIDs = missingRequiredModelPacks.map(\.id).filter { !scheduled.contains($0) }
        guard !packIDs.isEmpty else { return }

        isStartingModelDownload = true
        modelMessage = nil
        defer { isStartingModelDownload = false }

        do {
            applyModelLibrary(try await modelActions.download(packIDs))
        } catch {
            modelMessage = error.localizedDescription
        }
    }

    public func stopObservingModelDownloads() {
        modelDownloadMonitor?.cancel()
        modelDownloadMonitor = nil
    }

    private func applyModelLibrary(_ next: ModelLibrary) {
        modelLibrary = next
        guard let download = next.download else {
            isDownloadingModels = false
            downloadingPackID = nil
            if next.packs.filter(\.required).allSatisfy(\.present) {
                modelMessage = "Required models are ready."
            }
            return
        }

        isDownloadingModels = download.isActive
        downloadingPackID = download.isActive || download.isPaused ? download.packId : nil
        if download.state == .failed, let error = download.error, !error.isEmpty {
            modelMessage = error
        }
        if download.isActive {
            startModelDownloadMonitor()
        }
    }

    private func startModelDownloadMonitor() {
        guard modelDownloadMonitor == nil, let modelActions else { return }
        modelDownloadMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { modelDownloadMonitor = nil }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    applyModelLibrary(try await modelActions.status())
                    guard modelLibrary?.download?.isActive == true else { return }
                } catch is CancellationError {
                    return
                } catch {
                    modelMessage = error.localizedDescription
                    return
                }
            }
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
    @State private var domainDraft = ""

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
            if model.stage == .hotKey {
                Text(greeting)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(RecallPalette.textTertiary)
            }
            Text(headlineTitle)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(RecallPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headlineTitle: String {
        switch model.stage {
        case .hotKey:
            return "Open AfterRay."
        case .privacy:
            return "Choose what to skip."
        case .cli:
            return "Connect your agents."
        case .models:
            return "Set up local models."
        }
    }

    private var eyebrowTitle: String {
        switch model.stage {
        case .hotKey: "LOCAL ONLY / AFTERRAY"
        case .privacy: "LOCAL ONLY / PRIVACY"
        case .cli: "LOCAL ONLY / CLI"
        case .models: "LOCAL ONLY / MODELS"
        }
    }

    @ViewBuilder
    private var stageBody: some View {
        switch model.stage {
        case .hotKey:
            hotKeyStage
        case .privacy:
            privacyStage
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
                isHighlighted: model.didPractice,
                pressedSegments: model.pressedPracticeSegments,
                highlightedSegments: model.highlightedPracticeSegments,
                onBeginRecording: model.beginHotKeyRecording
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

    /// Apps and websites side by side. They are the same decision asked twice
    /// — "do not look here" — and separating them into consecutive steps would
    /// make the second read as an afterthought.
    @ViewBuilder
    private var privacyStage: some View {
        if let privacy = model.privacyActions {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 14) {
                    OnboardingExclusionColumn(
                        title: "Apps",
                        empty: "None",
                        entries: privacy.excludedApps().map {
                            OnboardingExclusionEntry(
                                id: $0,
                                label: privacy.displayName($0),
                                isProtected: model.protectedPrivacyApps.contains($0),
                                iconPath: privacy.iconPath($0),
                                isApplication: true
                            )
                        },
                        onRemove: { id in Task { await model.removePrivacyApp(id) } },
                        accessory: {
                            Button {
                                Task { await model.addPrivacyApp() }
                            } label: {
                                Label("Add app", systemImage: "plus")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                            }
                            .buttonStyle(OnboardingQuietButtonStyle())
                            .disabled(model.isUpdatingPrivacy)
                        }
                    )

                    OnboardingExclusionColumn(
                        title: "Websites",
                        empty: "None",
                        entries: privacy.excludedDomains().map {
                            OnboardingExclusionEntry(id: $0, label: $0)
                        },
                        onRemove: { domain in Task { await model.removePrivacyDomain(domain) } },
                        accessory: {
                            HStack(spacing: 7) {
                                Image(systemName: "globe")
                                    .font(.system(size: 12))
                                    .foregroundStyle(RecallPalette.textSecondary)
                                TextField("example.com", text: $domainDraft)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, design: .rounded))
                                    .onSubmit { submitDomain() }
                                Button("Save") { submitDomain() }
                                    .buttonStyle(OnboardingQuietButtonStyle())
                                    .disabled(
                                        model.isUpdatingPrivacy
                                            || domainDraft
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                            .isEmpty
                                    )
                            }
                        }
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 174, maxHeight: 174)

                Text(model.privacyMessage ?? "Installed password managers are skipped automatically.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(model.privacyMessage == nil ? RecallPalette.textSecondary : RecallPalette.ray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196)
        }
    }

    private func submitDomain() {
        let typed = domainDraft
        guard !model.isUpdatingPrivacy,
              !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        domainDraft = ""
        Task { await model.addPrivacyDomain(typed) }
    }

    private var privacyFooter: some View {
        HStack(spacing: 10) {
            Button("Back") { model.goBack() }
                .buttonStyle(OnboardingQuietButtonStyle())
            Spacer(minLength: 8)
            Button("Continue") { model.advanceFromPrivacy() }
                .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var cliStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Install the CLI for trusted agents. It can search your vault, change settings, and delete history."
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
            Text("Transcription and search use two local model packs. Manage them later in Settings.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(RecallPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isLoadingModels, model.modelLibrary == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking models…")
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

            if model.isDownloadingModels, let download = model.modelLibrary?.download {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(download.state == .verifying ? "Verifying \(modelPackName(download.packId))…" : "Downloading \(modelPackName(download.packId))…")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(RecallPalette.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(model.modelDownloadPercent ?? 0)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(RecallPalette.textPrimary)
                            .monospacedDigit()
                    }
                    ProgressView(value: model.modelDownloadProgress ?? 0)
                        .progressViewStyle(.linear)
                        .tint(RecallPalette.ray)
                }
            }

            Text(modelStageNote)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(model.modelMessage == nil ? RecallPalette.textTertiary : RecallPalette.ray)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelStageNote: String {
        if let message = model.modelMessage { return message }
        if model.isDownloadingModels { return "Close anytime. Downloads continue in the background." }
        if model.modelDownloadPaused { return "Paused. Resume here or manage downloads in Settings." }
        return "Optional local assistant: about 17 GB. Install it later in Settings."
    }

    private func modelPackRow(_ pack: ModelPack) -> some View {
        let download = model.modelLibrary?.download
        let isCurrent = !pack.present
            && (download?.isActive == true || download?.isPaused == true)
            && download?.packId == pack.id
        let isQueued = download?.isActive == true && download?.queuedPackIds.contains(pack.id) == true
        return HStack(spacing: 10) {
            Image(systemName: pack.present ? "checkmark.circle.fill" : isQueued ? "clock" : "arrow.down.circle")
                .foregroundStyle(pack.present ? .white.opacity(0.9) : RecallPalette.ray)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(RecallPalette.textPrimary)
                Text(modelPackSubtitle(pack, isCurrent: isCurrent, isQueued: isQueued))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(RecallPalette.textTertiary)
            }
            Spacer()
            if isCurrent, download?.isActive == true {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func modelPackSubtitle(_ pack: ModelPack, isCurrent: Bool, isQueued: Bool) -> String {
        if pack.present { return "Installed" }
        if isCurrent, model.modelDownloadPaused { return "Paused · \(model.modelDownloadPercent ?? 0)%" }
        if isCurrent, model.modelLibrary?.download?.state == .verifying { return "Verifying files" }
        if isCurrent { return "Downloading · \(model.modelDownloadPercent ?? 0)%" }
        if isQueued { return "Waiting to download" }
        return "Download · \(modelSize(pack.expectedBytes))"
    }

    private func modelPackName(_ packID: String) -> String {
        model.modelLibrary?.packs.first { $0.id == packID }?.name ?? "model"
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
        case .privacy:
            privacyFooter
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
                Button("Change shortcut") { model.beginHotKeyRecording() }
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
            Button("Back") { model.goBack() }
                .buttonStyle(OnboardingQuietButtonStyle())
            Spacer(minLength: 8)
            Button("Skip CLI") { continueFromCli() }
                .buttonStyle(OnboardingQuietButtonStyle())
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
            Button("Back") { model.goBack() }
                .buttonStyle(OnboardingQuietButtonStyle())
            Spacer(minLength: 8)
            if model.isDownloadingModels {
                if model.hasUnscheduledRequiredModelPacks {
                    Button("Download models") { Task { await model.downloadRequiredModels() } }
                        .buttonStyle(OnboardingQuietButtonStyle())
                        .disabled(model.isStartingModelDownload)
                }
                Button("Close", action: finish)
                    .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: true))
                    .keyboardShortcut(.defaultAction)
            } else if model.modelLibrary == nil, !model.isLoadingModels {
                Button("Check again") { Task { await model.refreshModels() } }
                    .buttonStyle(OnboardingQuietButtonStyle())
            } else if model.requiredModelsReady {
                Button("Start using AfterRay", action: finish)
                    .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: true))
                    .keyboardShortcut(.defaultAction)
            } else if model.modelLibrary != nil {
                Button("Skip for now", action: finish)
                    .buttonStyle(OnboardingQuietButtonStyle())
                Button(modelDownloadButtonTitle) {
                    Task { await model.downloadRequiredModels() }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle(isKeyAction: true))
                .disabled(model.isStartingModelDownload || !model.hasUnscheduledRequiredModelPacks)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var modelDownloadButtonTitle: String {
        if model.isStartingModelDownload { return "Starting…" }
        if model.modelDownloadPaused { return "Resume download" }
        return "Download models"
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
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
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct OnboardingExclusionEntry: Identifiable, Equatable {
    let id: String
    let label: String
    var isProtected = false
    var iconPath: String? = nil
    var isApplication = false
}

/// One exclusion list: an action row on top, then what has been excluded.
/// The action sits above the list because on first run the list is empty, and
/// a lone control under dead space reads as disabled.
struct OnboardingExclusionColumn<Accessory: View>: View {
    let title: String
    let empty: String
    let entries: [OnboardingExclusionEntry]
    let onRemove: (String) -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(RecallPalette.textPrimary)

            VStack(alignment: .leading, spacing: 0) {
                accessory()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                Divider().overlay(Color.white.opacity(0.08))

                if entries.isEmpty {
                    Text(empty)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(RecallPalette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(spacing: 8) {
                                    if entry.isApplication {
                                        OnboardingApplicationIcon(path: entry.iconPath)
                                    }
                                    Text(entry.label)
                                        .font(.system(size: 12, design: .rounded))
                                        .foregroundStyle(RecallPalette.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    if entry.isProtected {
                                        Image(systemName: "lock.fill")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(RecallPalette.textTertiary)
                                            .frame(width: 18, height: 18)
                                            .help("Always excluded for privacy")
                                    } else {
                                        Button {
                                            onRemove(entry.id)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(RecallPalette.textSecondary)
                                                .frame(width: 18, height: 18)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Stop excluding \(entry.label)")
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.035))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    }
            }
        }
    }
}

private struct OnboardingApplicationIcon: View {
    let path: String?

    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
                    .padding(3)
                    .foregroundStyle(RecallPalette.textSecondary)
            }
        }
        .scaledToFit()
        .frame(width: 20, height: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
