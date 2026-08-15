import Darwin
import Foundation

public enum DaemonClientError: LocalizedError, Equatable {
    case connection(String)
    case invalidResponse
    case rejected(String)
    case protocolMismatch(Int)
    case missingData

    public var errorDescription: String? {
        switch self {
        case .connection(let message): "Could not reach afterrayd: \(message)"
        case .invalidResponse: "afterrayd returned invalid JSON"
        case .rejected(let message): message
        case .protocolMismatch(let version): "Unsupported daemon protocol \(version)"
        case .missingData: "afterrayd returned no data"
        }
    }
}

public protocol RecallDaemonServing: Sendable {
    func sessions() async throws -> [RecallSession]
    func timeline() async throws -> [RecallMoment]
    func timeline(sinceMs: Int64) async throws -> [RecallMoment]
    func moments(sessionID: String) async throws -> [RecallMoment]
    func recallWindow(sessionID: String, centerMs: Int64, limit: Int) async throws -> [RecallMoment]
    func daySummary(dayMs: Int64) async throws -> DaySummary
    func summaryHistory(beforeMs: Int64?, limit: Int) async throws -> SummaryHistoryPage
    func artifact(id: String) async throws -> ArtifactPayload
    func gopSegment(id: String) async throws -> ArtifactPayload
    func gopFrame(segmentID: String, index: UInt16, mode: String) async throws -> ArtifactPayload
    /// Smallest pixels available for a moment. Usually a cached JPEG thumbnail,
    /// but moments packed before thumbnails existed answer with the IVF frame —
    /// always decode by `contentType`, never by assumption.
    func thumbnail(momentID: String, maxEdge: Int?) async throws -> ArtifactPayload
    func evidenceOcr(momentID: String) async throws -> OcrEvidence
    func setFavorite(momentID: String, favorite: Bool) async throws
}

public extension RecallDaemonServing {
    func gopSegment(id _: String) async throws -> ArtifactPayload {
        throw DaemonClientError.rejected("gop segment reads are not available")
    }

    func gopFrame(segmentID _: String, index _: UInt16, mode _: String) async throws -> ArtifactPayload {
        throw DaemonClientError.rejected("gop frame reads are not available")
    }

    func daySummary(dayMs _: Int64) async throws -> DaySummary {
        .empty
    }

    func summaryHistory(beforeMs _: Int64?, limit _: Int) async throws -> SummaryHistoryPage {
        SummaryHistoryPage(days: [], nextBeforeMs: nil, hasMore: false)
    }

    func thumbnail(momentID _: String, maxEdge _: Int?) async throws -> ArtifactPayload {
        throw DaemonClientError.rejected("thumbnail reads are not available")
    }

    func evidenceOcr(momentID _: String) async throws -> OcrEvidence {
        throw DaemonClientError.rejected("ocr evidence is not available")
    }
}

public protocol AfterRayChatServing: Sendable {
    func chatList() async throws -> [ChatConversation]
    func chatHistory(conversationID: String) async throws -> [ChatMessage]
    func chatDelete(conversationID: String) async throws
    func chatSend(conversationID: String?, message: String) async throws -> ChatSendResult
    func chatStream(conversationID: String?, message: String) -> AsyncThrowingStream<ChatStreamEvent, Error>
    /// Stops the turn running on a conversation.
    ///
    /// Explicit, and on its own connection, because closing the stream socket
    /// means the opposite thing: the daemon reads a hang-up as "I will read it
    /// later" and lets the turn finish.
    func chatAbort(conversationID: String) async throws
}

public extension AfterRayChatServing {
    func chatList() async throws -> [ChatConversation] {
        throw DaemonClientError.rejected("chat is not available")
    }

    func chatHistory(conversationID _: String) async throws -> [ChatMessage] {
        throw DaemonClientError.rejected("chat is not available")
    }

    func chatDelete(conversationID _: String) async throws {
        throw DaemonClientError.rejected("chat is not available")
    }

    func chatSend(conversationID _: String?, message _: String) async throws -> ChatSendResult {
        throw DaemonClientError.rejected("chat is not available")
    }

    func chatStream(conversationID _: String?, message _: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: DaemonClientError.rejected("chat is not available"))
        }
    }

    func chatAbort(conversationID _: String) async throws {
        throw DaemonClientError.rejected("chat is not available")
    }
}

public protocol AfterRayDaemonServing: RecallDaemonServing, AfterRayChatServing {
    func status() async throws -> DaemonStatus
    func recordStart() async throws -> RecordStartResult
    func recordStop(reason: String?) async throws -> RecordStopResult
    func search(query: String, limit: Int) async throws -> [RecallSearchHit]
    func ask(question: String, fromMs: Int64?, toMs: Int64?) async throws -> AskAnswer
    func shutdown() async throws -> DaemonShutdownResult
    func modelLibrary() async throws -> ModelLibrary
    func settings() async throws -> AppSettings
    func updateSettings(
        recordAudio: Bool?,
        excludedBundleIds: [String]?,
        excludedDomains: [String]?,
        llmProvider: LlmProvider?,
        llmBaseUrl: String?,
        llmModel: String?,
        llmApiKey: String?,
        storageLimitBytes: UInt64?,
        uiLanguage: String?,
        summaryLanguage: String?
    ) async throws -> AppSettings
    func probeLlm(provider: LlmProvider?, baseUrl: String?) async throws -> LlmEndpointStatus
    func startModelDownloads(packIDs: [String]) async throws -> ModelLibrary
    func pauseModelDownloads() async throws -> ModelLibrary
    func resumeModelDownloads() async throws -> ModelLibrary
    func cancelModelDownloads() async throws -> ModelLibrary
    func removeModel(packID: String) async throws -> ModelLibrary
    func jobs() async throws -> [ModelJob]
    func clearHistory(scope: HistoryScope) async throws -> HistoryClearResult
}

public extension AfterRayDaemonServing {
    func removeModel(packID _: String) async throws -> ModelLibrary {
        throw DaemonClientError.rejected("model removal is not available")
    }

    func updateSettings(recordAudio: Bool) async throws -> AppSettings {
        try await updateSettings(
            recordAudio: recordAudio,
            excludedBundleIds: nil,
            excludedDomains: nil,
            llmProvider: nil,
            llmBaseUrl: nil,
            llmModel: nil,
            llmApiKey: nil,
            storageLimitBytes: nil,
            uiLanguage: nil,
            summaryLanguage: nil
        )
    }
}

public actor UnixSocketDaemonClient: AfterRayDaemonServing {
    public static let protocolVersion = 8
    public nonisolated let socketPath: String

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath
            ?? ProcessInfo.processInfo.environment["AFTERRAY_SOCKET"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("afterray-v0.sock")
    }

    public func sessions() async throws -> [RecallSession] {
        try await request(WireRequest(type: "sessions_list"), as: [RecallSession].self)
    }

    public func timeline() async throws -> [RecallMoment] {
        try await request(WireRequest(type: "timeline_list"), as: [RecallMoment].self)
    }

    public func timeline(sinceMs: Int64) async throws -> [RecallMoment] {
        try await request(
            WireRequest(type: "timeline_since", sinceMs: sinceMs),
            as: [RecallMoment].self
        )
    }

    public func status() async throws -> DaemonStatus {
        try await request(WireRequest(type: "status"), as: DaemonStatus.self)
    }

    public func recordStart() async throws -> RecordStartResult {
        try await request(WireRequest(type: "record_start"), as: RecordStartResult.self)
    }

    public func recordStop(reason: String? = nil) async throws -> RecordStopResult {
        try await request(WireRequest(type: "record_stop", reason: reason), as: RecordStopResult.self)
    }

    public func shutdown() async throws -> DaemonShutdownResult {
        try await request(WireRequest(type: "shutdown"), as: DaemonShutdownResult.self)
    }

    public func modelLibrary() async throws -> ModelLibrary {
        try await request(WireRequest(type: "models_status"), as: ModelLibrary.self)
    }

    public func settings() async throws -> AppSettings {
        try await request(WireRequest(type: "settings"), as: AppSettings.self)
    }

    public func updateSettings(
        recordAudio: Bool?,
        excludedBundleIds: [String]?,
        excludedDomains: [String]?,
        llmProvider: LlmProvider? = nil,
        llmBaseUrl: String? = nil,
        llmModel: String? = nil,
        llmApiKey: String? = nil,
        storageLimitBytes: UInt64? = nil,
        uiLanguage: String? = nil,
        summaryLanguage: String? = nil
    ) async throws -> AppSettings {
        try await request(
            WireRequest(
                type: "update_settings",
                recordAudio: recordAudio,
                excludedBundleIds: excludedBundleIds,
                excludedDomains: excludedDomains,
                llmProvider: llmProvider?.rawValue,
                llmBaseUrl: llmBaseUrl,
                llmModel: llmModel,
                llmApiKey: llmApiKey,
                storageLimitBytes: storageLimitBytes,
                uiLanguage: uiLanguage,
                summaryLanguage: summaryLanguage
            ),
            as: AppSettings.self
        )
    }

    public func probeLlm(provider: LlmProvider? = nil, baseUrl: String? = nil) async throws -> LlmEndpointStatus {
        try await request(
            WireRequest(type: "llm_probe", provider: provider?.rawValue, baseUrl: baseUrl),
            as: LlmEndpointStatus.self
        )
    }

    public func clearHistory(scope: HistoryScope) async throws -> HistoryClearResult {
        try await request(
            WireRequest(type: "clear_history", historyScope: scope.rawValue),
            as: HistoryClearResult.self
        )
    }

    public func startModelDownloads(packIDs: [String] = []) async throws -> ModelLibrary {
        try await request(
            WireRequest(type: "download_models", packIDs: packIDs),
            as: ModelLibrary.self
        )
    }

    public func pauseModelDownloads() async throws -> ModelLibrary {
        try await request(WireRequest(type: "pause_model_downloads"), as: ModelLibrary.self)
    }

    public func resumeModelDownloads() async throws -> ModelLibrary {
        try await request(WireRequest(type: "resume_model_downloads"), as: ModelLibrary.self)
    }

    public func cancelModelDownloads() async throws -> ModelLibrary {
        try await request(WireRequest(type: "cancel_model_downloads"), as: ModelLibrary.self)
    }

    public func removeModel(packID: String) async throws -> ModelLibrary {
        try await request(
            WireRequest(type: "remove_model", packID: packID),
            as: ModelLibrary.self
        )
    }

    public func jobs() async throws -> [ModelJob] {
        try await request(WireRequest(type: "jobs_list"), as: [ModelJob].self)
    }

    public func search(query: String, limit: Int = 30) async throws -> [RecallSearchHit] {
        try await request(
            WireRequest(type: "search", limit: limit, query: query),
            as: [RecallSearchHit].self
        )
    }

    public func ask(question: String, fromMs: Int64? = nil, toMs: Int64? = nil) async throws -> AskAnswer {
        try await request(
            WireRequest(type: "ask", question: question, fromMs: fromMs, toMs: toMs),
            as: AskAnswer.self
        )
    }

    public func chatList() async throws -> [ChatConversation] {
        try await request(WireRequest(type: "chat_list"), as: ChatListPayload.self).conversations
    }

    public func chatHistory(conversationID: String) async throws -> [ChatMessage] {
        try await request(
            WireRequest(type: "chat_history", conversationID: conversationID),
            as: ChatHistoryPayload.self
        ).messages
    }

    public func chatAbort(conversationID: String) async throws {
        let _: EmptyResponse = try await request(
            WireRequest(type: "chat_abort", conversationID: conversationID),
            as: EmptyResponse.self,
            allowEmptyObject: true
        )
    }

    public func chatDelete(conversationID: String) async throws {
        let _: EmptyResponse = try await request(
            WireRequest(type: "chat_delete", conversationID: conversationID),
            as: EmptyResponse.self,
            allowEmptyObject: true
        )
    }

    public func chatSend(conversationID: String?, message: String) async throws -> ChatSendResult {
        try await request(
            WireRequest(type: "chat_send", conversationID: conversationID, message: message),
            as: ChatSendResult.self
        )
    }

    public nonisolated func chatStream(conversationID: String?, message: String) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        let encoded: Data
        do {
            var payload = try JSONEncoder().encode(
                WireRequest(type: "chat_stream", conversationID: conversationID, message: message)
            )
            payload.append(0x0A)
            encoded = payload
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let path = socketPath
        return AsyncThrowingStream { continuation in
            let socket = StreamSocket()
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try UnixLineTransport.stream(
                        path: path,
                        payload: encoded,
                        socket: socket,
                        isCancelled: { Task.isCancelled },
                        onLine: { line in
                            guard let event = try ChatStreamEventDecoder.decode(line: line) else {
                                return true
                            }
                            continuation.yield(event)
                            return !event.isTerminal
                        }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                socket.interrupt()
                task.cancel()
            }
        }
    }

    public func moments(sessionID: String) async throws -> [RecallMoment] {
        try await request(WireRequest(type: "moments_list", sessionID: sessionID), as: [RecallMoment].self)
    }

    public func daySummary(dayMs: Int64) async throws -> DaySummary {
        try await request(WireRequest(type: "day_summary", dayMs: dayMs), as: DaySummary.self)
    }

    public func summaryHistory(beforeMs: Int64?, limit: Int = 7) async throws -> SummaryHistoryPage {
        try await request(
            WireRequest(type: "summary_history", limit: limit, beforeMs: beforeMs),
            as: SummaryHistoryPage.self
        )
    }

    public func recallWindow(sessionID: String, centerMs: Int64, limit: Int = 120) async throws -> [RecallMoment] {
        try await request(
            WireRequest(type: "recall_window", sessionID: sessionID, centerMs: centerMs, limit: limit),
            as: [RecallMoment].self
        )
    }

    public func artifact(id: String) async throws -> ArtifactPayload {
        try await framed(WireRequest(type: "read_artifact", artifactID: id))
    }

    public func gopSegment(id: String) async throws -> ArtifactPayload {
        try await framed(WireRequest(type: "read_gop_segment", segmentID: id))
    }

    public func gopFrame(segmentID: String, index: UInt16, mode: String) async throws -> ArtifactPayload {
        try await framed(
            WireRequest(type: "read_gop_frame", segmentID: segmentID, gopIndex: index, gopMode: mode)
        )
    }

    public func thumbnail(momentID: String, maxEdge: Int? = nil) async throws -> ArtifactPayload {
        try await framed(
            WireRequest(type: "read_thumbnail", momentID: momentID, maxEdge: maxEdge)
        )
    }

    public func evidenceOcr(momentID: String) async throws -> OcrEvidence {
        try await request(
            WireRequest(type: "evidence_ocr", momentID: momentID),
            as: OcrEvidence.self
        )
    }

    private func framed(_ request: WireRequest) async throws -> ArtifactPayload {
        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        let path = socketPath
        return try await Task.detached(priority: .userInitiated) {
            try UnixLineTransport.exchangeArtifact(path: path, payload: payload)
        }.value
    }

    public func setFavorite(momentID: String, favorite: Bool) async throws {
        let _: EmptyResponse = try await request(
            WireRequest(type: "favorite_set", momentID: momentID, favorite: favorite),
            as: EmptyResponse.self,
            allowEmptyObject: true
        )
    }

    private func request<T: Decodable>(
        _ request: WireRequest,
        as type: T.Type,
        allowEmptyObject: Bool = false
    ) async throws -> T {
        let encoder = JSONEncoder()
        var payload = try encoder.encode(request)
        payload.append(0x0A)
        let path = socketPath
        let responseData = try await Task.detached(priority: .userInitiated) {
            try UnixLineTransport.exchange(path: path, payload: payload)
        }.value

        guard
            let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let version = object["protocol_version"] as? Int,
            let ok = object["ok"] as? Bool
        else { throw DaemonClientError.invalidResponse }

        guard version == Self.protocolVersion else {
            throw DaemonClientError.protocolMismatch(version)
        }
        guard ok else {
            throw DaemonClientError.rejected(object["error"] as? String ?? "Unknown daemon error")
        }

        if let dataObject = object["data"] {
            let nested = try JSONSerialization.data(withJSONObject: dataObject)
            return try JSONDecoder().decode(T.self, from: nested)
        }
        if allowEmptyObject, let empty = EmptyResponse() as? T { return empty }
        throw DaemonClientError.missingData
    }
}

struct WireRequest: Encodable, Equatable {
    let type: String
    var sessionID: String?
    var centerMs: Int64?
    var limit: Int?
    var artifactID: String?
    var momentID: String?
    var favorite: Bool?
    var query: String?
    var question: String?
    var fromMs: Int64?
    var toMs: Int64?
    var sinceMs: Int64?
    var dayMs: Int64?
    var beforeMs: Int64?
    var recordAudio: Bool?
    var reason: String?
    var packID: String?
    var packIDs: [String]?
    var segmentID: String?
    var gopIndex: UInt16?
    var gopMode: String?
    var maxEdge: Int?
    var excludedBundleIds: [String]?
    var excludedDomains: [String]?
    var historyScope: String?
    var llmProvider: String?
    var llmBaseUrl: String?
    var llmModel: String?
    var llmApiKey: String?
    var storageLimitBytes: UInt64?
    var uiLanguage: String?
    var summaryLanguage: String?
    var provider: String?
    var baseUrl: String?
    var conversationID: String? = nil
    var message: String? = nil

    enum CodingKeys: String, CodingKey {
        case type
        case sessionID = "session_id"
        case centerMs = "center_ms"
        case limit
        case artifactID = "artifact_id"
        case momentID = "moment_id"
        case favorite
        case query
        case question
        case fromMs = "from_ms"
        case toMs = "to_ms"
        case sinceMs = "since_ms"
        case dayMs = "day_ms"
        case beforeMs = "before_ms"
        case recordAudio = "record_audio"
        case reason
        case packID = "pack_id"
        case packIDs = "pack_ids"
        case segmentID = "segment_id"
        case gopIndex = "index"
        case gopMode = "mode"
        case maxEdge = "max_edge"
        case excludedBundleIds = "excluded_bundle_ids"
        case excludedDomains = "excluded_domains"
        case historyScope = "scope"
        case llmProvider = "llm_provider"
        case llmBaseUrl = "llm_base_url"
        case llmModel = "llm_model"
        case llmApiKey = "llm_api_key"
        case storageLimitBytes = "storage_limit_bytes"
        case uiLanguage = "ui_language"
        case summaryLanguage = "summary_language"
        case provider
        case baseUrl = "base_url"
        case conversationID = "conversation_id"
        case message
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(centerMs, forKey: .centerMs)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(artifactID, forKey: .artifactID)
        try container.encodeIfPresent(momentID, forKey: .momentID)
        try container.encodeIfPresent(favorite, forKey: .favorite)
        try container.encodeIfPresent(query, forKey: .query)
        try container.encodeIfPresent(question, forKey: .question)
        try container.encodeIfPresent(fromMs, forKey: .fromMs)
        try container.encodeIfPresent(toMs, forKey: .toMs)
        try container.encodeIfPresent(sinceMs, forKey: .sinceMs)
        try container.encodeIfPresent(dayMs, forKey: .dayMs)
        try container.encodeIfPresent(beforeMs, forKey: .beforeMs)
        try container.encodeIfPresent(recordAudio, forKey: .recordAudio)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(packID, forKey: .packID)
        if let packIDs, !packIDs.isEmpty {
            try container.encode(packIDs, forKey: .packIDs)
        }
        try container.encodeIfPresent(segmentID, forKey: .segmentID)
        try container.encodeIfPresent(gopIndex, forKey: .gopIndex)
        try container.encodeIfPresent(gopMode, forKey: .gopMode)
        try container.encodeIfPresent(maxEdge, forKey: .maxEdge)
        try container.encodeIfPresent(excludedBundleIds, forKey: .excludedBundleIds)
        try container.encodeIfPresent(excludedDomains, forKey: .excludedDomains)
        try container.encodeIfPresent(historyScope, forKey: .historyScope)
        try container.encodeIfPresent(llmProvider, forKey: .llmProvider)
        try container.encodeIfPresent(llmBaseUrl, forKey: .llmBaseUrl)
        try container.encodeIfPresent(llmModel, forKey: .llmModel)
        try container.encodeIfPresent(llmApiKey, forKey: .llmApiKey)
        try container.encodeIfPresent(storageLimitBytes, forKey: .storageLimitBytes)
        try container.encodeIfPresent(uiLanguage, forKey: .uiLanguage)
        try container.encodeIfPresent(summaryLanguage, forKey: .summaryLanguage)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
        try container.encodeIfPresent(conversationID, forKey: .conversationID)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

struct EmptyResponse: Codable {
    init() {}
}

final class StreamSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    func attach(_ descriptor: Int32) {
        lock.lock()
        self.descriptor = descriptor
        lock.unlock()
    }

    func interrupt() {
        lock.lock()
        let descriptor = self.descriptor
        lock.unlock()
        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }
}

enum UnixLineTransport {
    /// Unary requests get a receive deadline. Without one, a daemon that is
    /// alive but wedged (model queue jammed, vault lock held) parks every
    /// caller in a blocking `read` forever — awaits that never resume are how
    /// the overlay froze on 2026-08-15. Streaming reads (`readLines`) stay
    /// deadline-free: a chat stream legitimately goes quiet during prefill.
    static let unaryReceiveTimeout: TimeInterval = 30

    static func exchange(
        path: String,
        payload: Data,
        receiveTimeout: TimeInterval = UnixLineTransport.unaryReceiveTimeout
    ) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("open socket") }
        defer { Darwin.close(descriptor) }
        try applyReceiveTimeout(descriptor: descriptor, seconds: receiveTimeout)
        try connect(descriptor: descriptor, path: path)
        try writeAll(descriptor: descriptor, payload: payload)
        return try readLine(descriptor: descriptor)
    }

    static func exchangeArtifact(path: String, payload: Data) throws -> ArtifactPayload {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("open socket") }
        defer { Darwin.close(descriptor) }
        try applyReceiveTimeout(descriptor: descriptor, seconds: unaryReceiveTimeout)
        try connect(descriptor: descriptor, path: path)
        try writeAll(descriptor: descriptor, payload: payload)

        let framed = try readLineAndLeftover(descriptor: descriptor)
        let header = try decodeHeader(framed.line)
        guard header.ok else {
            throw DaemonClientError.rejected(header.error ?? "Unknown daemon error")
        }
        guard let metaObject = header.data else { throw DaemonClientError.missingData }
        let nested = try JSONSerialization.data(withJSONObject: metaObject)
        let meta = try JSONDecoder().decode(ArtifactMeta.self, from: nested)
        guard meta.byteLength >= 0, meta.byteLength <= 8 * 1_024 * 1_024 else {
            throw DaemonClientError.invalidResponse
        }
        let bytes = try readExact(
            descriptor: descriptor,
            count: meta.byteLength,
            prefix: framed.leftover
        )
        return ArtifactPayload(id: meta.id, contentType: meta.contentType, bytes: bytes)
    }

    static func stream(
        path: String,
        payload: Data,
        socket: StreamSocket? = nil,
        isCancelled: @escaping () -> Bool,
        onLine: (Data) throws -> Bool
    ) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("open socket") }
        socket?.attach(descriptor)
        defer { Darwin.close(descriptor) }
        try connect(descriptor: descriptor, path: path)
        try writeAll(descriptor: descriptor, payload: payload)
        try readLines(descriptor: descriptor, isCancelled: isCancelled, onLine: onLine)
    }

    static func readLines(
        descriptor: Int32,
        isCancelled: () -> Bool,
        onLine: (Data) throws -> Bool
    ) throws {
        let maximumResponseBytes = 64 * 1_024 * 1_024
        var leftover = Data()
        leftover.reserveCapacity(256)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while !isCancelled() {
            while let newline = leftover.firstIndex(of: 0x0A) {
                let line = leftover[..<newline]
                leftover.removeSubrange(...newline)
                let keepReading = try onLine(Data(line))
                if !keepReading { return }
            }
            if leftover.count > maximumResponseBytes {
                throw DaemonClientError.invalidResponse
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                leftover.append(contentsOf: buffer[..<count])
                continue
            }
            if count == 0 {
                if !leftover.isEmpty {
                    _ = try onLine(leftover)
                }
                return
            }
            if errno == EINTR { continue }
            if isCancelled() { return }
            throw posixError("read")
        }
    }

    private static func applyReceiveTimeout(descriptor: Int32, seconds: TimeInterval) throws {
        guard seconds > 0 else { return }
        var timeout = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        let applied = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard applied == 0 else { throw posixError("set receive timeout") }
    }

    private static func connect(descriptor: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw DaemonClientError.connection("socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw posixError("connect") }
    }

    private static func writeAll(descriptor: Int32, payload: Data) throws {
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                guard count > 0 else { throw posixError("write") }
                written += count
            }
        }
    }

    private static func readLine(descriptor: Int32) throws -> Data {
        try readLineAndLeftover(descriptor: descriptor).line
    }

    private static func readLineAndLeftover(descriptor: Int32) throws -> (line: Data, leftover: Data) {
        let maximumResponseBytes = 64 * 1_024 * 1_024
        var response = Data()
        response.reserveCapacity(256)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while response.count < maximumResponseBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw DaemonClientError.connection(
                    "daemon did not respond within \(Int(unaryReceiveTimeout))s"
                )
            }
            guard count > 0 else { break }
            let bytes = buffer[..<count]
            if let newline = bytes.firstIndex(of: 0x0A) {
                response.append(contentsOf: bytes[..<newline])
                return (response, Data(bytes[bytes.index(after: newline)...]))
            }
            response.append(contentsOf: bytes)
        }
        guard !response.isEmpty else { throw DaemonClientError.connection("empty response") }
        return (response, Data())
    }

    private static func readExact(descriptor: Int32, count: Int, prefix: Data) throws -> Data {
        var data = prefix
        if data.count > count {
            throw DaemonClientError.invalidResponse
        }
        data.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < count {
            let needed = count - data.count
            let readCount = Darwin.read(descriptor, &buffer, min(buffer.count, needed))
            guard readCount > 0 else {
                throw DaemonClientError.connection("artifact body ended early")
            }
            data.append(contentsOf: buffer[..<readCount])
        }
        return data
    }

    private struct Header {
        let ok: Bool
        let data: Any?
        let error: String?
    }

    private static func decodeHeader(_ responseData: Data) throws -> Header {
        guard
            let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let version = object["protocol_version"] as? Int,
            let ok = object["ok"] as? Bool
        else { throw DaemonClientError.invalidResponse }
        guard version == UnixSocketDaemonClient.protocolVersion else {
            throw DaemonClientError.protocolMismatch(version)
        }
        return Header(ok: ok, data: object["data"], error: object["error"] as? String)
    }

    private static func posixError(_ operation: String) -> DaemonClientError {
        DaemonClientError.connection("\(operation): \(String(cString: strerror(errno)))")
    }
}
