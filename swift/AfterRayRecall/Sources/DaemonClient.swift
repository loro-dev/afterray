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

    func thumbnail(momentID _: String, maxEdge _: Int?) async throws -> ArtifactPayload {
        throw DaemonClientError.rejected("thumbnail reads are not available")
    }

    func evidenceOcr(momentID _: String) async throws -> OcrEvidence {
        throw DaemonClientError.rejected("ocr evidence is not available")
    }
}

public protocol AfterRayDaemonServing: RecallDaemonServing {
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
        llmProvider: LlmProvider?,
        llmBaseUrl: String?,
        llmModel: String?,
        llmApiKey: String?
    ) async throws -> AppSettings
    func probeLlm(provider: LlmProvider?, baseUrl: String?) async throws -> LlmEndpointStatus
    func downloadModels(packID: String?) async throws -> ModelLibrary
    func jobs() async throws -> [ModelJob]
    func clearHistory(scope: HistoryScope) async throws -> HistoryClearResult
}

public extension AfterRayDaemonServing {
    func updateSettings(recordAudio: Bool) async throws -> AppSettings {
        try await updateSettings(
            recordAudio: recordAudio,
            excludedBundleIds: nil,
            llmProvider: nil,
            llmBaseUrl: nil,
            llmModel: nil,
            llmApiKey: nil
        )
    }
}

public actor UnixSocketDaemonClient: AfterRayDaemonServing {
    public static let protocolVersion = 6
    public let socketPath: String

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
        llmProvider: LlmProvider? = nil,
        llmBaseUrl: String? = nil,
        llmModel: String? = nil,
        llmApiKey: String? = nil
    ) async throws -> AppSettings {
        try await request(
            WireRequest(
                type: "update_settings",
                recordAudio: recordAudio,
                excludedBundleIds: excludedBundleIds,
                llmProvider: llmProvider?.rawValue,
                llmBaseUrl: llmBaseUrl,
                llmModel: llmModel,
                llmApiKey: llmApiKey
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

    public func downloadModels(packID: String?) async throws -> ModelLibrary {
        try await request(
            WireRequest(type: "download_models", packID: packID),
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

    public func moments(sessionID: String) async throws -> [RecallMoment] {
        try await request(WireRequest(type: "moments_list", sessionID: sessionID), as: [RecallMoment].self)
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
    var recordAudio: Bool?
    var reason: String?
    var packID: String?
    var segmentID: String?
    var gopIndex: UInt16?
    var gopMode: String?
    var maxEdge: Int?
    var excludedBundleIds: [String]?
    var historyScope: String?
    var llmProvider: String?
    var llmBaseUrl: String?
    var llmModel: String?
    var llmApiKey: String?
    var provider: String?
    var baseUrl: String?

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
        case recordAudio = "record_audio"
        case reason
        case packID = "pack_id"
        case segmentID = "segment_id"
        case gopIndex = "index"
        case gopMode = "mode"
        case maxEdge = "max_edge"
        case excludedBundleIds = "excluded_bundle_ids"
        case historyScope = "scope"
        case llmProvider = "llm_provider"
        case llmBaseUrl = "llm_base_url"
        case llmModel = "llm_model"
        case llmApiKey = "llm_api_key"
        case provider
        case baseUrl = "base_url"
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
        try container.encodeIfPresent(recordAudio, forKey: .recordAudio)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(packID, forKey: .packID)
        try container.encodeIfPresent(segmentID, forKey: .segmentID)
        try container.encodeIfPresent(gopIndex, forKey: .gopIndex)
        try container.encodeIfPresent(gopMode, forKey: .gopMode)
        try container.encodeIfPresent(maxEdge, forKey: .maxEdge)
        try container.encodeIfPresent(excludedBundleIds, forKey: .excludedBundleIds)
        try container.encodeIfPresent(historyScope, forKey: .historyScope)
        try container.encodeIfPresent(llmProvider, forKey: .llmProvider)
        try container.encodeIfPresent(llmBaseUrl, forKey: .llmBaseUrl)
        try container.encodeIfPresent(llmModel, forKey: .llmModel)
        try container.encodeIfPresent(llmApiKey, forKey: .llmApiKey)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(baseUrl, forKey: .baseUrl)
    }
}

private struct EmptyResponse: Codable {
    init() {}
}

private enum UnixLineTransport {
    static func exchange(path: String, payload: Data) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("open socket") }
        defer { Darwin.close(descriptor) }
        try connect(descriptor: descriptor, path: path)
        try writeAll(descriptor: descriptor, payload: payload)
        return try readLine(descriptor: descriptor)
    }

    static func exchangeArtifact(path: String, payload: Data) throws -> ArtifactPayload {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError("open socket") }
        defer { Darwin.close(descriptor) }
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
