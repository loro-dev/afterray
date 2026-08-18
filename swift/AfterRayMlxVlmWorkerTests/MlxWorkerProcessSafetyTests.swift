import Foundation
import MLX
import Testing

@testable import AfterRayMlxVlmWorkerCore

// The metallib built by scripts/build-mlx-metallib.sh. mlx loads it from the
// directory of the image its code is linked into (dladdr-based); in
// `swift test` that is the xctest bundle binary, not Bundle.main (which is
// the toolchain's test runner inside Xcode.app), so resolve it the same way
// via #dsohandle and copy the metallib there before touching MLX.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // AfterRayMlxVlmWorkerTests
    .deletingLastPathComponent() // swift
    .deletingLastPathComponent() // repo root
private let builtMetallib = repoRoot
    .appending(path: ".build/mlx-metallib/mlx.metallib")

private func testImageDirectory() -> URL {
    var info = Dl_info()
    dladdr(#dsohandle, &info)
    return URL(fileURLWithPath: String(cString: info.dli_fname))
        .deletingLastPathComponent()
}

@Suite("MLX worker process safety")
struct MlxWorkerProcessSafetyTests {
    @Test("unscoped MLX errors reach the installed sink instead of stdout")
    func unscopedMlxErrorReachesSink() {
        let recorder = MessageRecorder()
        installMlxErrorHandler(sink: { message in recorder.append(message) })

        // A broadcast mismatch raises in MLX outside any `withError` scope.
        // mlx-c's default handler would print `MLX error: ...` to stdout —
        // corrupting the worker's protocol channel — and then exit(-1).
        let a = MLXArray(0 ..< 10, [2, 5])
        let b = MLXArray(0 ..< 15, [3, 5])
        _ = a + b

        #expect(!recorder.messages.isEmpty)
    }

    @Test(
        "colocated mlx.metallib loads the Metal default library",
        .enabled(
            if: FileManager.default.fileExists(atPath: builtMetallib.path),
            "Run scripts/build-mlx-metallib.sh first (it runs as part of make v0-build)."
        )
    )
    func colocatedMetallibLoads() throws {
        let destination = testImageDirectory().appending(path: "mlx.metallib")
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: builtMetallib, to: destination)
        }

        // Any GPU op eagerly constructs mlx's Metal device, which throws
        // "Failed to load the default metallib" when the library is missing.
        try withError {
            let sum = MLXArray(1) + MLXArray(1)
            eval(sum)
        }
    }
}

private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}
