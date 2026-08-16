import AppKit
import SwiftUI

@MainActor
public protocol AfterRaySettingsModeling: ObservableObject {
    var settings: AppSettings? { get }
    var library: ModelLibrary? { get }
    var storage: AfterRayStorageSnapshot { get }
    var message: String? { get }
    var isRefreshing: Bool { get }
    var downloadingID: String? { get }
    var downloadProgress: Double? { get }
    var downloadStatus: String? { get }
    var isControllingDownload: Bool { get }
    var isUpdatingAudio: Bool { get }
    var isUpdatingStorageLimit: Bool { get }
    var isUpdatingLanguage: Bool { get }
    var recordAudio: Bool { get }
    var excludedBundleIds: [String] { get }
    var excludedDomains: [String] { get }
    var isUpdatingExclusions: Bool { get }
    var isClearingHistory: Bool { get }
    var dataDirectoryPath: String { get }
    var modelDirectoryPath: String { get }
    var logDirectoryPath: String { get }
    var logFilePath: String { get }
    var recentJobs: [ModelJob] { get }
    var llmProbe: LlmEndpointStatus? { get }
    var isProbingLlm: Bool { get }
    var isUpdatingLlm: Bool { get }
    var draftLlmBaseUrl: String { get set }
    var draftLlmModel: String { get set }
    var draftLlmApiKey: String { get set }
    var cliStatus: String { get }
    var isInstallingCli: Bool { get }
    var cliInstalled: Bool { get }
    /// False in a development build, where the updater is not running and the
    /// section has nothing to control.
    var updatesSupported: Bool { get }
    var automaticUpdates: Bool { get }
    var updateStatus: String { get }
    var developerOptionsUnlocked: Bool { get }
    var developerOptionsEnabled: Bool { get }

    func refresh() async
    func setRecordAudio(_ enabled: Bool) async
    func setStorageLimitBytes(_ bytes: UInt64) async
    func setUiLanguage(_ code: String) async
    func setSummaryLanguage(_ code: String) async
    func excludeBundle(_ bundleID: String) async
    func includeBundle(_ bundleID: String) async
    func excludeChosenApp() async
    func excludeDomain(_ input: String) async
    func includeDomain(_ domain: String) async
    func clearHistory(_ scope: HistoryScope) async
    func reveal(_ path: String)
    func download(packID: String?) async
    func pauseModelDownloads() async
    func resumeModelDownloads() async
    func cancelModelDownloads() async
    func remove(packID: String) async
    func revealLogs()
    func copyDiagnostics()
    func setLlmProvider(_ provider: LlmProvider) async
    func saveLlmConnection() async
    func probeLlm() async
    func installCli() async
    func setAutomaticUpdates(_ enabled: Bool)
    func checkForUpdates()
    func unlockDeveloperOptions()
    func setDeveloperOptionsEnabled(_ enabled: Bool)
    func replayOnboarding()
}

public struct AfterRayStorageSnapshot: Equatable, Sendable {
    public var vaultBytes: UInt64
    public var modelBytes: UInt64
    public var runtimeBytes: UInt64
    public var volumeTotal: UInt64
    public var volumeFree: UInt64

    public init(
        vaultBytes: UInt64 = 0,
        modelBytes: UInt64 = 0,
        runtimeBytes: UInt64 = 0,
        volumeTotal: UInt64 = 0,
        volumeFree: UInt64 = 0
    ) {
        self.vaultBytes = vaultBytes
        self.modelBytes = modelBytes
        self.runtimeBytes = runtimeBytes
        self.volumeTotal = volumeTotal
        self.volumeFree = volumeFree
    }

    public var afterrayBytes: UInt64 { vaultBytes + modelBytes + runtimeBytes }

    public var otherBytes: UInt64 {
        let used = volumeTotal > volumeFree ? volumeTotal - volumeFree : 0
        return used > afterrayBytes ? used - afterrayBytes : 0
    }

    public var diskShareText: String {
        guard volumeTotal > 0 else { return "Disk size is unavailable." }
        let percent = Double(afterrayBytes) / Double(volumeTotal) * 100
        let share = percent < 0.1
            ? "less than 0.1%"
            : String(format: "%.1f%%", percent)
        return "AfterRay is \(share) of this \(Self.byteCount(volumeTotal)) disk."
    }

    public var barSlices: (afterray: CGFloat, other: CGFloat, free: CGFloat) {
        let total = max(volumeTotal, afterrayBytes + volumeFree)
        guard total > 0 else { return (0, 0, 1) }
        let afterray = CGFloat(afterrayBytes) / CGFloat(total)
        let free = CGFloat(volumeFree) / CGFloat(total)
        let other = max(0, 1 - afterray - free)
        return (afterray, other, free)
    }

    public static func measure(dataDirectory: URL, modelDirectory: URL, runtimeDirectory: URL) -> Self {
        let values = try? dataDirectory.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        return Self(
            vaultBytes: itemBytes(at: dataDirectory),
            modelBytes: itemBytes(at: modelDirectory),
            runtimeBytes: itemBytes(at: runtimeDirectory),
            volumeTotal: UInt64(values?.volumeTotalCapacity ?? 0),
            volumeFree: UInt64(max(free, 0))
        )
    }

    public static func itemBytes(at url: URL) -> UInt64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var total: UInt64 = 0
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += UInt64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    public static func byteCount(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

public enum AfterRaySettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general
    case models
    case advanced
    case developer
    case diagnostics

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .models: "AI Models"
        case .advanced: "Advanced"
        case .developer: "Developer Options"
        case .diagnostics: "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .models: "cpu"
        case .advanced: "wrench.and.screwdriver"
        case .developer: "hammer"
        case .diagnostics: "stethoscope"
        }
    }

    var selectedIcon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .models: "cpu.fill"
        case .advanced: "wrench.and.screwdriver.fill"
        case .developer: "hammer.fill"
        case .diagnostics: "stethoscope"
        }
    }

    static func visiblePages(developerOptionsEnabled: Bool) -> [Self] {
        allCases.filter { $0 != .developer || developerOptionsEnabled }
    }
}

struct SettingsDeveloperUnlockSequence {
    private static let phrase = Array("loro")
    private static let maximumPause: TimeInterval = 2

    private var matchedCount = 0
    private var lastInputAt: TimeInterval?

    mutating func consume(_ input: String, at timestamp: TimeInterval) -> Bool {
        guard input.count == 1, let character = input.lowercased().first else {
            reset()
            return false
        }
        if let lastInputAt, timestamp - lastInputAt > Self.maximumPause {
            matchedCount = 0
        }
        lastInputAt = timestamp

        if character == Self.phrase[matchedCount] {
            matchedCount += 1
        } else {
            matchedCount = character == Self.phrase[0] ? 1 : 0
        }

        guard matchedCount == Self.phrase.count else { return false }
        reset()
        return true
    }

    private mutating func reset() {
        matchedCount = 0
        lastInputAt = nil
    }
}

// MARK: - Design tokens

/// One place for the panel's geometry. Nested radii stay concentric:
/// `panel 14 → card 10 → control 6`, each one step in from its parent's inset.
private enum SettingsMetrics {
    static let panelWidth: CGFloat = 820
    static let panelHeight: CGFloat = 620
    static let panelRadius: CGFloat = 14
    static let sidebarWidth: CGFloat = 204
    static let gutter: CGFloat = 24
    static let sectionGap: CGFloat = 22
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
    static let rowInset: CGFloat = 14
    static let rowMinHeight: CGFloat = 46
}

private enum SettingsPalette {
    static let accent = RecallPalette.ray
    static let panel = Color(red: 0.055, green: 0.052, blue: 0.060)
    static let sidebar = Color.black.opacity(0.24)

    static let label = Color.white.opacity(0.94)
    static let secondaryLabel = Color.white.opacity(0.60)
    static let tertiaryLabel = Color.white.opacity(0.40)

    static let cardFill = Color.white.opacity(0.042)
    static let cardStroke = Color.white.opacity(0.070)
    static let separator = Color.white.opacity(0.055)

    static let controlFill = Color.white.opacity(0.075)
    static let controlHover = Color.white.opacity(0.115)
    static let controlStroke = Color.white.opacity(0.085)

    static let positive = Color(red: 0.40, green: 0.83, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.74, blue: 0.34)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.34)
}

private extension Font {
    static let settingsPageTitle = Font.system(size: 21, weight: .semibold)
    static let settingsSectionTitle = Font.system(size: 11, weight: .semibold)
    static let settingsRowTitle = Font.system(size: 13, weight: .medium)
    static let settingsRowSubtitle = Font.system(size: 11)
    static let settingsBody = Font.system(size: 12)
    static let settingsCaption = Font.system(size: 11)
    static let settingsControl = Font.system(size: 12, weight: .medium)
    static let settingsFieldLabel = Font.system(size: 10, weight: .medium)
    static let settingsMono = Font.system(size: 11.5, design: .monospaced)
    static let settingsStat = Font.system(size: 19, weight: .semibold, design: .rounded)
    static let settingsPill = Font.system(size: 10.5, weight: .semibold)
}

private enum SettingsTone {
    case neutral
    case positive
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: SettingsPalette.secondaryLabel
        case .positive: SettingsPalette.positive
        case .warning: SettingsPalette.warning
        case .danger: SettingsPalette.danger
        }
    }
}

// MARK: - Panel

public struct AfterRaySettingsView<Model: AfterRaySettingsModeling>: View {
    @ObservedObject var model: Model
    @ObservedObject private var hotKeys = RecallHotKeyStore.shared
    let onClose: () -> Void
    @State private var page: AfterRaySettingsPage
    @State private var copied = false
    @State private var confirmingMlxRemoval = false
    @State private var domainDraft = ""
    @FocusState private var domainFieldFocused: Bool

    public init(
        model: Model,
        onClose: @escaping () -> Void,
        initialPage: AfterRaySettingsPage = .general
    ) {
        self.model = model
        self.onClose = onClose
        _page = State(initialValue: initialPage)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(SettingsPalette.separator)
                .frame(width: 1)
            pageColumn
        }
        .frame(width: SettingsMetrics.panelWidth, height: SettingsMetrics.panelHeight)
        .background(SettingsPalette.panel)
        // Settings sits inside the recall overlay, where a global scroll-wheel
        // monitor claims events for the timeline. Fencing the whole panel hands
        // every phase of the gesture — including the zero-delta `began`/`ended`
        // events AppKit needs to run momentum — straight to the page's own
        // scroll view. Without it the page tracks the finger and then stops
        // dead on release.
        .background(ScrollFenceView())
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.panelRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
        .task { await model.refresh() }
        .onChange(of: model.developerOptionsEnabled) { _, enabled in
            if !enabled, page == .developer {
                page = .advanced
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Rectangle()
                    .fill(SettingsPalette.accent)
                    .frame(width: 16, height: 2)
                Text("AFTERRAY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(SettingsPalette.accent)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            VStack(spacing: 2) {
                ForEach(AfterRaySettingsPage.visiblePages(
                    developerOptionsEnabled: model.developerOptionsEnabled
                )) { item in
                    SettingsSidebarRow(
                        page: item,
                        isSelected: page == item,
                        badge: item == .models ? missingRequiredCount : 0
                    ) {
                        page = item
                    }
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.developerOptionsEnabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: SettingsMetrics.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsPalette.sidebar)
    }

    // MARK: Page column

    @ViewBuilder
    private var pageSections: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionGap) {
            switch page {
            case .general: generalPage
            case .models: modelsPage
            case .advanced:
                advancedPage
                    .background {
                        if !model.developerOptionsUnlocked {
                            SettingsDeveloperUnlockMonitor {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    model.unlockDeveloperOptions()
                                }
                            }
                            .frame(width: 0, height: 0)
                        }
                    }
            case .developer: developerPage
            case .diagnostics: diagnosticsPage
            }
        }
        .padding(.horizontal, SettingsMetrics.gutter)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageColumn: some View {
        VStack(spacing: 0) {
            header
            ScrollView { pageSections }
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.16), value: model.message)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(page.title)
                .font(.settingsPageTitle)
                .foregroundStyle(SettingsPalette.label)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    SettingsIconButton(symbol: "arrow.clockwise", help: "Refresh") {
                        Task { await model.refresh() }
                    }
                }
                SettingsIconButton(symbol: "xmark", help: "Close settings", action: onClose)
            }
        }
        .padding(.horizontal, SettingsMetrics.gutter)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    /// Pinned under the scroll view so a message never reflows the page.
    @ViewBuilder
    private var statusBar: some View {
        if let message = model.message, !message.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsPalette.tertiaryLabel)
                    .padding(.top, 1)
                Text(message)
                    .font(.settingsCaption)
                    .foregroundStyle(SettingsPalette.secondaryLabel)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsMetrics.gutter)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.22))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(SettingsPalette.separator)
                    .frame(height: 1)
            }
            .transition(.opacity)
        }
    }

    // MARK: General

    @ViewBuilder
    private var generalPage: some View {
        // Footnote only when something is wrong with the shortcut. What a
        // global shortcut is for needs no caption.
        SettingsSection(
            title: "Opening AfterRay",
            footnote: hotKeys.failure ?? hotKeys.hotKey.systemConflictNote
        ) {
            SettingsRow(
                title: "Global shortcut",
                subtitle: hotKeys.isRecording
                    ? "Listening — press the keys you want, or esc to keep the current one."
                    : "Click the keys to record a new combination."
            ) {
                HStack(spacing: 8) {
                    if !hotKeys.isDefault, !hotKeys.isRecording {
                        Button("Reset") { hotKeys.restoreDefault() }
                            .buttonStyle(SettingsButtonStyle())
                    }
                    RecallHotKeyField(store: hotKeys, size: .compact)
                }
            }
        }

        SettingsSection(title: "Capture") {
            SettingsRow(
                title: "Record audio",
                subtitle: "System audio and microphone for transcripts. Recordings already in the vault stay."
            ) {
                HStack(spacing: 8) {
                    if model.isUpdatingAudio {
                        ProgressView().controlSize(.mini)
                    }
                    Toggle("", isOn: Binding(
                        get: { model.recordAudio },
                        set: { enabled in Task { await model.setRecordAudio(enabled) } }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(model.isUpdatingAudio)
                }
            }
        }

        SettingsSection(title: "Language") {
            SettingsRow(
                title: "Interface",
                subtitle: "Not applied yet."
            ) {
                languageMenu(
                    title: "Interface language",
                    selection: uiLanguageBinding,
                    options: languagePickerOptions(selected: model.settings?.uiLanguage)
                )
            }
            SettingsSeparator()
            SettingsRow(title: "Summaries") {
                languageMenu(
                    title: "Summary language",
                    selection: summaryLanguageBinding,
                    options: languagePickerOptions(selected: model.settings?.summaryLanguage)
                )
            }
        }

        SettingsSection(title: "Excluded apps") {
            if model.excludedBundleIds.isEmpty {
                // Empty state carries the action itself: a lone footer bar under
                // an empty row leaves a separator floating over dead space.
                SettingsRow(title: "Nothing excluded") {
                    excludeAppButtons
                }
            } else {
                ForEach(Array(model.excludedBundleIds.enumerated()), id: \.element) { index, bundleID in
                    if index > 0 { SettingsSeparator() }
                    let name = appName(for: bundleID)
                    SettingsRow(
                        title: name,
                        subtitle: name == bundleID ? nil : bundleID,
                        iconBundleID: bundleID
                    ) {
                        if model.settings?.protectedBundleIds.contains(bundleID) == true {
                            Label("Always excluded", systemImage: "lock.fill")
                                .font(.settingsRowSubtitle)
                                .foregroundStyle(SettingsPalette.secondaryLabel)
                        } else {
                            Button("Include") {
                                Task { await model.includeBundle(bundleID) }
                            }
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(model.isUpdatingExclusions)
                        }
                    }
                }
                SettingsSeparator()
                SettingsFooterBar { excludeAppButtons }
            }
        }

        SettingsSection(title: "Excluded websites") {
            if model.excludedDomains.isEmpty {
                SettingsRow(title: "Nothing excluded") {
                    addDomainField
                }
            } else {
                ForEach(Array(model.excludedDomains.enumerated()), id: \.element) { index, domain in
                    if index > 0 { SettingsSeparator() }
                    SettingsRow(title: domain, subtitle: nil) {
                        Button("Include") {
                            Task { await model.includeDomain(domain) }
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(model.isUpdatingExclusions)
                    }
                }
                SettingsSeparator()
                SettingsFooterBar { addDomainField }
            }
        }

        storageSection

        SettingsSection(
            title: "Delete history",
            footnote: "Deleted moments are removed from this Mac and cannot be recovered."
        ) {
            SettingsRow(title: "Remove captured moments") {
                HStack(spacing: 7) {
                    Button("Last hour") { Task { await model.clearHistory(.lastHour) } }
                        .buttonStyle(SettingsButtonStyle())
                    Button("Today") { Task { await model.clearHistory(.today) } }
                        .buttonStyle(SettingsButtonStyle())
                    Button("Everything") { Task { await model.clearHistory(.all) } }
                        .buttonStyle(SettingsButtonStyle(kind: .destructive))
                }
                .disabled(model.isClearingHistory)
            }
        }
    }

    /// A picker rather than a "use the frontmost app" shortcut: while Settings
    /// is open the frontmost app is AfterRay itself, so the shortcut could only
    /// ever name the wrong app.
    private var excludeAppButtons: some View {
        Button("Choose App…") {
            Task { await model.excludeChosenApp() }
        }
        .buttonStyle(SettingsButtonStyle())
        .disabled(model.isUpdatingExclusions)
    }

    /// The same boxed field the rest of Settings uses. Unstyled it read as a
    /// disabled caption next to a greyed-out button — an input nobody could
    /// tell was an input, which is the same as having no way to add a site.
    private var addDomainField: some View {
        HStack(spacing: 7) {
            TextField("example.com", text: $domainDraft)
                .settingsFieldStyle()
                .frame(width: 150)
                .focused($domainFieldFocused)
                .onSubmit { submitDomain() }
            Button("Exclude", action: submitDomain)
                .buttonStyle(SettingsButtonStyle())
                // Without this the empty-state row's long subtitle wins the
                // squeeze and the button reads "Ex…".
                .fixedSize()
                .disabled(
                    model.isUpdatingExclusions
                        || domainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
    }

    /// The first entry moves the field out of the empty-state row and into the
    /// section's footer bar, which is a different view — so focus is asked for
    /// again, or excluding a second site means reaching for the mouse.
    private func submitDomain() {
        let typed = domainDraft
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        domainDraft = ""
        Task { @MainActor in
            await model.excludeDomain(typed)
            domainFieldFocused = true
        }
    }

    private var storageSection: some View {
        SettingsSection(title: "Storage", contentPadding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    storageStat("AfterRay uses", AfterRayStorageSnapshot.byteCount(model.storage.afterrayBytes))
                    Spacer(minLength: 12)
                    storageStat(
                        "Free on disk",
                        AfterRayStorageSnapshot.byteCount(model.storage.volumeFree),
                        align: .trailing
                    )
                }
                StorageCompositionBar(segments: storageSegments)
                VStack(spacing: 7) {
                    ForEach(storageSegments) { segment in
                        storageLegend(segment)
                    }
                }
                Text(model.storage.diskShareText)
                    .font(.settingsCaption)
                    .foregroundStyle(SettingsPalette.tertiaryLabel)
                Rectangle()
                    .fill(SettingsPalette.separator)
                    .frame(height: 1)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Memory limit")
                            .font(.settingsRowTitle)
                            .foregroundStyle(SettingsPalette.label)
                        Text("Oldest unstarred moments are removed first. Favorites and a small metadata overhead may exceed this limit.")
                            .font(.settingsRowSubtitle)
                            .foregroundStyle(SettingsPalette.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    if model.isUpdatingStorageLimit {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Picker("Memory limit", selection: storageLimitBinding) {
                        ForEach(storageLimitOptions, id: \.self) { bytes in
                            Text(AfterRayStorageSnapshot.byteCount(bytes)).tag(bytes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .disabled(model.isUpdatingStorageLimit)
                }
            }
        }
    }

    private var storageLimitOptions: [UInt64] {
        let presets: [UInt64] = [
            10_000_000_000,
            25_000_000_000,
            50_000_000_000,
            100_000_000_000,
            250_000_000_000,
            500_000_000_000,
            1_000_000_000_000,
        ]
        let current = model.settings?.storageLimitBytes ?? AppSettings.defaultStorageLimitBytes
        return Array(Set(presets + [current])).sorted()
    }

    private var storageLimitBinding: Binding<UInt64> {
        Binding(
            get: { model.settings?.storageLimitBytes ?? AppSettings.defaultStorageLimitBytes },
            set: { bytes in Task { await model.setStorageLimitBytes(bytes) } }
        )
    }

    private var uiLanguageBinding: Binding<String> {
        Binding(
            get: { model.settings?.uiLanguage ?? AppSettings.defaultLanguage },
            set: { code in Task { await model.setUiLanguage(code) } }
        )
    }

    private var summaryLanguageBinding: Binding<String> {
        Binding(
            get: { model.settings?.summaryLanguage ?? AppSettings.defaultLanguage },
            set: { code in Task { await model.setSummaryLanguage(code) } }
        )
    }

    private func languagePickerOptions(selected: String?) -> [LanguageOption] {
        model.settings?.languagePickerOptions(selected: selected ?? AppSettings.defaultLanguage)
            ?? [LanguageOption.followSystem]
    }

    private func languageMenu(
        title: String,
        selection: Binding<String>,
        options: [LanguageOption]
    ) -> some View {
        HStack(spacing: 8) {
            if model.isUpdatingLanguage {
                ProgressView().controlSize(.mini)
            }
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.menuTitle)
                        .tag(option.code)
                        .accessibilityLabel(option.englishName)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 132, maxWidth: 176)
            .disabled(model.isUpdatingLanguage)
            .accessibilityLabel(title)
        }
    }

    /// AfterRay's own footprint, not the whole volume: at ~0.2% of a 1 TB disk
    /// a whole-disk bar renders as an invisible hairline.
    private var storageSegments: [StorageSegment] {
        [
            StorageSegment(
                id: "memories",
                title: "Memories",
                bytes: model.storage.vaultBytes,
                color: SettingsPalette.accent
            ),
            StorageSegment(
                id: "models",
                title: "Models",
                bytes: model.storage.modelBytes,
                color: SettingsPalette.accent.opacity(0.58)
            ),
            StorageSegment(
                id: "runtime",
                title: "Runtime",
                bytes: model.storage.runtimeBytes,
                color: SettingsPalette.accent.opacity(0.32)
            ),
        ]
        .filter { $0.bytes > 0 }
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return AfterRayPrivacyCatalog.protectedName(for: bundleID) ?? bundleID
    }

    // MARK: Models

    @ViewBuilder
    private var modelsPage: some View {
        SettingsSection(
            title: "Assistant source",
            footnote: providerFootnote,
            contentPadding: 14
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Assistant source", selection: llmProviderBinding) {
                    ForEach(LlmProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isUpdatingLlm)
                llmProviderPanel
            }
        }

        SettingsSection(title: "Model packs") {
            SettingsRow(title: "On-device OCR", subtitle: "Apple Vision") {
                SettingsPill("Built in", tone: .neutral)
            }
            if let library = model.library {
                ForEach(library.packs.filter {
                    $0.id != qwen35MlxPackID && $0.id != qwen35Mlx9BPackID
                }) { pack in
                    SettingsSeparator()
                    modelPackRow(pack)
                }
            } else if model.message == nil {
                SettingsSeparator()
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading the model folder…")
                        .font(.settingsCaption)
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                    Spacer()
                }
                .padding(.horizontal, SettingsMetrics.rowInset)
                .padding(.vertical, 14)
            }
            SettingsSeparator()
            packsFooter
        }

        if !model.recentJobs.isEmpty {
            SettingsSection(title: "Recent inference") {
                ForEach(Array(model.recentJobs.enumerated()), id: \.element.id) { index, job in
                    if index > 0 { SettingsSeparator() }
                    SettingsRow(title: jobTitle(job), subtitle: jobSubtitle(job)) {
                        SettingsPill(jobStateLabel(job.state), tone: jobTone(job.state))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var packsFooter: some View {
        if model.downloadingID != nil, let status = model.downloadStatus {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if model.library?.download?.isPaused == true {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(SettingsPalette.secondaryLabel)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(status)
                        .font(.settingsCaption)
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let percent = percentLabel(model.downloadProgress) {
                        Text(percent)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(SettingsPalette.label)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: model.downloadProgress ?? 0)
                    .progressViewStyle(.linear)
                    .tint(SettingsPalette.accent)
                HStack(spacing: 10) {
                    Text(model.library?.download?.isPaused == true
                        ? "Partial files are kept for resume."
                        : "Pause keeps partial files; cancel removes them.")
                        .font(.settingsCaption)
                        .foregroundStyle(SettingsPalette.tertiaryLabel)
                    Spacer(minLength: 8)
                    if model.library?.download?.isPaused == true {
                        Button("Resume") {
                            Task { await model.resumeModelDownloads() }
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .prominent))
                    } else {
                        Button("Pause") {
                            Task { await model.pauseModelDownloads() }
                        }
                        .buttonStyle(SettingsButtonStyle())
                    }
                    Button("Cancel") {
                        Task { await model.cancelModelDownloads() }
                    }
                    .buttonStyle(SettingsButtonStyle())
                }
                .disabled(model.isControllingDownload)
            }
            .padding(.horizontal, SettingsMetrics.rowInset)
            .padding(.vertical, 12)
        } else {
            SettingsFooterBar {
                Button(missingPackCount > 0 ? "Download Missing (\(missingPackCount))" : "All Packs Installed") {
                    Task { await model.download(packID: nil) }
                }
                .buttonStyle(SettingsButtonStyle(kind: .prominent))
                .disabled(model.downloadingID != nil || missingPackCount == 0)
            }
        }
    }

    private var missingRequiredCount: Int {
        model.library?.packs.filter { $0.required && !$0.present }.count ?? 0
    }

    /// Every absent pack, optional ones included: the daemon downloads those
    /// too, so gating the button on required-only packs left it dead.
    private var missingPackCount: Int {
        model.library?.packs.filter { !$0.present }.count ?? 0
    }

    /// Only where the choice carries a consequence the controls do not show.
    /// The local pack's own picker already names both models.
    private var providerFootnote: String? {
        switch model.settings?.llmProvider ?? .mlxLocal {
        case .mlxLocal:
            nil
        case .ollama:
            "Nothing leaves this Mac."
        case .openaiCompatible:
            "Any server that speaks OpenAI chat completions."
        }
    }

    private var llmProviderBinding: Binding<LlmProvider> {
        Binding(
            get: { model.settings?.llmProvider ?? .mlxLocal },
            set: { provider in
                Task { await model.setLlmProvider(provider) }
            }
        )
    }

    @ViewBuilder
    private var llmProviderPanel: some View {
        switch model.settings?.llmProvider ?? .mlxLocal {
        case .mlxLocal:
            mlxLocalPanel
        case .ollama:
            ollamaPanel
        case .openaiCompatible:
            openaiPanel
        }
    }

    private let qwen35MlxPackID = "llm_qwen35_4b_mlx4"
    private let qwen35Mlx9BPackID = "llm_qwen35_9b_mlx4"

    @ViewBuilder
    private var mlxLocalPanel: some View {
        let selectedPackID = selectedMlxPackID
        if let pack = model.library?.packs.first(where: { $0.id == selectedPackID }) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsField(label: "Model") {
                    SettingsMenuPicker(
                        options: [
                            .init(id: qwen35MlxPackID, title: "Recommended · Qwen3.5 4B"),
                            .init(id: qwen35Mlx9BPackID, title: "Higher quality · Qwen3.5 9B"),
                        ],
                        selection: mlxModelBinding,
                        disabled: model.isUpdatingLlm
                    )
                }
                HStack(spacing: 8) {
                    SettingsPill(mlxStateLabel(pack.state), tone: mlxStateTone(pack.state))
                    Text("mlx-community · Apache 2.0")
                        .font(.settingsCaption)
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                    Spacer(minLength: 8)
                    if pack.state == .downloading || pack.state == .verifying {
                        ProgressView().controlSize(.mini)
                    }
                }

                Text(mlxDescription(for: pack.id))
                    .font(.settingsCaption)
                    .foregroundStyle(SettingsPalette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = pack.error, !error.isEmpty {
                    Text(error)
                        .font(.settingsCaption)
                        .foregroundStyle(SettingsPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let download = model.library?.download,
                   download.packId == pack.id,
                   download.state == .downloading || download.state == .verifying
                {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(download.state == .verifying ? "Verifying files…" : "Downloading model…")
                                .font(.settingsCaption)
                                .foregroundStyle(SettingsPalette.secondaryLabel)
                            Spacer()
                            if let percent = download.percent {
                                Text("\(percent)%")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                            }
                        }
                        ProgressView(value: download.fraction ?? 0)
                            .progressViewStyle(.linear)
                            .tint(SettingsPalette.accent)
                    }
                } else if model.library?.download?.isActive == true,
                          model.library?.download?.queuedPackIds.contains(pack.id) == true
                {
                    Label("Waiting to download", systemImage: "clock")
                        .font(.settingsCaption)
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                }

                HStack(spacing: 10) {
                    switch pack.state {
                    case .notDownloaded, .failed:
                        Button(pack.state == .failed ? "Retry Download" : "Download \(mlxDownloadLabel(for: pack.id))") {
                            Task { await model.download(packID: pack.id) }
                        }
                        .buttonStyle(SettingsButtonStyle(kind: .prominent))
                        .disabled(model.downloadingID != nil)
                    case .ready, .inUse:
                        Button("Show Files") { model.reveal(pack.path) }
                            .buttonStyle(SettingsButtonStyle())
                        Button("Remove…") { confirmingMlxRemoval = true }
                            .buttonStyle(SettingsButtonStyle())
                            .disabled(pack.state == .inUse || model.downloadingID != nil)
                    case .downloading, .verifying, .paused, .incompatible:
                        EmptyView()
                    }
                    Spacer()
                }
            }
            .confirmationDialog(
                "Remove \(pack.name) from this Mac?",
                isPresented: $confirmingMlxRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Download", role: .destructive) {
                    Task { await model.remove(packID: pack.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("AfterRay can download the verified snapshot again later.")
            }
        } else {
            Text("The managed MLX model is unavailable in this daemon build.")
                .font(.settingsCaption)
                .foregroundStyle(SettingsPalette.secondaryLabel)
        }
    }

    private var selectedMlxPackID: String {
        let candidate = model.settings?.llmModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [qwen35MlxPackID, qwen35Mlx9BPackID].contains(candidate) ? candidate : qwen35MlxPackID
    }

    private var mlxModelBinding: Binding<String> {
        Binding(
            get: { selectedMlxPackID },
            set: { next in
                model.draftLlmModel = next
                Task { await model.saveLlmConnection() }
            }
        )
    }

    private func mlxDownloadLabel(for packID: String) -> String {
        packID == qwen35Mlx9BPackID ? "~5.97 GB" : "~3.06 GB"
    }

    /// Only the memory caveat. The picker names the model, the pill line gives
    /// the license, and the download button carries the size — repeating all
    /// three underneath them is a paragraph that says nothing new.
    private func mlxDescription(for packID: String) -> String {
        packID == qwen35Mlx9BPackID
            ? "Check your free unified memory before downloading."
            : "Experimental on an 8 GB Mac."
    }

    private func mlxStateLabel(_ state: ModelPackState) -> String {
        switch state {
        case .notDownloaded: "Not downloaded"
        case .downloading: "Downloading"
        case .verifying: "Verifying"
        case .paused: "Paused"
        case .ready: "Ready"
        case .inUse: "Loaded"
        case .failed: "Failed"
        case .incompatible: "Incompatible"
        }
    }

    private func mlxStateTone(_ state: ModelPackState) -> SettingsTone {
        switch state {
        case .ready, .inUse: .positive
        case .downloading, .verifying, .paused: .neutral
        case .notDownloaded: .warning
        case .failed, .incompatible: .danger
        }
    }

    private var ollamaPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.llmProbe?.reachable == true
                        ? SettingsPalette.positive
                        : SettingsPalette.tertiaryLabel)
                    .frame(width: 6, height: 6)
                Text(ollamaStatusText)
                    .font(.settingsCaption)
                    .foregroundStyle(SettingsPalette.secondaryLabel)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if model.isProbingLlm {
                    ProgressView().controlSize(.mini)
                }
                Button("Check Again") {
                    Task { await model.probeLlm() }
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(model.isProbingLlm)
            }

            SettingsField(label: "Model") {
                if let models = model.llmProbe?.models, !models.isEmpty {
                    SettingsMenuPicker(
                        options: ollamaPickerModels(models).map {
                            .init(id: $0.id, title: $0.name)
                        },
                        selection: ollamaModelBinding,
                        disabled: model.isUpdatingLlm
                    )
                } else {
                    TextField("qwen3.6:latest", text: $model.draftLlmModel)
                        .settingsFieldStyle()
                        .onSubmit { Task { await model.saveLlmConnection() } }
                }
            }

            SettingsField(label: "Server URL") {
                TextField(
                    model.llmProbe?.defaultBaseUrl ?? "http://127.0.0.1:11434",
                    text: $model.draftLlmBaseUrl
                )
                .settingsFieldStyle()
                .onSubmit { Task { await model.saveLlmConnection() } }
            }

            if ollamaHasUnsavedChanges {
                HStack {
                    Spacer()
                    Button("Save Connection") {
                        Task { await model.saveLlmConnection() }
                    }
                    .buttonStyle(SettingsButtonStyle(kind: .prominent))
                    .disabled(model.isUpdatingLlm)
                }
            }
        }
    }

    private var ollamaHasUnsavedChanges: Bool {
        model.draftLlmBaseUrl != (model.settings?.llmBaseUrl ?? "")
            || model.draftLlmModel != (model.settings?.llmModel ?? "")
            || (model.llmProbe?.models.isEmpty ?? true)
    }

    private var openaiPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsField(label: "Server URL") {
                TextField("https://dashscope.aliyuncs.com/compatible-mode/v1", text: $model.draftLlmBaseUrl)
                    .settingsFieldStyle()
            }
            SettingsField(label: "Model") {
                TextField("qwen3.7-max", text: $model.draftLlmModel)
                    .settingsFieldStyle()
            }
            SettingsField(label: "API key") {
                SecureField(
                    model.settings?.llmApiKeySet == true
                        ? "Saved — leave blank to keep it"
                        : "Optional",
                    text: $model.draftLlmApiKey
                )
                .settingsFieldStyle()
            }
            HStack(spacing: 10) {
                if model.isProbingLlm {
                    ProgressView().controlSize(.mini)
                } else if let probe = model.llmProbe {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(probe.reachable ? SettingsPalette.positive : SettingsPalette.danger)
                            .frame(width: 6, height: 6)
                        Text(probe.reachable ? "Endpoint reachable" : (probe.error ?? "Not reachable"))
                            .font(.settingsCaption)
                            .foregroundStyle(SettingsPalette.secondaryLabel)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button("Save Connection") {
                    Task { await model.saveLlmConnection() }
                }
                .buttonStyle(SettingsButtonStyle(kind: .prominent))
                .disabled(model.isUpdatingLlm)
            }
        }
    }

    private var ollamaStatusText: String {
        if model.isProbingLlm { return "Looking for Ollama…" }
        guard let probe = model.llmProbe else { return "Ollama has not been probed yet." }
        if probe.reachable {
            let count = probe.models.count
            return count == 1 ? "Ollama is running · 1 chat model" : "Ollama is running · \(count) chat models"
        }
        return probe.error ?? "Ollama is not reachable on this Mac."
    }

    private var ollamaModelBinding: Binding<String> {
        Binding(
            get: { model.draftLlmModel },
            set: { next in
                model.draftLlmModel = next
                Task { await model.saveLlmConnection() }
            }
        )
    }

    private func ollamaPickerModels(_ models: [LlmRemoteModel]) -> [LlmRemoteModel] {
        if models.contains(where: { $0.id == model.draftLlmModel }) || model.draftLlmModel.isEmpty {
            return models
        }
        return [LlmRemoteModel(id: model.draftLlmModel)] + models
    }

    private func modelPackRow(_ pack: ModelPack) -> some View {
        let downloading = model.library?.download?.isActive == true
            && (model.downloadingID == pack.id || model.library?.download?.packId == pack.id)
        let paused = model.library?.download?.isPaused == true
            && model.library?.download?.packId == pack.id
        let queued = model.library?.download?.isActive == true
            && model.library?.download?.queuedPackIds.contains(pack.id) == true
        return SettingsRow(
            title: pack.name,
            subtitle: packSubtitle(pack),
            subtitleLineLimit: 2
        ) {
            HStack(spacing: 8) {
                if downloading {
                    ProgressView().controlSize(.mini)
                    Text(percentLabel(model.downloadProgress) ?? "Downloading")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                        .monospacedDigit()
                } else if paused {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                    Text(percentLabel(model.downloadProgress).map { "Paused · \($0)" } ?? "Paused")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                        .monospacedDigit()
                } else if queued {
                    Image(systemName: "clock")
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                    Text("Waiting")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                } else {
                    SettingsPill(packStatus(pack), tone: packTone(pack))
                    if pack.present {
                        Button("Show") { model.reveal(pack.path) }
                            .buttonStyle(SettingsButtonStyle())
                    } else {
                        Button("Download") {
                            Task { await model.download(packID: pack.id) }
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .disabled(model.downloadingID != nil)
                    }
                }
            }
        }
    }

    private func packSubtitle(_ pack: ModelPack) -> String {
        [
            capabilityLabel(pack.capability),
            pack.present ? AfterRayStorageSnapshot.byteCount(pack.bytes) : nil,
            pack.note,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private func packStatus(_ pack: ModelPack) -> String {
        if pack.state == .failed { return "Failed" }
        if pack.state == .incompatible { return "Incompatible" }
        if pack.state == .paused { return "Paused" }
        if pack.state == .verifying { return "Verifying" }
        if pack.state == .inUse { return "Loaded" }
        if pack.present { return "Ready" }
        if pack.bytes > 0 { return "Incomplete" }
        return pack.required ? "Needed" : "Optional"
    }

    private func packTone(_ pack: ModelPack) -> SettingsTone {
        if pack.state == .failed || pack.state == .incompatible { return .danger }
        if pack.present { return .positive }
        if pack.bytes > 0 { return .warning }
        return pack.required ? .warning : .neutral
    }

    private func jobTitle(_ job: ModelJob) -> String {
        switch job.capability {
        case "asr": "Qwen3 ASR"
        case "ocr": "OCR"
        case "embedding": "Embeddings"
        case "llm": "Assistant"
        default: job.capability
        }
    }

    private func jobSubtitle(_ job: ModelJob) -> String {
        if let error = job.lastError, !error.isEmpty {
            return error
        }
        return job.adapter
    }

    private func jobStateLabel(_ state: String) -> String {
        switch state {
        case "done": "OK"
        case "failed": "Failed"
        case "running": "Running"
        case "pending": "Queued"
        case "cancelled": "Cancelled"
        default: state
        }
    }

    private func jobTone(_ state: String) -> SettingsTone {
        switch state {
        case "done": .positive
        case "failed": .danger
        default: .neutral
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedPage: some View {
        if model.developerOptionsUnlocked {
            SettingsSection(title: "Developer Options") {
                SettingsRow(title: "Show developer settings") {
                    Toggle("", isOn: Binding(
                        get: { model.developerOptionsEnabled },
                        set: { model.setDeveloperOptionsEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            .transition(.opacity)
        }

        if model.updatesSupported {
            SettingsSection(
                title: "Updates",
                footnote: "Updates install the next time you quit, so a recording is never interrupted."
            ) {
                SettingsRow(
                    title: "Check automatically",
                    subtitle: model.updateStatus,
                    subtitleLineLimit: 2
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.automaticUpdates },
                        set: { model.setAutomaticUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsSeparator()
                SettingsFooterBar {
                    Button("Check Now") { model.checkForUpdates() }
                        .buttonStyle(SettingsButtonStyle(kind: .standard))
                }
            }
        }

        SettingsSection(
            title: "CLI for agents",
            footnote: "Installs `afterray` to ~/.local/bin so coding agents can search your history. V0 installs the full developer CLI, which can also change settings and delete history."
        ) {
            SettingsRow(
                title: model.cliInstalled ? "afterray is installed" : "afterray CLI",
                subtitle: model.cliStatus,
                subtitleLineLimit: 3
            ) {
                SettingsPill(
                    model.cliInstalled ? "Ready" : "Missing",
                    tone: model.cliInstalled ? .positive : .warning
                )
            }
            SettingsSeparator()
            SettingsFooterBar {
                Button(model.cliInstalled ? "Reinstall CLI" : "Install CLI") {
                    Task { await model.installCli() }
                }
                .buttonStyle(SettingsButtonStyle(kind: model.cliInstalled ? .standard : .prominent))
                .disabled(model.isInstallingCli)
                if model.isInstallingCli {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }

        // The title states the interval and the pill states that it cannot be
        // changed. A footnote and a subtitle saying both again is three of one.
        SettingsSection(title: "Capture cadence") {
            SettingsRow(title: captureCadenceTitle) {
                SettingsPill("Fixed", tone: .neutral)
            }
        }

        SettingsSection(
            title: "Locations",
            footnote: "Moving the vault to another disk is not available yet."
        ) {
            SettingsPathRow(title: "Vault", path: model.dataDirectoryPath) {
                model.reveal(model.dataDirectoryPath)
            }
            SettingsSeparator()
            SettingsPathRow(title: "Models", path: model.modelDirectoryPath) {
                model.reveal(model.modelDirectoryPath)
            }
        }
    }

    private var captureCadenceTitle: String {
        let seconds = model.settings?.captureIntervalSeconds ?? 10
        return "One still every \(seconds) second\(seconds == 1 ? "" : "s")"
    }

    // MARK: Developer

    private var developerPage: some View {
        SettingsSection(
            title: "Onboarding",
            footnote: "Reopens the first-run flow without changing downloads or other settings."
        ) {
            SettingsRow(title: "Replay onboarding") {
                Button("Replay") { model.replayOnboarding() }
                    .buttonStyle(SettingsButtonStyle(kind: .prominent))
            }
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnosticsPage: some View {
        SettingsSection(
            title: "Logs",
            footnote: "Attach this file when reporting a bug."
        ) {
            SettingsPathRow(title: "Log file", path: model.logFilePath, action: nil)
            SettingsSeparator()
            SettingsFooterBar {
                Button("Reveal Log Folder") { model.revealLogs() }
                    .buttonStyle(SettingsButtonStyle())
                Button(copied ? "Copied" : "Copy Report") {
                    model.copyDiagnostics()
                    copied = true
                }
                .buttonStyle(SettingsButtonStyle(kind: copied ? .prominent : .standard))
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: Shared pieces

    private func percentLabel(_ progress: Double?) -> String? {
        guard let progress else { return nil }
        return "\(Int((progress * 100).rounded(.down)))%"
    }

    private func storageStat(
        _ title: String,
        _ value: String,
        align: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: align, spacing: 2) {
            Text(title)
                .font(.settingsCaption)
                .foregroundStyle(SettingsPalette.tertiaryLabel)
            Text(value)
                .font(.settingsStat)
                .foregroundStyle(SettingsPalette.label)
                .monospacedDigit()
        }
    }

    private func storageLegend(_ segment: StorageSegment) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(segment.color)
                .frame(width: 8, height: 8)
            Text(segment.title)
                .foregroundStyle(SettingsPalette.secondaryLabel)
            Spacer(minLength: 12)
            Text(AfterRayStorageSnapshot.byteCount(segment.bytes))
                .foregroundStyle(SettingsPalette.secondaryLabel)
                .monospacedDigit()
        }
        .font(.settingsCaption)
    }

    private func capabilityLabel(_ capability: String) -> String {
        switch capability {
        case "asr": "Transcription"
        case "embedding": "Search embeddings"
        case "llm": "Assistant"
        default: capability.capitalized
        }
    }
}

// MARK: - Building blocks

/// Header + one card. The card wraps `content` in a single container, so a
/// section with several children stays one surface instead of one card each.
private struct SettingsSection<Content: View>: View {
    var title: String?
    var footnote: String?
    var contentPadding: CGFloat = 0
    @ViewBuilder var content: Content

    init(
        title: String? = nil,
        footnote: String? = nil,
        contentPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footnote = footnote
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.settingsSectionTitle)
                    .tracking(0.7)
                    .foregroundStyle(SettingsPalette.tertiaryLabel)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.cardFill, in: cardShape)
            .overlay { cardShape.strokeBorder(SettingsPalette.cardStroke, lineWidth: 1) }
            if let footnote {
                Text(footnote)
                    .font(.settingsCaption)
                    .foregroundStyle(SettingsPalette.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var subtitleLineLimit: Int?
    /// Rows that name an app carry its icon: a list of bundle ids is a list of
    /// strings to read, while a list of icons is one to recognise.
    var iconBundleID: String?
    var trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        subtitleLineLimit: Int? = nil,
        iconBundleID: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.iconBundleID = iconBundleID
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let iconBundleID {
                AppIconView(bundleIdentifier: iconBundleID, size: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.settingsRowTitle)
                    .foregroundStyle(SettingsPalette.label)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.settingsRowSubtitle)
                        .foregroundStyle(SettingsPalette.secondaryLabel)
                        .lineLimit(subtitleLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 11)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }
}

private struct SettingsPathRow: View {
    let title: String
    let path: String
    var action: (() -> Void)?

    init(title: String, path: String, action: (() -> Void)?) {
        self.title = title
        self.path = path
        self.action = action
    }

    init(title: String, path: String, action: @escaping () -> Void) {
        self.init(title: title, path: path, action: .some(action))
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.settingsRowTitle)
                    .foregroundStyle(SettingsPalette.label)
                Text(path)
                    .font(.settingsMono)
                    .foregroundStyle(SettingsPalette.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
            }
            Spacer(minLength: 16)
            if let action {
                Button("Show") { action() }
                    .buttonStyle(SettingsButtonStyle())
            }
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 11)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }
}

/// Trailing action strip at the bottom of a card.
private struct SettingsFooterBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 10)
    }
}

private struct SettingsSeparator: View {
    var body: some View {
        Rectangle()
            .fill(SettingsPalette.separator)
            .frame(height: 1)
            .padding(.leading, SettingsMetrics.rowInset)
    }
}

/// Label above a control. Field labels beat placeholder-only inputs: the
/// placeholder disappears exactly when the user needs to know what they typed.
private struct SettingsField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.settingsFieldLabel)
                .tracking(0.6)
                .foregroundStyle(SettingsPalette.tertiaryLabel)
            content
        }
    }
}

/// A popup that wears the same box as the text fields around it.
///
/// SwiftUI's stock menu picker draws its own chrome and, given a wide field,
/// parks itself in the middle of it — so the model row sat centred above a
/// full-width server field and read as a different kind of control.
private struct SettingsMenuPicker: View {
    struct Option: Identifiable {
        let id: String
        let title: String
    }

    let options: [Option]
    @Binding var selection: String
    var disabled = false

    @State private var isHovering = false

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(selectedTitle)
                    .font(.settingsBody)
                    .foregroundStyle(SettingsPalette.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SettingsPalette.tertiaryLabel)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovering ? SettingsPalette.controlHover : SettingsPalette.controlFill,
            in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                .strokeBorder(SettingsPalette.controlStroke, lineWidth: 1)
        }
        .opacity(disabled ? 0.42 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = !disabled && $0 }
        .disabled(disabled)
    }

    private var selectedTitle: String {
        options.first { $0.id == selection }?.title ?? selection
    }
}

private extension View {
    func settingsFieldStyle() -> some View {
        textFieldStyle(.plain)
            .font(.settingsBody)
            .foregroundStyle(SettingsPalette.label)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                SettingsPalette.controlFill,
                in: RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
                    .strokeBorder(SettingsPalette.controlStroke, lineWidth: 1)
            }
    }
}

private struct SettingsPill: View {
    let text: String
    let tone: SettingsTone

    init(_ text: String, tone: SettingsTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.settingsPill)
            .foregroundStyle(tone == .neutral ? SettingsPalette.secondaryLabel : tone.color)
            .padding(.horizontal, 8)
            .frame(height: 19)
            .background(
                tone == .neutral ? Color.white.opacity(0.07) : tone.color.opacity(0.15),
                in: Capsule()
            )
    }
}

private struct StorageSegment: Identifiable {
    let id: String
    let title: String
    let bytes: UInt64
    let color: Color
}

private struct StorageCompositionBar: View {
    let segments: [StorageSegment]

    private var total: UInt64 { segments.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                if total == 0 {
                    Rectangle().fill(Color.white.opacity(0.06))
                } else {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: width(for: segment, in: geometry.size.width))
                    }
                }
            }
        }
        .frame(height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityLabel(accessibilityText)
    }

    private func width(for segment: StorageSegment, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let gaps = CGFloat(max(segments.count - 1, 0)) * 1.5
        let usable = max(available - gaps, 0)
        let share = CGFloat(Double(segment.bytes) / Double(total))
        return max(usable * share, 3)
    }

    private var accessibilityText: String {
        segments
            .map { "\($0.title) \(AfterRayStorageSnapshot.byteCount($0.bytes))" }
            .joined(separator: ", ")
    }
}

// MARK: - Controls

private struct SettingsDeveloperUnlockMonitor: NSViewRepresentable {
    let onUnlock: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUnlock: onUnlock)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onUnlock = onUnlock
        context.coordinator.view = view
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onUnlock: () -> Void
        weak var view: NSView?
        private var monitor: Any?
        private var sequence = SettingsDeveloperUnlockSequence()

        init(onUnlock: @escaping () -> Void) {
            self.onUnlock = onUnlock
        }

        func install(for view: NSView) {
            self.view = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.view?.window?.isKeyWindow == true,
                      !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      let characters = event.charactersIgnoringModifiers
                else { return event }
                if sequence.consume(characters, at: event.timestamp) {
                    onUnlock()
                }
                // The hidden sequence has no text field to receive it. Consume
                // its letters so a successful attempt does not produce four
                // AppKit error beeps; unrelated keys keep their normal path.
                return ["l", "o", "r"].contains(characters.lowercased()) ? nil : event
            }
        }

        func uninstall() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            view = nil
        }
    }
}

private struct SettingsSidebarRow: View {
    let page: AfterRaySettingsPage
    let isSelected: Bool
    let badge: Int
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? page.selectedIcon : page.icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 17)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? SettingsPalette.label : SettingsPalette.secondaryLabel)
                Spacer(minLength: 6)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(SettingsPalette.accent)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(SettingsPalette.accent.opacity(0.18), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(rowFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .onHover { isHovering = $0 }
    }

    private var iconColor: Color {
        if isSelected { return SettingsPalette.accent }
        return isHovering ? SettingsPalette.label : SettingsPalette.secondaryLabel
    }

    private var rowFill: Color {
        if isSelected { return Color.white.opacity(0.085) }
        return isHovering ? Color.white.opacity(0.045) : .clear
    }
}

private struct SettingsIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? SettingsPalette.label : SettingsPalette.secondaryLabel)
                .frame(width: 28, height: 28)
                .background(
                    isHovering ? SettingsPalette.controlFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .onHover { isHovering = $0 }
        .help(help)
        // `help` is only a tooltip; without this VoiceOver announces the
        // header's two controls as unlabelled buttons.
        .accessibilityLabel(help)
    }
}

/// Real buttons instead of grey text: every action now reads as pressable, and
/// destructive ones no longer look identical to `Refresh`.
private struct SettingsButtonStyle: ButtonStyle {
    enum Kind {
        case standard
        case prominent
        case destructive
    }

    var kind: Kind = .standard

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.settingsControl)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(fill, in: shape)
                .overlay { shape.strokeBorder(stroke, lineWidth: 1) }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.42)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .onHover { isHovering = isEnabled && $0 }
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: SettingsMetrics.controlRadius, style: .continuous)
        }

        private var labelColor: Color {
            switch kind {
            case .standard: SettingsPalette.label
            case .prominent: .white
            case .destructive: SettingsPalette.danger
            }
        }

        private var fill: Color {
            switch kind {
            case .standard:
                isHovering ? SettingsPalette.controlHover : SettingsPalette.controlFill
            case .prominent:
                SettingsPalette.accent.opacity(isHovering ? 1 : 0.88)
            case .destructive:
                isHovering ? SettingsPalette.danger.opacity(0.16) : Color.white.opacity(0.05)
            }
        }

        private var stroke: Color {
            switch kind {
            case .standard: SettingsPalette.controlStroke
            case .prominent: .clear
            case .destructive: SettingsPalette.danger.opacity(0.35)
            }
        }
    }
}

private struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
