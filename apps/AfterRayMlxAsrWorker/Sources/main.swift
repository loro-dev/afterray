import Foundation
import MLXAudioCore
import MLXAudioSTT

private let workerProtocolVersion = 3

private struct WorkerRequest: Decodable {
    let v: Int
    let kind: String
    let requestID: String
    let modelDir: String?
    let audioPath: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case v, kind
        case requestID = "request_id"
        case modelDir = "model_dir"
        case audioPath = "audio_path"
        case language
    }
}

private struct WorkerResponse: Encodable {
    let v = workerProtocolVersion
    let kind: String
    let requestID: String
    let text: String?
    let language: String?
    let runtime: String?
    let error: String?
    let retryable: Bool?

    enum CodingKeys: String, CodingKey {
        case v, kind
        case requestID = "request_id"
        case text, language, runtime, error, retryable
    }
}

private enum WorkerFailure: Error {
    case invalid(String)
    case missing(String)

    var message: String {
        switch self {
        case let .invalid(message), let .missing(message): message
        }
    }
}

@main
enum AfterRayMlxAsrWorker {
    static func main() async {
        var model: Qwen3ASRModel?
        var loadedDirectory: URL?
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let requestID = requestIdentifier(in: line)
            do {
                let request = try JSONDecoder().decode(WorkerRequest.self, from: Data(line.utf8))
                guard request.v == workerProtocolVersion else {
                    throw WorkerFailure.invalid("unsupported worker protocol \(request.v)")
                }
                switch request.kind {
                case "load":
                    guard let directory = request.modelDir, !directory.isEmpty else {
                        throw WorkerFailure.missing("MLX ASR load request has no model directory")
                    }
                    let url = URL(fileURLWithPath: directory)
                    try validateLocalModel(url)
                    if loadedDirectory != url || model == nil {
                        model = try await Qwen3ASRModel.fromModelDirectory(url)
                        loadedDirectory = url
                    }
                    try write(WorkerResponse(
                        kind: "ready", requestID: request.requestID, text: nil, language: nil,
                        runtime: "mlx-audio-swift", error: nil, retryable: nil
                    ))
                // @dec:asr-empty-transcript-results — docs/decisions/active/architecture/2026-08-25-asr-empty-transcript-results.md
                case "asr_generate":
                    guard let model else {
                        throw WorkerFailure.invalid("MLX ASR worker received generation before load")
                    }
                    guard let audioPath = request.audioPath, !audioPath.isEmpty else {
                        throw WorkerFailure.missing("MLX ASR request has no readable audio input")
                    }
                    let audioURL = URL(fileURLWithPath: audioPath)
                    guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
                        throw WorkerFailure.missing("audio input is not readable")
                    }
                    let (_, audio) = try loadAudioArray(from: audioURL)
                    let started = ContinuousClock.now
                    let result = model.generate(audio: audio, language: request.language)
                    log("transcribed \(result.text.count) chars in \(started.duration(to: .now))")
                    try write(WorkerResponse(
                        kind: "final", requestID: request.requestID, text: result.text,
                        language: result.language, runtime: nil, error: nil, retryable: nil
                    ))
                case "cancel":
                    // Rust kills this process when an ASR generation is cancelled:
                    // Qwen3ASRModel.generate is synchronous and cannot safely be
                    // interrupted from a second stdin read.
                    try write(WorkerResponse(
                        kind: "cancelled", requestID: request.requestID, text: nil,
                        language: nil, runtime: nil, error: nil, retryable: nil
                    ))
                default:
                    throw WorkerFailure.invalid("unsupported MLX ASR request kind \(request.kind)")
                }
            } catch let failure as WorkerFailure {
                writeBestEffort(failure.message, requestID: requestID, retryable: false)
            } catch {
                log("ASR failed: \(error)")
                writeBestEffort("MLX ASR failed: \(error)", requestID: requestID, retryable: true)
            }
        }
    }

    private static func validateLocalModel(_ directory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.appendingPathComponent(".afterray-ready.json").path) else {
            throw WorkerFailure.missing("model directory has no AfterRay ready marker")
        }
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        guard manager.isReadableFile(atPath: tokenizer.path) else {
            throw WorkerFailure.missing("model directory has no prepared tokenizer.json")
        }
        let config = directory.appendingPathComponent("config.json")
        let data = try Data(contentsOf: config)
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard value?["model_type"] as? String == "qwen3_asr" else {
            throw WorkerFailure.invalid("model directory is not Qwen3 ASR")
        }
    }

    private static func requestIdentifier(in line: String) -> String {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = value["request_id"] as? String
        else { return "unknown" }
        return identifier
    }

    private static func write(_ response: WorkerResponse) throws {
        let data = try JSONEncoder().encode(response)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeBestEffort(_ error: String, requestID: String, retryable: Bool) {
        try? write(WorkerResponse(
            kind: "error", requestID: requestID, text: nil, language: nil, runtime: nil,
            error: error, retryable: retryable
        ))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("afterray-mlx-asr-worker: \(message)\n".utf8))
    }
}
