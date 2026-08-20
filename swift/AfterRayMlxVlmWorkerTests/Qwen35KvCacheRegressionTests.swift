import CoreImage
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import AfterRayMlxVlmWorkerCore

private let qwen35ModelDirectory = ProcessInfo.processInfo.environment[
    "AFTERRAY_QWEN35_MODEL_DIR"
]

@Suite("Qwen3.5 VLM worker", .serialized)
struct Qwen35KvCacheRegressionTests {
    @Test("normalizes hidden reasoning and control tokens")
    func normalizesModelOutput() {
        #expect(
            normalizeModelOutput("<think>private</think><|im_start|>answer<|im_end|>")
                == "answer"
        )
    }

    @Test("requires the pinned verified snapshot marker")
    func rejectsUnverifiedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try validateLocalSnapshot(directory)
        }
    }

    @Test("accepts the pinned 9B VLM snapshot shape")
    func acceptsPinned9BSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            "chat_template.jinja", "model.safetensors.index.json", "preprocessor_config.json",
            "processor_config.json", "tokenizer.json", "tokenizer_config.json",
            "video_preprocessor_config.json", "vocab.json", "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
        ]
        for file in files {
            try Data().write(to: directory.appendingPathComponent(file))
        }
        try Data("{\"model_type\":\"qwen3_5\"}".utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data("{\"revision\":\"\(qwen35_9BRevision)\",\"verified\":true}".utf8)
            .write(to: directory.appendingPathComponent(".afterray-ready.json"))

        try validateLocalSnapshot(directory)
    }

    @Test(
        "real Qwen3.5 VLM handles continuation, cancellation, and windowed long prefill",
        .enabled(
            if: qwen35ModelDirectory?.isEmpty == false,
            "Set AFTERRAY_QWEN35_MODEL_DIR to a verified AfterRay Qwen3.5 4B or 9B snapshot."
        )
    )
    func realQwen35KvCacheRegression() async throws {
        guard let rawModelDirectory = qwen35ModelDirectory, !rawModelDirectory.isEmpty else { return }

        let runtime = MlxModelRuntime()
        _ = try await runtime.load(modelDirectory: URL(fileURLWithPath: rawModelDirectory))
        let container = try await runtime.containerForRegression()
        let session = ChatSession(
            container,
            instructions: "Answer with only a short description of the input.",
            generateParameters: .init(maxTokens: 24, temperature: 0),
            additionalContext: ["enable_thinking": false]
        )

        let red = solidImage(red: 1, green: 0, blue: 0)
        let blue = solidImage(red: 0, green: 0, blue: 1)

        let first = try await session.respond(
            to: "Describe this image.", image: .ciImage(red)
        )
        #expect(!normalizeModelOutput(first).isEmpty)

        let second = try await session.respond(
            to: "Describe this different image.", image: .ciImage(blue)
        )
        #expect(!normalizeModelOutput(second).isEmpty)

        let textOnly = try await session.respond(to: "Reply with the word ready.")
        #expect(!normalizeModelOutput(textOnly).isEmpty)

        let cancelled = Task {
            for try await _ in session.streamResponse(
                to: "Count slowly from one to one hundred, one number per line."
            ) {
                try Task.checkCancellation()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        _ = try? await cancelled.value

        let afterCancellation = try await session.respond(
            to: "Reply with the word recovered."
        )
        #expect(!normalizeModelOutput(afterCancellation).isEmpty)

        // The old Qwen3.5 prepare path ignored its prefill window. Two prompts
        // of this size on one warm session formed a single float32 attention
        // scratch tensor of roughly 16 heads × 20k queries × 40k keys (> 47 GiB).
        // The pinned runtime must process both in bounded windows.
        let longPrompt = Array(repeating: "memory", count: 20_000).joined(separator: " ")
        let firstLong = try await session.respond(to: longPrompt)
        #expect(!normalizeModelOutput(firstLong).isEmpty)
        let secondLong = try await session.respond(to: longPrompt)
        #expect(!normalizeModelOutput(secondLong).isEmpty)
        // An old unwindowed runtime can still return on a 64 GB machine after
        // allocating its roughly 47 GiB scratch tensor. Bound the MLX peak so
        // that surviving the allocation cannot make this regression pass.
        let maximumPeakBytes = 16 * 1_024 * 1_024 * 1_024
        #expect(
            Memory.peakMemory < maximumPeakBytes,
            "long prefill exceeded the 16 GiB MLX peak-memory budget"
        )
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
}
