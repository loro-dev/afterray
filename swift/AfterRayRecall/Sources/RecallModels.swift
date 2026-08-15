import Foundation

public struct RecallSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64?

    public init(id: String, startedAtMs: Int64, endedAtMs: Int64? = nil) {
        self.id = id
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
    }
}

public struct RecallMoment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let capturedAtMs: Int64
    public let imageArtifactId: String?
    public var isFavorite: Bool
    public let gop: RecallGopRef?
    public let stillOrigin: String
    public let ocrText: String?
    public let transcriptText: String?

    /// Optional until the daemon's recall read model attaches the nearest audio segment.
    public let audioArtifactId: String?
    public let audioStartedAtMs: Int64?
    public let accessibilityArtifactId: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let windowTitle: String?
    public let url: String?
    public let document: String?

    public init(
        id: String,
        sessionId: String,
        capturedAtMs: Int64,
        imageArtifactId: String? = nil,
        isFavorite: Bool = false,
        gop: RecallGopRef? = nil,
        stillOrigin: String = "capture",
        ocrText: String? = nil,
        transcriptText: String? = nil,
        audioArtifactId: String? = nil,
        audioStartedAtMs: Int64? = nil,
        accessibilityArtifactId: String? = nil,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        document: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.capturedAtMs = capturedAtMs
        self.imageArtifactId = imageArtifactId
        self.isFavorite = isFavorite
        self.gop = gop
        self.stillOrigin = stillOrigin
        self.ocrText = ocrText
        self.transcriptText = transcriptText
        self.audioArtifactId = audioArtifactId
        self.audioStartedAtMs = audioStartedAtMs
        self.accessibilityArtifactId = accessibilityArtifactId
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.url = url
        self.document = document
    }

    public var hasVisibleTranscript: Bool {
        guard let transcriptText else { return false }
        return !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case capturedAtMs = "captured_at_ms"
        case imageArtifactId = "image_artifact_id"
        case isFavorite = "is_favorite"
        case gop
        case stillOrigin = "still_origin"
        case ocrText = "ocr_text"
        case transcriptText = "transcript_text"
        case audioArtifactId = "audio_artifact_id"
        case audioStartedAtMs = "audio_started_at_ms"
        case accessibilityArtifactId = "accessibility_artifact_id"
        case applicationName = "application_name"
        case bundleIdentifier = "bundle_identifier"
        case windowTitle = "window_title"
        case url
        case document
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        capturedAtMs = try container.decode(Int64.self, forKey: .capturedAtMs)
        imageArtifactId = try container.decodeIfPresent(String.self, forKey: .imageArtifactId)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        gop = try container.decodeIfPresent(RecallGopRef.self, forKey: .gop)
        stillOrigin = try container.decodeIfPresent(String.self, forKey: .stillOrigin) ?? "capture"
        ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        transcriptText = try container.decodeIfPresent(String.self, forKey: .transcriptText)
        audioArtifactId = try container.decodeIfPresent(String.self, forKey: .audioArtifactId)
        audioStartedAtMs = try container.decodeIfPresent(Int64.self, forKey: .audioStartedAtMs)
        accessibilityArtifactId = try container.decodeIfPresent(String.self, forKey: .accessibilityArtifactId)
        applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        document = try container.decodeIfPresent(String.self, forKey: .document)
    }

    public var displayCacheKey: String {
        if let gop { return "gop:\(gop.segmentId)#\(gop.index)" }
        if let imageArtifactId { return imageArtifactId }
        return id
    }
}

public struct RecallGopRef: Codable, Equatable, Sendable {
    public let segmentId: String
    public let index: UInt16
    public let keyframeIndex: UInt16
    public let frameCount: UInt16
    public let codec: String

    public init(
        segmentId: String,
        index: UInt16,
        keyframeIndex: UInt16 = 0,
        frameCount: UInt16,
        codec: String = "av01"
    ) {
        self.segmentId = segmentId
        self.index = index
        self.keyframeIndex = keyframeIndex
        self.frameCount = frameCount
        self.codec = codec
    }

    enum CodingKeys: String, CodingKey {
        case segmentId = "segment_id"
        case index
        case keyframeIndex = "keyframe_index"
        case frameCount = "frame_count"
        case codec
    }
}

public struct ArtifactPayload: Equatable, Sendable {
    public let id: String
    public let contentType: String
    public let bytes: Data

    public init(id: String, contentType: String, bytes: Data) {
        self.id = id
        self.contentType = contentType
        self.bytes = bytes
    }
}

public struct ArtifactMeta: Decodable, Equatable, Sendable {
    public let id: String
    public let contentType: String
    public let byteLength: Int

    enum CodingKeys: String, CodingKey {
        case id
        case contentType = "content_type"
        case byteLength = "byte_length"
    }
}

public enum DaemonRecordingState: String, Codable, Equatable, Sendable {
    case idle
    case waiting
    case recording
    case stopping
    case failed
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public let daemonVersion: String
    public let protocolVersion: Int
    public let schemaVersion: Int
    public let recordingState: DaemonRecordingState
    public let activeSessionId: String?

    public init(
        daemonVersion: String,
        protocolVersion: Int,
        schemaVersion: Int,
        recordingState: DaemonRecordingState,
        activeSessionId: String? = nil
    ) {
        self.daemonVersion = daemonVersion
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.recordingState = recordingState
        self.activeSessionId = activeSessionId
    }

    enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case protocolVersion = "protocol_version"
        case schemaVersion = "schema_version"
        case recordingState = "recording_state"
        case activeSessionId = "active_session_id"
    }
}

public struct RecordStartResult: Codable, Equatable, Sendable {
    public let session: RecallSession?
    public let sessionId: String?
    public let alreadyRecording: Bool?

    public var effectiveSessionId: String? { session?.id ?? sessionId }

    public init(session: RecallSession? = nil, sessionId: String? = nil, alreadyRecording: Bool? = nil) {
        self.session = session
        self.sessionId = sessionId
        self.alreadyRecording = alreadyRecording
    }

    enum CodingKeys: String, CodingKey {
        case session
        case sessionId = "session_id"
        case alreadyRecording = "already_recording"
    }
}

public struct ModelLibrary: Codable, Equatable, Sendable {
    public let directory: String
    public let packs: [ModelPack]
    public let download: ModelDownloadProgress?

    public init(directory: String, packs: [ModelPack], download: ModelDownloadProgress? = nil) {
        self.directory = directory
        self.packs = packs
        self.download = download
    }

    public var installedBytes: UInt64 {
        packs.reduce(0) { $0 + $1.bytes }
    }
}

public struct ModelJob: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let capability: String
    public let adapter: String
    public let state: String
    public let attempts: UInt32
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
    public let lastError: String?

    public init(
        id: String,
        capability: String,
        adapter: String,
        state: String,
        attempts: UInt32 = 1,
        createdAtMs: Int64 = 0,
        updatedAtMs: Int64 = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.capability = capability
        self.adapter = adapter
        self.state = state
        self.attempts = attempts
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case id
        case capability
        case adapter
        case state
        case attempts
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case lastError = "last_error"
    }
}

public struct ModelDownloadProgress: Codable, Equatable, Sendable {
    public let packId: String
    public let state: ModelPackState
    public let bytes: UInt64
    public let expectedBytes: UInt64?
    public let completedFiles: UInt64
    public let totalFiles: UInt64
    public let error: String?

    public init(
        packId: String,
        state: ModelPackState = .downloading,
        bytes: UInt64,
        expectedBytes: UInt64? = nil,
        completedFiles: UInt64 = 0,
        totalFiles: UInt64 = 0,
        error: String? = nil
    ) {
        self.packId = packId
        self.state = state
        self.bytes = bytes
        self.expectedBytes = expectedBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.error = error
    }

    public var fraction: Double? {
        guard let expected = expectedBytes, expected > 0 else { return nil }
        return min(Double(bytes) / Double(expected), 1)
    }

    public var percent: Int? {
        fraction.map { Int(($0 * 100).rounded(.down)) }
    }

    enum CodingKeys: String, CodingKey {
        case packId = "pack_id"
        case state
        case bytes
        case expectedBytes = "expected_bytes"
        case completedFiles = "completed_files"
        case totalFiles = "total_files"
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packId = try container.decode(String.self, forKey: .packId)
        state = try container.decodeIfPresent(ModelPackState.self, forKey: .state) ?? .downloading
        bytes = try container.decode(UInt64.self, forKey: .bytes)
        expectedBytes = try container.decodeIfPresent(UInt64.self, forKey: .expectedBytes)
        completedFiles = try container.decodeIfPresent(UInt64.self, forKey: .completedFiles) ?? 0
        totalFiles = try container.decodeIfPresent(UInt64.self, forKey: .totalFiles) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

public enum ModelPackState: String, Codable, Equatable, Sendable {
    case notDownloaded = "not_downloaded"
    case downloading
    case verifying
    case ready
    case inUse = "in_use"
    case failed
    case incompatible
}

public struct ModelPack: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let capability: String
    public let path: String
    public let present: Bool
    public let bytes: UInt64
    public let required: Bool
    public let note: String?
    public let expectedBytes: UInt64?
    public let state: ModelPackState
    public let revision: String?
    public let error: String?

    public init(
        id: String,
        name: String,
        capability: String,
        path: String,
        present: Bool,
        bytes: UInt64,
        required: Bool,
        note: String? = nil,
        expectedBytes: UInt64? = nil,
        state: ModelPackState? = nil,
        revision: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.capability = capability
        self.path = path
        self.present = present
        self.bytes = bytes
        self.required = required
        self.note = note
        self.expectedBytes = expectedBytes
        self.state = state ?? (present ? .ready : .notDownloaded)
        self.revision = revision
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case capability
        case path
        case present
        case bytes
        case required
        case note
        case expectedBytes = "expected_bytes"
        case state
        case revision
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        capability = try container.decode(String.self, forKey: .capability)
        path = try container.decode(String.self, forKey: .path)
        present = try container.decode(Bool.self, forKey: .present)
        bytes = try container.decode(UInt64.self, forKey: .bytes)
        required = try container.decode(Bool.self, forKey: .required)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        expectedBytes = try container.decodeIfPresent(UInt64.self, forKey: .expectedBytes)
        state = try container.decodeIfPresent(ModelPackState.self, forKey: .state)
            ?? (present ? .ready : .notDownloaded)
        revision = try container.decodeIfPresent(String.self, forKey: .revision)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

public enum LlmProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtin
    case mlxLocal = "mlx_local"
    case ollama
    case openaiCompatible = "openai_compatible"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .builtin: "Built-in"
        case .mlxLocal: "AfterRay Local (MLX)"
        case .ollama: "Ollama"
        case .openaiCompatible: "OpenAI compatible"
        }
    }
}

public struct LlmRemoteModel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name ?? id
    }
}

public struct LlmEndpointStatus: Codable, Equatable, Sendable {
    public let reachable: Bool
    public let models: [LlmRemoteModel]
    public let recommendedModel: String?
    public let error: String?
    public let defaultBaseUrl: String

    public init(
        reachable: Bool,
        models: [LlmRemoteModel] = [],
        recommendedModel: String? = nil,
        error: String? = nil,
        defaultBaseUrl: String = "http://127.0.0.1:11434"
    ) {
        self.reachable = reachable
        self.models = models
        self.recommendedModel = recommendedModel
        self.error = error
        self.defaultBaseUrl = defaultBaseUrl
    }

    enum CodingKeys: String, CodingKey {
        case reachable
        case models
        case recommendedModel = "recommended_model"
        case error
        case defaultBaseUrl = "default_base_url"
    }
}

/// One language the daemon is willing to store. The catalogue lives in
/// afterray-protocol; Swift only renders what Settings already returned.
public struct LanguageOption: Codable, Equatable, Identifiable, Sendable {
    public let code: String
    public let nativeName: String
    public let englishName: String

    public var id: String { code }

    public init(code: String, nativeName: String, englishName: String) {
        self.code = code
        self.nativeName = nativeName
        self.englishName = englishName
    }

    enum CodingKeys: String, CodingKey {
        case code
        case nativeName = "native_name"
        case englishName = "english_name"
    }

    public static let autoCode = "auto"

    /// Last-resort row when an old daemon omits `language_options`.
    public static let followSystem = LanguageOption(
        code: autoCode,
        nativeName: "跟随系统",
        englishName: "Follow system"
    )

    public var isAuto: Bool {
        code.compare(Self.autoCode, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Menu label: `auto` is always 「跟随系统」, everything else uses the native name.
    public var menuTitle: String {
        isAuto ? "跟随系统" : nativeName
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultStorageLimitBytes: UInt64 = 100_000_000_000
    public static let defaultLanguage = LanguageOption.autoCode

    public let dataDir: String
    public let modelDir: String
    public let recordAudio: Bool
    public let captureIntervalSeconds: UInt64
    public let storageLimitBytes: UInt64
    public let excludedBundleIds: [String]
    /// Hosts never recorded. Subdomains are covered by the daemon.
    public let excludedDomains: [String]
    public let llmProvider: LlmProvider
    public let llmBaseUrl: String
    public let llmModel: String
    public let llmApiKeySet: Bool
    public let uiLanguage: String
    public let summaryLanguage: String
    public let languageOptions: [LanguageOption]

    public init(
        dataDir: String,
        modelDir: String,
        recordAudio: Bool,
        captureIntervalSeconds: UInt64,
        storageLimitBytes: UInt64 = Self.defaultStorageLimitBytes,
        excludedBundleIds: [String] = [],
        excludedDomains: [String] = [],
        llmProvider: LlmProvider = .builtin,
        llmBaseUrl: String = "",
        llmModel: String = "",
        llmApiKeySet: Bool = false,
        uiLanguage: String = defaultLanguage,
        summaryLanguage: String = defaultLanguage,
        languageOptions: [LanguageOption] = []
    ) {
        self.dataDir = dataDir
        self.modelDir = modelDir
        self.recordAudio = recordAudio
        self.captureIntervalSeconds = captureIntervalSeconds
        self.storageLimitBytes = storageLimitBytes
        self.excludedBundleIds = excludedBundleIds
        self.excludedDomains = excludedDomains
        self.llmProvider = llmProvider
        self.llmBaseUrl = llmBaseUrl
        self.llmModel = llmModel
        self.llmApiKeySet = llmApiKeySet
        self.uiLanguage = uiLanguage
        self.summaryLanguage = summaryLanguage
        self.languageOptions = languageOptions
    }

    enum CodingKeys: String, CodingKey {
        case dataDir = "data_dir"
        case modelDir = "model_dir"
        case recordAudio = "record_audio"
        case captureIntervalSeconds = "capture_interval_seconds"
        case storageLimitBytes = "storage_limit_bytes"
        case excludedBundleIds = "excluded_bundle_ids"
        case excludedDomains = "excluded_domains"
        case llmProvider = "llm_provider"
        case llmBaseUrl = "llm_base_url"
        case llmModel = "llm_model"
        case llmApiKeySet = "llm_api_key_set"
        case uiLanguage = "ui_language"
        case summaryLanguage = "summary_language"
        case languageOptions = "language_options"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataDir = try container.decode(String.self, forKey: .dataDir)
        modelDir = try container.decode(String.self, forKey: .modelDir)
        recordAudio = try container.decode(Bool.self, forKey: .recordAudio)
        captureIntervalSeconds = try container.decode(UInt64.self, forKey: .captureIntervalSeconds)
        storageLimitBytes = try container.decodeIfPresent(UInt64.self, forKey: .storageLimitBytes)
            ?? Self.defaultStorageLimitBytes
        excludedBundleIds = try container.decodeIfPresent([String].self, forKey: .excludedBundleIds) ?? []
        excludedDomains = try container.decodeIfPresent([String].self, forKey: .excludedDomains) ?? []
        llmProvider = try container.decodeIfPresent(LlmProvider.self, forKey: .llmProvider) ?? .builtin
        llmBaseUrl = try container.decodeIfPresent(String.self, forKey: .llmBaseUrl) ?? ""
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? ""
        llmApiKeySet = try container.decodeIfPresent(Bool.self, forKey: .llmApiKeySet) ?? false
        uiLanguage = try container.decodeIfPresent(String.self, forKey: .uiLanguage) ?? Self.defaultLanguage
        summaryLanguage = try container.decodeIfPresent(String.self, forKey: .summaryLanguage)
            ?? Self.defaultLanguage
        languageOptions = try container.decodeIfPresent([LanguageOption].self, forKey: .languageOptions) ?? []
    }

    /// Rows for a language picker. The catalogue itself is never hardcoded here;
    /// an empty list (old daemon) falls back to `auto` so the control still works.
    public func languagePickerOptions(selected: String) -> [LanguageOption] {
        var options = languageOptions.isEmpty ? [LanguageOption.followSystem] : languageOptions
        if !selected.isEmpty, !options.contains(where: { $0.code == selected }) {
            options.append(LanguageOption(code: selected, nativeName: selected, englishName: selected))
        }
        return options
    }
}

public enum HistoryScope: String, Codable, Sendable {
    case lastHour = "last_hour"
    case today
    case all
}

public struct HistoryClearResult: Codable, Equatable, Sendable {
    public let deleted: Int
    public let scope: String?
}

public struct DaemonShutdownResult: Codable, Equatable, Sendable {
    public let stopping: Bool
    public let pid: Int32?

    public init(stopping: Bool, pid: Int32? = nil) {
        self.stopping = stopping
        self.pid = pid
    }
}

public struct RecordStopResult: Codable, Equatable, Sendable {
    public let sessionId: String?
    public let alreadyStopped: Bool?

    public init(sessionId: String? = nil, alreadyStopped: Bool? = nil) {
        self.sessionId = sessionId
        self.alreadyStopped = alreadyStopped
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case alreadyStopped = "already_stopped"
    }
}

public struct AskCitation: Codable, Equatable, Identifiable, Sendable {
    public let momentId: String
    public let capturedAtMs: Int64
    public let label: String
    public let excerpt: String

    public var id: String { "\(momentId):\(capturedAtMs)" }

    public init(momentId: String, capturedAtMs: Int64, label: String, excerpt: String) {
        self.momentId = momentId
        self.capturedAtMs = capturedAtMs
        self.label = label
        self.excerpt = excerpt
    }

    enum CodingKeys: String, CodingKey {
        case momentId = "moment_id"
        case capturedAtMs = "captured_at_ms"
        case label
        case excerpt
    }

    public func asSearchHit() -> RecallSearchHit {
        RecallSearchHit(
            momentId: momentId,
            sessionId: "",
            capturedAtMs: capturedAtMs,
            source: "ask",
            text: excerpt,
            score: 1
        )
    }
}

public struct AskAnswer: Codable, Equatable, Sendable {
    public let answer: String
    public let citations: [AskCitation]
    public let modelMissing: Bool

    public init(answer: String, citations: [AskCitation] = [], modelMissing: Bool = false) {
        self.answer = answer
        self.citations = citations
        self.modelMissing = modelMissing
    }

    enum CodingKeys: String, CodingKey {
        case answer
        case citations
        case modelMissing = "model_missing"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = try container.decode(String.self, forKey: .answer)
        citations = try container.decodeIfPresent([AskCitation].self, forKey: .citations) ?? []
        modelMissing = try container.decodeIfPresent(Bool.self, forKey: .modelMissing) ?? false
    }
}

public struct RecallSearchHit: Codable, Equatable, Identifiable, Sendable {
    public let momentId: String
    public let sessionId: String
    public let capturedAtMs: Int64
    public let source: String
    public let text: String
    public let score: Double

    public var id: String { "\(momentId):\(source)" }

    public init(
        momentId: String,
        sessionId: String,
        capturedAtMs: Int64,
        source: String,
        text: String,
        score: Double
    ) {
        self.momentId = momentId
        self.sessionId = sessionId
        self.capturedAtMs = capturedAtMs
        self.source = source
        self.text = text
        self.score = score
    }

    enum CodingKeys: String, CodingKey {
        case momentId = "moment_id"
        case sessionId = "session_id"
        case capturedAtMs = "captured_at_ms"
        case source
        case text
        case score
    }
}

/// One recognized text box on a captured frame.
///
/// Coordinates are Apple Vision's: a unit square with the origin at the
/// **bottom left**, not SwiftUI's top left. `OcrHighlight` does the flip.
public struct OcrRegion: Codable, Equatable, Sendable {
    public let text: String
    public let confidence: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        text: String,
        confidence: Double,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct OcrEvidence: Codable, Equatable, Sendable {
    public let momentId: String
    public let text: String
    public let regions: [OcrRegion]

    public init(momentId: String, text: String, regions: [OcrRegion] = []) {
        self.momentId = momentId
        self.text = text
        self.regions = regions
    }

    enum CodingKeys: String, CodingKey {
        case momentId = "moment_id"
        case text
        case regions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        momentId = try container.decode(String.self, forKey: .momentId)
        text = try container.decode(String.self, forKey: .text)
        // The daemon omits `regions` entirely when a frame produced no boxes.
        regions = try container.decodeIfPresent([OcrRegion].self, forKey: .regions) ?? []
    }
}

public enum RecallLoadState: Equatable, Sendable {
    case loading
    case ready
    case processing(message: String)
    case failed(message: String)
}

public struct RecallVisualTuning: Equatable, Sendable {
    public var topScrimOpacity: Double
    public var bottomScrimOpacity: Double
    public var timelineDensity: Double
    public var timelineSegmentHeight: Double
    public var timelineSegmentGap: Double
    public var dragPointsPerMoment: Double

    public init(
        topScrimOpacity: Double = 0.29,
        bottomScrimOpacity: Double = 0.5,
        timelineDensity: Double = 0.12,
        timelineSegmentHeight: Double = 48,
        timelineSegmentGap: Double = 2,
        dragPointsPerMoment: Double = 54
    ) {
        self.topScrimOpacity = topScrimOpacity
        self.bottomScrimOpacity = bottomScrimOpacity
        self.timelineDensity = timelineDensity
        self.timelineSegmentHeight = timelineSegmentHeight
        self.timelineSegmentGap = timelineSegmentGap
        self.dragPointsPerMoment = dragPointsPerMoment
    }

    public static let standard = RecallVisualTuning()
}

public enum RecallGeometry {
    public static let overlayChromeButtonSize: CGFloat = 40
    public static let overlayChromeMargin: CGFloat = 26
    /// Space between sibling buttons inside one chrome cluster.
    public static let overlayChromeItemGap: CGFloat = 10
    /// Sized for a whole slot card — title plus its bullets — rather than a
    /// one-line index. Narrower than this and every summary wraps into a
    /// column of fragments.
    public static let daySummaryPanelWidth: CGFloat = 392
    public static let daySummaryMaxHeight: CGFloat = 520
    public static let daySummaryListMaxHeight: CGFloat = 460
    public static let daySummaryCornerRadius: CGFloat = 16
    /// Window titles run long. Cap the identity capsule so one verbose title
    /// cannot push the rest of the chrome row off screen.
    public static let appIdentityTitleMaxWidth: CGFloat = 320

    public static func controlBarTopPadding(
        safeAreaTop: CGFloat,
        minimum: CGFloat = 22,
        clearance: CGFloat = 12
    ) -> CGFloat {
        max(minimum, safeAreaTop + clearance)
    }

    /// Extra trailing inset so moment actions sit clear of a separate overlay settings button.
    public static func overlaySettingsReservedWidth(
        buttonSize: CGFloat = overlayChromeButtonSize,
        groupGap: CGFloat = overlayChromeItemGap
    ) -> CGFloat {
        buttonSize + groupGap
    }

    public static func detailsMenuTopPadding(
        chromeTopPadding: CGFloat,
        buttonSize: CGFloat = overlayChromeButtonSize,
        gap: CGFloat = 12
    ) -> CGFloat {
        chromeTopPadding + buttonSize + gap
    }

    public static func clampedIndex(_ index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(index, 0), count - 1)
    }

    public static func index(
        fromDragTranslation translation: Double,
        originIndex: Int,
        count: Int,
        pointsPerMoment: Double
    ) -> Int? {
        guard count > 0, pointsPerMoment > 0 else { return nil }
        let delta = Int((-translation / pointsPerMoment).rounded())
        return clampedIndex(originIndex + delta, count: count)
    }

    /// Positions include one virtual slot after the latest captured moment.
    /// That final slot represents the transparent, live "now" view.
    public static func timelinePosition(
        fromDragTranslation translation: Double,
        originPosition: Int,
        momentCount: Int,
        pointsPerMoment: Double
    ) -> Int {
        guard momentCount > 0, pointsPerMoment > 0 else { return 0 }
        let delta = Int((-translation / pointsPerMoment).rounded())
        return min(max(originPosition + delta, 0), momentCount)
    }

    /// A rightward/upward scroll begins history immediately from the virtual
    /// live slot instead of waiting for the normal accumulated threshold.
    public static func liveScrollStep(delta: CGFloat) -> Int? {
        delta > 0 ? -1 : nil
    }

    public static func accumulatedScrollDelta(
        current: CGFloat,
        incoming: CGFloat,
        maximum: CGFloat = 160
    ) -> CGFloat {
        guard maximum > 0 else { return 0 }
        return min(max(current + incoming, -maximum), maximum)
    }

    public static func drainScrollDelta(
        _ accumulated: CGFloat,
        maximumPerFrame: CGFloat = 40
    ) -> (emitted: CGFloat, remaining: CGFloat) {
        guard maximumPerFrame > 0 else { return (0, accumulated) }
        let emitted = min(max(accumulated, -maximumPerFrame), maximumPerFrame)
        return (emitted, accumulated - emitted)
    }
}
