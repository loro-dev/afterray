import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

public let mlxWorkerProtocolVersion = 1
public let mlxRuntimeVersion = "mlx-swift-lm@3.31.4"
public let qwen35_4BRevision = "32f3e8ecf65426fc3306969496342d504bfa13f3"
public let qwen35_9BRevision = "938d8919941c6e7efd3c7150eff7fe9d12afa631"

public struct MlxWorkerRequest: Decodable, Sendable {
    public struct Message: Decodable, Sendable {
        public let role: String
        public let content: String
    }

    public let v: Int
    public let kind: String
    public let requestId: String
    public let modelDir: String?
    public let messages: [Message]?
    public let images: [String]?
    public let maxTokens: Int?
    public let useKvCache: Bool?

    enum CodingKeys: String, CodingKey {
        case v, kind, messages, images
        case requestId = "request_id"
        case modelDir = "model_dir"
        case maxTokens = "max_tokens"
        case useKvCache = "use_kv_cache"
    }
}

public struct MlxWorkerResponse: Encodable, Sendable {
    public struct Usage: Encodable, Sendable {
        public let outputCharacters: Int
        public let elapsedMilliseconds: Int

        enum CodingKeys: String, CodingKey {
            case outputCharacters = "output_characters"
            case elapsedMilliseconds = "elapsed_ms"
        }
    }

    public let v: Int
    public let kind: String
    public let requestId: String
    public var runtime: String?
    public var text: String?
    public var usage: Usage?
    public var loadMilliseconds: Int?
    public var error: String?
    public var cache: String?

    enum CodingKeys: String, CodingKey {
        case v, kind, runtime, text, usage, error, cache
        case requestId = "request_id"
        case loadMilliseconds = "load_ms"
    }
}

public actor ProtocolWriter {
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    public init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    public func send(_ response: MlxWorkerResponse) {
        do {
            var data = try encoder.encode(response)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            WorkerLog.write("could not write protocol response: \(error)")
        }
    }
}

public enum WorkerLog {
    public static func write(_ message: String) {
        let line = "afterray-mlx-vlm-worker: \(message)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}

actor MlxModelRuntime {
    private(set) var container: ModelContainer?
    private var activeTask: Task<Void, Never>?
    private var activeRequestId: String?
    private var cachedSession: ChatSession?
    private var cachedInstructions: String?

    func load(modelDirectory: URL) async throws -> Int {
        guard container == nil else { return 0 }
        try validateLocalSnapshot(modelDirectory)
        let clock = ContinuousClock()
        let started = clock.now
        let configuration = ModelConfiguration(directory: modelDirectory)
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        )
        container = loaded
        let duration = started.duration(to: clock.now)
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    func startGenerate(_ request: MlxWorkerRequest, writer: ProtocolWriter) async {
        guard activeTask == nil else {
            await writer.send(.init(
                v: mlxWorkerProtocolVersion,
                kind: "error",
                requestId: request.requestId,
                error: "only one generate request may run at a time"
            ))
            return
        }
        guard container != nil else {
            await writer.send(.init(
                v: mlxWorkerProtocolVersion,
                kind: "error",
                requestId: request.requestId,
                error: "load must complete before generate"
            ))
            return
        }
        activeRequestId = request.requestId
        activeTask = Task { [weak self] in
            await self?.generate(request, writer: writer)
        }
    }

    func cancel(requestId: String, writer: ProtocolWriter) async {
        guard activeRequestId == requestId, let activeTask else {
            await writer.send(.init(
                v: mlxWorkerProtocolVersion,
                kind: "error",
                requestId: requestId,
                error: "request is not active"
            ))
            return
        }
        activeTask.cancel()
        // Do not acknowledge cancellation until MLX has stopped consuming the
        // session's cache. Starting another request first can race the VLM
        // processor and was the shape of the Qwen3.5 cache regression.
        await activeTask.value
        self.activeTask = nil
        activeRequestId = nil
        await writer.send(.init(
            v: mlxWorkerProtocolVersion,
            kind: "cancelled",
            requestId: requestId
        ))
    }

    func containerForRegression() throws -> ModelContainer {
        guard let container else {
            throw WorkerFailure("model is not loaded")
        }
        return container
    }

    private func generate(_ request: MlxWorkerRequest, writer: ProtocolWriter) async {
        do {
            guard let container else { throw WorkerFailure("model is not loaded") }
            let messages = request.messages ?? []
            let instructions = messages.first(where: { $0.role == "system" })?.content
            guard let prompt = messages.last(where: { $0.role == "user" })?.content,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw WorkerFailure("generate requires a non-empty user message") }
            let parameters = GenerateParameters(
                maxTokens: max(1, min(request.maxTokens ?? 512, 4_096)),
                temperature: 0
            )
            let session: ChatSession
            let cacheMode: String
            if request.useKvCache == true,
               cachedInstructions == instructions,
               let cachedSession
            {
                session = cachedSession
                cacheMode = "reused"
            } else {
                session = ChatSession(
                    container,
                    instructions: instructions,
                    generateParameters: parameters,
                    additionalContext: ["enable_thinking": false]
                )
                cacheMode = "full_prefill"
                if request.useKvCache == true {
                    cachedSession = session
                    cachedInstructions = instructions
                }
            }
            let imageInputs = try (request.images ?? []).map { path -> UserInput.Image in
                let url = URL(fileURLWithPath: path)
                guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                    throw WorkerFailure("image does not exist: \(path)")
                }
                return .url(url)
            }
            let clock = ContinuousClock()
            let started = clock.now
            var raw = ""
            var emitted = ""
            for try await item in session.streamDetails(to: prompt, images: imageInputs) {
                try Task.checkCancellation()
                if case .chunk(let chunk) = item {
                    raw += chunk
                    let visible = normalizeModelOutput(raw)
                    if visible.hasPrefix(emitted) {
                        let delta = String(visible.dropFirst(emitted.count))
                        if !delta.isEmpty {
                            emitted = visible
                            await writer.send(.init(
                                v: mlxWorkerProtocolVersion,
                                kind: "delta",
                                requestId: request.requestId,
                                text: delta
                            ))
                        }
                    }
                }
            }
            try Task.checkCancellation()
            let final = normalizeModelOutput(raw)
            guard !final.isEmpty else { throw WorkerFailure("model returned empty output") }
            let duration = started.duration(to: clock.now)
            let elapsed = Int(duration.components.seconds * 1_000)
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
            await writer.send(.init(
                v: mlxWorkerProtocolVersion,
                kind: "final",
                requestId: request.requestId,
                text: final,
                usage: .init(outputCharacters: final.count, elapsedMilliseconds: elapsed),
                cache: cacheMode
            ))
        } catch is CancellationError {
            // The cancel request emits the sole terminal protocol event.
        } catch {
            if !Task.isCancelled {
                await writer.send(.init(
                    v: mlxWorkerProtocolVersion,
                    kind: "error",
                    requestId: request.requestId,
                    error: error.localizedDescription
                ))
            }
        }
        if activeRequestId == request.requestId {
            activeTask = nil
            activeRequestId = nil
        }
    }
}

public actor MlxWorker {
    private let runtime = MlxModelRuntime()
    private let writer: ProtocolWriter

    public init(writer: ProtocolWriter = ProtocolWriter()) {
        self.writer = writer
    }

    public func accept(line: String) async {
        let request: MlxWorkerRequest
        do {
            request = try JSONDecoder().decode(MlxWorkerRequest.self, from: Data(line.utf8))
        } catch {
            WorkerLog.write("ignored malformed stdin: \(error)")
            return
        }
        guard request.v == mlxWorkerProtocolVersion else {
            await writer.send(.init(
                v: mlxWorkerProtocolVersion,
                kind: "error",
                requestId: request.requestId,
                error: "unsupported protocol version \(request.v)"
            ))
            return
        }
        switch request.kind {
        case "load":
            guard let modelDir = request.modelDir else {
                await writer.send(.init(
                    v: mlxWorkerProtocolVersion,
                    kind: "error",
                    requestId: request.requestId,
                    error: "load requires model_dir"
                ))
                return
            }
            do {
                let milliseconds = try await runtime.load(
                    modelDirectory: URL(fileURLWithPath: modelDir, isDirectory: true)
                )
                await writer.send(.init(
                    v: mlxWorkerProtocolVersion,
                    kind: "ready",
                    requestId: request.requestId,
                    runtime: mlxRuntimeVersion,
                    loadMilliseconds: milliseconds
                ))
            } catch {
                await writer.send(.init(
                    v: mlxWorkerProtocolVersion,
                    kind: "error",
                    requestId: request.requestId,
                    error: error.localizedDescription
                ))
            }
        case "generate":
            await runtime.startGenerate(request, writer: writer)
        case "cancel":
            await runtime.cancel(requestId: request.requestId, writer: writer)
        default:
            await writer.send(.init(
                v: mlxWorkerProtocolVersion,
                kind: "error",
                requestId: request.requestId,
                error: "unknown request kind \(request.kind)"
            ))
        }
    }
}

struct WorkerFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

func validateLocalSnapshot(_ directory: URL) throws {
    let manager = FileManager.default
    let required = [
        ".afterray-ready.json",
        "chat_template.jinja",
        "config.json",
        "model.safetensors.index.json",
        "preprocessor_config.json",
        "processor_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
        "video_preprocessor_config.json",
        "vocab.json",
    ]
    for name in required where !manager.fileExists(
        atPath: directory.appendingPathComponent(name).path
    ) {
        throw WorkerFailure("model snapshot is missing \(name)")
    }
    let markerData = try Data(contentsOf: directory.appendingPathComponent(".afterray-ready.json"))
    let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: Any]
    guard let revision = marker?["revision"] as? String,
          [qwen35_4BRevision, qwen35_9BRevision].contains(revision),
          marker?["verified"] as? Bool == true
    else { throw WorkerFailure("model snapshot ready marker has the wrong revision") }
    let has4BWeights = manager.fileExists(
        atPath: directory.appendingPathComponent("model.safetensors").path
    )
    let has9BWeights = manager.fileExists(
        atPath: directory.appendingPathComponent("model-00001-of-00002.safetensors").path
    ) && manager.fileExists(
        atPath: directory.appendingPathComponent("model-00002-of-00002.safetensors").path
    )
    guard (revision == qwen35_4BRevision && has4BWeights)
        || (revision == qwen35_9BRevision && has9BWeights)
    else { throw WorkerFailure("model snapshot weights do not match its pinned revision") }
    let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
    let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
    guard config?["model_type"] as? String == "qwen3_5" else {
        throw WorkerFailure("model is not a Qwen3.5 VLM snapshot")
    }
}

public func normalizeModelOutput(_ text: String) -> String {
    var result = text
    while let start = result.range(of: "<think>") {
        guard let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) else {
            result.removeSubrange(start.lowerBound..<result.endIndex)
            break
        }
        result.removeSubrange(start.lowerBound..<end.upperBound)
    }
    for token in [
        "<|im_start|>", "<|im_end|>", "<|endoftext|>",
        "<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>",
    ] {
        result = result.replacingOccurrences(of: token, with: "")
    }
    if let trailing = result.lastIndex(of: "<") {
        let suffix = result[trailing...]
        let controlTokens = [
            "<think>", "</think>", "<|im_start|>", "<|im_end|>", "<|endoftext|>",
            "<|vision_start|>", "<|vision_end|>", "<|image_pad|>", "<|video_pad|>",
        ]
        if controlTokens.contains(where: { $0.hasPrefix(suffix) }) {
            result.removeSubrange(trailing..<result.endIndex)
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
