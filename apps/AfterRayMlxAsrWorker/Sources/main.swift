import AVFoundation
import Foundation
import MLX
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
                    let audio = try loadAudioForASR(from: audioURL)
                    log(
                        "audio duration \(String(format: "%.3f", audioDurationSeconds(audio)))s at 16 kHz"
                    )
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

    private static let asrSampleRate = 16_000

    // Qwen3 ASR derives duration from sample count at 16 kHz. Capture files
    // are commonly 48 kHz stereo AAC, so a one-shot converter that drops the
    // tail — or a load that skips resampling — makes a five-minute clip look
    // like fifteen minutes, or like a few hundred milliseconds.
    // @dec:mlx-asr-runtime — docs/decisions/active/architecture/2026-08-25-mlx-asr-runtime.md
    private static func loadAudioForASR(from url: URL) throws -> MLXArray {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else {
            throw WorkerFailure.invalid("audio input has no sample frames")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw WorkerFailure.invalid("could not allocate an audio buffer")
        }
        try file.read(into: buffer)
        let sourceRate = Int(format.sampleRate.rounded())
        guard sourceRate > 0 else {
            throw WorkerFailure.invalid("audio input has no sample rate")
        }
        let mono = try monoSamples(from: buffer)
        let resampled = try resampleMono(mono, from: sourceRate, to: asrSampleRate)
        let expected = resampledFrameCount(sourceFrames: mono.count, sourceRate: sourceRate, targetRate: asrSampleRate)
        let slop = max(expected / 50, asrSampleRate / 10)
        guard abs(resampled.count - expected) <= slop else {
            throw WorkerFailure.invalid(
                "resampled audio is \(resampled.count) samples at \(asrSampleRate) Hz, expected \(expected) from \(mono.count) frames at \(sourceRate) Hz"
            )
        }
        var samples = resampled
        if samples.count > expected {
            samples.removeLast(samples.count - expected)
        } else if samples.count < expected {
            samples.append(contentsOf: repeatElement(Float(0), count: expected - samples.count))
        }
        let audio = MLXArray(samples)
        if audio.ndim == 1 {
            return audio
        }
        return audio.reshaped([samples.count])
    }

    private static func audioDurationSeconds(_ audio: MLXArray) -> Double {
        let axis = max(audio.ndim - 1, 0)
        return Double(audio.dim(axis)) / Double(asrSampleRate)
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else {
            throw WorkerFailure.invalid("audio buffer has no samples")
        }
        let channelCount = min(max(Int(buffer.format.channelCount), 1), 8)
        if buffer.format.isInterleaved {
            let source = channels[0]
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: source, count: frames))
            }
            var mono = [Float](repeating: 0, count: frames)
            let scale = 1 / Float(channelCount)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += source[frame * channelCount + channel]
                }
                mono[frame] = sum * scale
            }
            return mono
        }
        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channelCount)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            mono[frame] = sum * scale
        }
        return mono
    }

    private static func resampleMono(
        _ samples: [Float],
        from sourceSampleRate: Int,
        to targetSampleRate: Int
    ) throws -> [Float] {
        if samples.isEmpty || sourceSampleRate == targetSampleRate {
            return samples
        }
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceSampleRate),
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw WorkerFailure.invalid("could not create an audio resampler")
        }
        let provider = try ChunkedPCMProvider(samples: samples, format: inputFormat)
        var output = [Float]()
        output.reserveCapacity(resampledFrameCount(
            sourceFrames: samples.count,
            sourceRate: sourceSampleRate,
            targetRate: targetSampleRate
        ) + targetSampleRate)
        var finished = false
        var iterations = 0
        while !finished {
            iterations += 1
            if iterations > 1_000_000 {
                throw WorkerFailure.invalid("audio resampling did not finish")
            }
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: 8_192
            ) else {
                throw WorkerFailure.invalid("could not allocate a resample buffer")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, status in
                provider.pull(status)
            }
            if let conversionError {
                throw WorkerFailure.invalid("audio resampling failed: \(conversionError.localizedDescription)")
            }
            if outBuffer.frameLength > 0, let data = outBuffer.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(outBuffer.frameLength)))
            }
            switch status {
            case .endOfStream:
                finished = true
            case .error:
                throw WorkerFailure.invalid("audio resampling failed")
            default:
                continue
            }
        }
        return output
    }

    private static func resampledFrameCount(sourceFrames: Int, sourceRate: Int, targetRate: Int) -> Int {
        Int((Double(sourceFrames) * Double(targetRate) / Double(sourceRate)).rounded())
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

private final class ChunkedPCMProvider: @unchecked Sendable {
    private let samples: [Float]
    private let buffer: AVAudioPCMBuffer
    private var offset = 0

    init(samples: [Float], format: AVAudioFormat) throws {
        self.samples = samples
        let capacity = AVAudioFrameCount(max(min(samples.count, 4_096), 1))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw WorkerFailure.invalid("could not allocate a PCM provider buffer")
        }
        self.buffer = buffer
    }

    func pull(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if offset >= samples.count {
            status.pointee = .endOfStream
            return nil
        }
        let count = min(Int(buffer.frameCapacity), samples.count - offset)
        buffer.frameLength = AVAudioFrameCount(count)
        samples[offset..<(offset + count)].withUnsafeBufferPointer { source in
            guard let base = source.baseAddress, let destination = buffer.floatChannelData?[0] else {
                return
            }
            destination.update(from: base, count: count)
        }
        offset += count
        status.pointee = .haveData
        return buffer
    }
}
