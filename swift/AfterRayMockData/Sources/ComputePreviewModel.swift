import AfterRayRecall
import Foundation

/// Fixture driver for the local-computation dashboard, so the Visual Lab and
/// previews can render it without a daemon.
///
/// The default fixture is deliberately the awkward case rather than the happy
/// one: on battery, one thing running, summaries held with a real reason, and a
/// model resident in memory doing nothing. A panel that only ever gets designed
/// against "everything is fine" is the panel that reads badly on the day
/// somebody actually opens it.
@MainActor
public final class ComputePreviewModel: ObservableObject, ComputeActivityPresenting {
    @Published public private(set) var status: ComputeStatus
    @Published public private(set) var message: String?
    @Published public private(set) var isApplying = false
    @Published public private(set) var tick = Date()

    public init(status: ComputeStatus? = nil) {
        self.status = status ?? ComputeFixtures.onBattery
    }

    public var indicator: ComputeIndicator {
        ComputeIndicator(status: status, now: tick)
    }

    public func startWatching() {}
    public func stopWatching() {}

    public func runNow(_ workload: ComputeWorkload) async {
        let forced = Int64(Date().timeIntervalSince1970 * 1000) + 1_800_000
        var next = status
        next.pausedUntilMs = nil
        next.gates = next.gates.map { gate in
            guard gate.workload == workload else { return gate }
            return ComputeGate(
                workload: gate.workload,
                allowed: true,
                code: .allowed,
                pending: gate.pending,
                backlog: gate.backlog,
                forcedUntilMs: forced
            )
        }
        publish(next)
    }

    public func setMode(_ mode: ComputeMode) async {
        var next = status
        next.mode = mode
        next.running = mode == .off ? [] : next.running
        publish(next)
    }

    public func togglePause() async {
        var next = status
        next.pausedUntilMs = status.isPaused(now: Date())
            ? nil
            : Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        publish(next)
    }

    private func publish(_ next: ComputeStatus) {
        status = next
        tick = Date()
    }
}

/// Fixture reports, outside the main actor so they can be used as default
/// arguments and from previews.
public enum ComputeFixtures {
    /// Unplugged, mid-transcription, summaries waiting for power.
    public static var onBattery: ComputeStatus {
        ComputeStatus(
            mode: .full,
            running: [
                ComputeTask(
                    id: "job-asr",
                    workload: .asr,
                    lane: .gpu,
                    detail: "qwen3-asr",
                    startedAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 42_000,
                    cpuPercent: 186.4,
                    footprintBytes: 1_610_612_736
                ),
            ],
            gates: [
                ComputeGate(workload: .ocr, allowed: true, code: .allowed, pending: 2, backlog: 6),
                ComputeGate(
                    workload: .asr,
                    allowed: true,
                    code: .allowed,
                    pending: 1,
                    backlog: 7,
                    canRunNow: true
                ),
                ComputeGate(workload: .embedding, allowed: true, code: .allowed),
                ComputeGate(
                    workload: .summary,
                    allowed: false,
                    code: .onBattery,
                    reason: "on battery — summaries wait for power",
                    backlog: 23,
                    canRunNow: true
                ),
                ComputeGate(
                    workload: .archive,
                    allowed: false,
                    code: .onBattery,
                    reason: "on battery — compression waits for power",
                    backlog: 1_412,
                    canRunNow: true
                ),
            ],
            machine: ComputeMachine(
                onAc: false,
                batteryFraction: 0.46,
                idleSeconds: 3,
                loadPerCore: 1.18,
                thermalLevel: 1,
                daemonCpuPercent: 22.5,
                daemonFootprintBytes: 903_872_512
            ),
            residentModels: [
                ComputeResidentModel(
                    packId: "qwen35-4b-mlx",
                    name: "mlx-qwen3.5-4b",
                    pid: 4321,
                    footprintBytes: 5_368_709_120,
                    cpuPercent: 0.0
                ),
            ],
            recentSummaries: recentSummaries,
            summaryTypicalMs: 164_000,
            capturePaused: true
        )
    }

    /// Plugged in and compressing — the case where the CPU lane matters.
    public static var archiving: ComputeStatus {
        ComputeStatus(
            mode: .full,
            running: [
                ComputeTask(
                    id: "gop-packer",
                    workload: .archive,
                    lane: .cpu,
                    detail: "rav1e (in the daemon)",
                    startedAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 8_000
                ),
            ],
            gates: allAllowed,
            machine: ComputeMachine(
                onAc: true,
                batteryFraction: 0.98,
                idleSeconds: 640,
                loadPerCore: 0.42,
                daemonCpuPercent: 388.0,
                daemonFootprintBytes: 1_207_959_552
            ),
            recentSummaries: recentSummaries,
            summaryTypicalMs: 164_000
        )
    }

    /// A summary already running, so the "about N left" estimate is visible.
    public static var summarising: ComputeStatus {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return ComputeStatus(
            mode: .full,
            running: [
                ComputeTask(
                    id: "job-t2",
                    workload: .summary,
                    lane: .gpu,
                    detail: "qwen35-4b-mlx",
                    startedAtMs: now - 96_000,
                    cpuPercent: 291.0,
                    footprintBytes: 5_368_709_120
                ),
            ],
            gates: allAllowed,
            machine: ComputeMachine(
                onAc: true,
                batteryFraction: 1.0,
                idleSeconds: 320,
                loadPerCore: 0.61,
                daemonCpuPercent: 18.0,
                daemonFootprintBytes: 964_689_920
            ),
            residentModels: [
                ComputeResidentModel(
                    packId: "qwen35-4b-mlx",
                    name: "mlx-qwen3.5-4b",
                    pid: 4321,
                    footprintBytes: 5_368_709_120,
                    cpuPercent: 288.5
                ),
            ],
            recentSummaries: recentSummaries,
            summaryTypicalMs: 164_000
        )
    }

    /// A spread wide enough that the median matters — including one pass that
    /// gave up, so the failed row gets designed too.
    public static var recentSummaries: [ComputeRun] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return [
            ComputeRun(slotStartMs: now - 600_000, finishedAtMs: now - 240_000, durationMs: 164_000),
            ComputeRun(slotStartMs: now - 1_200_000, finishedAtMs: now - 900_000, durationMs: 402_000),
            ComputeRun(
                slotStartMs: now - 1_800_000,
                finishedAtMs: now - 1_500_000,
                durationMs: 11_000,
                ok: false
            ),
            ComputeRun(slotStartMs: now - 2_400_000, finishedAtMs: now - 2_100_000, durationMs: 151_000),
            ComputeRun(slotStartMs: now - 3_000_000, finishedAtMs: now - 2_700_000, durationMs: 178_000),
        ]
    }

    public static let allAllowed: [ComputeGate] = [
        ComputeGate(workload: .ocr, allowed: true, code: .allowed),
        ComputeGate(workload: .asr, allowed: true, code: .allowed),
        ComputeGate(workload: .embedding, allowed: true, code: .allowed),
        ComputeGate(workload: .summary, allowed: true, code: .allowed),
        ComputeGate(workload: .archive, allowed: true, code: .allowed),
    ]
}
