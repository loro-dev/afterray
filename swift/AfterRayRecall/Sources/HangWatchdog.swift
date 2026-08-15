import Foundation

/// Thread-safe mirror of "is the full-screen overlay up". The watchdog must
/// read this from its own thread while the main thread may be dead, so it
/// cannot ask AppKit — window state is main-thread-only by contract.
public final class OverlayVisibility: @unchecked Sendable {
    public static let shared = OverlayVisibility()
    private let lock = NSLock()
    private var visible = false

    public func set(_ isVisible: Bool) {
        lock.lock()
        visible = isVisible
        lock.unlock()
    }

    public var isVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible
    }
}

/// Decides what to do about a stalled main thread. Pure — the thresholds and
/// the one-shot bookkeeping are the part of a watchdog that must not be
/// wrong, so they live where a test can drive them with a fake clock.
///
/// Stages:
/// 1. `sample` once per incident after `sampleAfter`: capture every thread's
///    stack while the hang is still happening. The record is the point — a
///    hang that kills the app without a stack teaches nothing.
/// 2. `terminate` after `terminateAfter`, but only while the overlay is up.
///    A hung faceless app is a bug; a hung full-screen overlay at status-bar
///    level is a locked screen the user cannot escape — process death is the
///    only exit that does not require the dead main thread to cooperate.
public struct HangJudge {
    public enum Action: Equatable {
        case none
        case sample
        case terminate
    }

    public let sampleAfter: TimeInterval
    public let terminateAfter: TimeInterval
    private var sampledThisIncident = false

    public init(sampleAfter: TimeInterval = 5, terminateAfter: TimeInterval = 12) {
        self.sampleAfter = sampleAfter
        self.terminateAfter = terminateAfter
    }

    public mutating func assess(
        now: Date,
        lastHeartbeat: Date,
        overlayVisible: Bool
    ) -> Action {
        let stall = now.timeIntervalSince(lastHeartbeat)
        if stall < sampleAfter {
            sampledThisIncident = false // responsive again: re-arm
            return .none
        }
        if stall >= terminateAfter, overlayVisible {
            return .terminate
        }
        if !sampledThisIncident {
            sampledThisIncident = true
            return .sample
        }
        return .none
    }
}

/// Watches the main thread from a plain background `Thread` — deliberately
/// not a dispatch queue or a Task, because the runtime being watched must
/// not be able to starve the watcher.
public final class HangWatchdog: @unchecked Sendable {
    public static let shared = HangWatchdog()

    private let lock = NSLock()
    private var lastHeartbeat = Date()
    private var started = false

    /// Interval between heartbeat probes; also the detection resolution.
    private let probeInterval: useconds_t = 500_000

    public func start(logDirectory: URL) {
        lock.lock()
        defer { lock.unlock() }
        if started { return }
        started = true

        let thread = Thread { [weak self] in
            self?.run(logDirectory: logDirectory)
        }
        thread.name = "afterray-hang-watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func beat() {
        lock.lock()
        lastHeartbeat = Date()
        lock.unlock()
    }

    private var heartbeat: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastHeartbeat
    }

    private func run(logDirectory: URL) {
        var judge = HangJudge()
        // Seed one beat so launch time does not count as a stall.
        beat()
        while true {
            DispatchQueue.main.async { [weak self] in self?.beat() }
            usleep(probeInterval)
            let action = judge.assess(
                now: Date(),
                lastHeartbeat: heartbeat,
                overlayVisible: OverlayVisibility.shared.isVisible
            )
            switch action {
            case .none:
                continue
            case .sample:
                captureHangReport(logDirectory: logDirectory)
            case .terminate:
                AfterRayLog.error(
                    "hang-watchdog: main thread unresponsive with the overlay up; "
                        + "terminating so the screen is released"
                )
                // `_exit`, not `exit`: atexit handlers may need the very
                // main thread that is dead. The log write above is already
                // synchronous and on disk.
                _exit(70)
            }
        }
    }

    /// `/usr/bin/sample` inspects the process from outside, so it works on
    /// the hung target even though we spawn it from within. Its report names
    /// the exact frame every thread — including the dead main — is stuck in.
    private func captureHangReport(logDirectory: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let report = logDirectory.appendingPathComponent("hang-\(stamp).txt")
        AfterRayLog.error(
            "hang-watchdog: main thread stalled >5s (overlay visible: "
                + "\(OverlayVisibility.shared.isVisible)); sampling to \(report.lastPathComponent)"
        )
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-file", report.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        try? sample.run()
        sample.waitUntilExit()
    }
}
