import Foundation
import MLXAudioCore
import MLXAudioSTT

private let workerProtocolVersion = 2

private struct WorkerRequest: Decodable {
    let protocolVersion: Int
    let capability: String
    let input: Input

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case capability, input
    }
}

private struct Input: Decodable {
    let type: String
    let audioPath: String?

    enum CodingKeys: String, CodingKey {
        case type
        case audioPath = "audio_path"
    }
}

private struct WorkerResponse: Encodable {
    let protocolVersion: Int
    let output: AsrOutput?
    let error: String?
    let retryable: Bool

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case output, error, retryable
    }
}

private struct AsrOutput: Encodable {
    let type = "asr"
    let text: String
    let language: String?
}

@main
enum AfterRayMlxAsrWorker {
    static func main() async {
        do {
            let request = try decodeRequest()
            guard request.protocolVersion == workerProtocolVersion else {
                try write(WorkerResponse(
                    protocolVersion: workerProtocolVersion,
                    output: nil,
                    error: "unsupported worker protocol \(request.protocolVersion)",
                    retryable: false
                ))
                return
            }
            guard request.capability == "asr", request.input.type == "asr",
                  let audioPath = request.input.audioPath, !audioPath.isEmpty
            else {
                try write(WorkerResponse(
                    protocolVersion: workerProtocolVersion,
                    output: nil,
                    error: "MLX ASR worker accepts only an ASR audio request",
                    retryable: false
                ))
                return
            }
            let modelDirectory = try localModelDirectory()
            let audioURL = URL(fileURLWithPath: audioPath)
            guard FileManager.default.isReadableFile(atPath: audioURL.path) else {
                throw WorkerFailure.missing("audio input is not readable")
            }
            let (sampleRate, audio) = try loadAudioArray(from: audioURL)
            _ = sampleRate
            let model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
            let started = ContinuousClock.now
            let result = model.generate(audio: audio, language: nil)
            let elapsed = started.duration(to: .now)
            log("transcribed \(result.text.count) chars in \(elapsed)")
            try write(WorkerResponse(
                protocolVersion: workerProtocolVersion,
                output: AsrOutput(text: result.text, language: result.language),
                error: nil,
                retryable: false
            ))
        } catch let failure as WorkerFailure {
            writeBestEffort(failure.message, retryable: false)
        } catch {
            log("ASR failed: \(error)")
            writeBestEffort("MLX ASR failed: \(error)", retryable: true)
        }
    }

    private static func decodeRequest() throws -> WorkerRequest {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { throw WorkerFailure.missing("worker request is empty") }
        return try JSONDecoder().decode(WorkerRequest.self, from: data)
    }

    private static func localModelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["AFTERRAY_ASR_MODEL"], !path.isEmpty else {
            throw WorkerFailure.missing("AFTERRAY_ASR_MODEL is not set")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let config = directory.appendingPathComponent("config.json")
        let marker = directory.appendingPathComponent(".afterray-ready.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw WorkerFailure.missing("ASR model is not verified by AfterRay")
        }
        guard FileManager.default.fileExists(atPath: tokenizer.path) else {
            throw WorkerFailure.missing("ASR model tokenizer.json is missing")
        }
        let data = try Data(contentsOf: config)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["model_type"] as? String == "qwen3_asr" else {
            throw WorkerFailure.missing("ASR model is not an MLX Qwen3 ASR snapshot")
        }
        return directory
    }

    private static func write(_ response: WorkerResponse) throws {
        let encoded = try JSONEncoder().encode(response)
        FileHandle.standardOutput.write(encoded)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeBestEffort(_ error: String, retryable: Bool) {
        do {
            try write(WorkerResponse(
                protocolVersion: workerProtocolVersion,
                output: nil,
                error: error,
                retryable: retryable
            ))
        } catch {
            log("could not write worker response: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct WorkerFailure: Error {
    let message: String

    static func missing(_ message: String) -> WorkerFailure { WorkerFailure(message: message) }
}
