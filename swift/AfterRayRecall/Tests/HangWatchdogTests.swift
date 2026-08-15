import XCTest
@testable import AfterRayRecall

final class HangWatchdogTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_786_000_000)

    private func advance(_ seconds: TimeInterval) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    func testResponsiveMainThreadNeverTriggers() {
        var judge = HangJudge(sampleAfter: 5, terminateAfter: 12)
        for second in 0..<60 {
            let now = advance(TimeInterval(second))
            // Heartbeat is always fresh (0.4s ago).
            let action = judge.assess(
                now: now,
                lastHeartbeat: now.addingTimeInterval(-0.4),
                overlayVisible: true
            )
            XCTAssertEqual(action, .none, "false positive at t=\(second)")
        }
    }

    func testStallSamplesOnceThenTerminatesWhenOverlayIsUp() {
        var judge = HangJudge(sampleAfter: 5, terminateAfter: 12)
        let beat = epoch

        XCTAssertEqual(judge.assess(now: advance(4.9), lastHeartbeat: beat, overlayVisible: true), .none)
        XCTAssertEqual(
            judge.assess(now: advance(5.5), lastHeartbeat: beat, overlayVisible: true),
            .sample,
            "first crossing of the sample threshold must capture stacks"
        )
        XCTAssertEqual(
            judge.assess(now: advance(8), lastHeartbeat: beat, overlayVisible: true),
            .none,
            "one sample per incident — the report is already being written"
        )
        XCTAssertEqual(
            judge.assess(now: advance(12.5), lastHeartbeat: beat, overlayVisible: true),
            .terminate
        )
    }

    /// A hung faceless app is a bug to log, not a reason to kill the process:
    /// nothing is covering the screen, and dying would also kill capture.
    func testHiddenOverlayNeverTerminates() {
        var judge = HangJudge(sampleAfter: 5, terminateAfter: 12)
        let beat = epoch
        XCTAssertEqual(judge.assess(now: advance(6), lastHeartbeat: beat, overlayVisible: false), .sample)
        for second in [13.0, 30, 300, 3_600] {
            XCTAssertEqual(
                judge.assess(now: advance(second), lastHeartbeat: beat, overlayVisible: false),
                .none,
                "terminate must require the overlay at t=\(second)"
            )
        }
    }

    func testRecoveryRearmsTheSampler() {
        var judge = HangJudge(sampleAfter: 5, terminateAfter: 12)
        XCTAssertEqual(judge.assess(now: advance(6), lastHeartbeat: epoch, overlayVisible: true), .sample)
        // Main thread recovers: heartbeat fresh again.
        XCTAssertEqual(
            judge.assess(now: advance(10), lastHeartbeat: advance(9.8), overlayVisible: true),
            .none
        )
        // A second incident later must sample again.
        XCTAssertEqual(
            judge.assess(now: advance(20), lastHeartbeat: advance(9.8), overlayVisible: true),
            .sample
        )
    }

    func testOverlayVisibilityMirror() {
        let visibility = OverlayVisibility()
        XCTAssertFalse(visibility.isVisible)
        visibility.set(true)
        XCTAssertTrue(visibility.isVisible)
        visibility.set(false)
        XCTAssertFalse(visibility.isVisible)
    }
}

final class DaemonTimeoutTests: XCTestCase {
    /// A daemon that accepts the connection and then never answers used to
    /// park the caller in a blocking read forever; every await upstream froze
    /// with it. The unary path now trips its receive deadline instead.
    func testUnaryExchangeTimesOutAgainstASilentServer() throws {
        let path = NSTemporaryDirectory() + "afterray-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            _ = path.utf8CString.withUnsafeBytes { source in
                destination.copyBytes(from: source.prefix(destination.count))
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        // Accept in the background and hold the connection open, silently.
        let silent = Thread {
            let connection = accept(listener, nil, nil)
            Thread.sleep(forTimeInterval: 10)
            if connection >= 0 { close(connection) }
        }
        silent.start()

        let started = Date()
        XCTAssertThrowsError(
            try UnixLineTransport.exchange(
                path: path,
                payload: Data("{\"type\":\"ping\"}\n".utf8),
                receiveTimeout: 1
            )
        ) { error in
            XCTAssertTrue(
                "\(error)".contains("did not respond"),
                "timeout must be named, got: \(error)"
            )
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5, "deadline must fire near 1s, took \(elapsed)s")
    }
}
