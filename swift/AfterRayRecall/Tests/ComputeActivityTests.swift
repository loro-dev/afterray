import Foundation
import XCTest
@testable import AfterRayRecall

final class ComputeActivityTests: XCTestCase {
    /// The exact bytes `afterrayd` sends for `compute_status`. Written out in
    /// full so a field renamed on the Rust side fails here rather than showing
    /// the user an empty dashboard.
    private let daemonPayload = """
    {
      "mode": "essential",
      "paused_until_ms": 1750000060000,
      "running": [
        {
          "id": "job-1",
          "workload": "ocr",
          "lane": "gpu",
          "detail": "vision-ocr",
          "started_at_ms": 1750000000000,
          "cpu_percent": 143.5,
          "footprint_bytes": 268435456
        }
      ],
      "gates": [
        {
          "workload": "summary",
          "allowed": false,
          "code": "on_battery",
          "reason": "on battery — summaries wait for power",
          "pending": 3
        },
        { "workload": "ocr", "allowed": true, "code": "allowed", "pending": 0 }
      ],
      "machine": {
        "on_ac": false,
        "battery_fraction": 0.42,
        "idle_seconds": 4.5,
        "load_per_core": 1.25,
        "thermal_level": 2,
        "daemon_cpu_percent": 12.5,
        "daemon_footprint_bytes": 1073741824
      },
      "resident_models": [
        {
          "pack_id": "qwen35-4b-mlx",
          "name": "mlx-qwen@4b",
          "pid": 4321,
          "footprint_bytes": 5368709120,
          "cpu_percent": 0.0
        }
      ],
      "capture_paused": true
    }
    """

    func testDecodesTheDaemonReport() throws {
        let status = try JSONDecoder().decode(
            ComputeStatus.self,
            from: Data(daemonPayload.utf8)
        )

        XCTAssertEqual(status.mode, .essential)
        XCTAssertEqual(status.pausedUntilMs, 1_750_000_060_000)
        XCTAssertTrue(status.capturePaused)
        XCTAssertEqual(status.running.count, 1)
        XCTAssertEqual(status.running[0].workload, .ocr)
        XCTAssertEqual(status.running[0].lane, .gpu)
        XCTAssertEqual(status.running[0].footprintBytes, 268_435_456)
        XCTAssertEqual(status.pendingTotal, 3)
        XCTAssertEqual(status.machine.batteryFraction, 0.42)
        XCTAssertEqual(status.machine.thermalLevel, 2)
        XCTAssertEqual(status.residentModels.first?.pid, 4321)

        let summary = try XCTUnwrap(status.gates.first { $0.workload == .summary })
        XCTAssertFalse(summary.allowed)
        XCTAssertEqual(summary.code, .onBattery)
        XCTAssertEqual(summary.reason, "on battery — summaries wait for power")
    }

    /// A gate the daemon could not classify must not take the whole dashboard
    /// down with it — an unknown code is a new daemon talking to an old app.
    func testAnUnknownGateCodeFailsThatGateOnly() {
        let json = """
        { "workload": "summary", "allowed": false, "code": "brand_new", "pending": 1 }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ComputeGate.self, from: Data(json.utf8))
        )
        // The protocol version handshake is what actually prevents this pairing;
        // this test pins that we fail loudly rather than silently showing
        // "allowed".
    }

    func testComputeRequestsMatchTheRustShape() throws {
        let status = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WireRequest(type: "compute_status"))
        ) as? [String: Any]
        XCTAssertEqual(status?["type"] as? String, "compute_status")
        XCTAssertEqual(status?.count, 1)

        let mode = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                WireRequest(type: "compute_set_mode", mode: ComputeMode.off.rawValue)
            )
        ) as? [String: Any]
        XCTAssertEqual(mode?["type"] as? String, "compute_set_mode")
        XCTAssertEqual(mode?["mode"] as? String, "off")

        let pause = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WireRequest(type: "compute_pause", pauseSeconds: 3600))
        ) as? [String: Any]
        XCTAssertEqual(pause?["type"] as? String, "compute_pause")
        XCTAssertEqual(pause?["seconds"] as? Int, 3600)
    }

    // MARK: - Indicator

    func testIndicatorPrefersTheUsersOwnChoiceOverBusyness() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let running = [
            ComputeTask(
                id: "j",
                workload: .ocr,
                lane: .gpu,
                detail: "vision-ocr",
                startedAtMs: 1_749_999_999_000
            ),
        ]

        XCTAssertEqual(
            ComputeIndicator(status: ComputeStatus(mode: .off, running: running), now: now),
            .off,
            "switched off outranks anything still draining"
        )
        XCTAssertEqual(
            ComputeIndicator(
                status: ComputeStatus(
                    pausedUntilMs: Int64((now.timeIntervalSince1970 + 1_800) * 1000),
                    running: running
                ),
                now: now
            ),
            .paused(minutesRemaining: 30)
        )
        XCTAssertEqual(
            ComputeIndicator(status: ComputeStatus(running: running), now: now),
            .working(count: 1)
        )
    }

    /// The state that explains a quiet machine: nothing running, work queued,
    /// and a reason the user did not choose.
    func testIndicatorSurfacesAMachineHold() {
        let status = ComputeStatus(
            gates: [
                ComputeGate(
                    workload: .summary,
                    allowed: false,
                    code: .onBattery,
                    reason: "on battery — summaries wait for power",
                    pending: 4
                ),
            ]
        )
        XCTAssertEqual(
            ComputeIndicator(status: status, now: Date()),
            .waiting(reason: "on battery — summaries wait for power")
        )
        XCTAssertTrue(status.isHeldByMachine)
        XCTAssertEqual(status.machineHold?.workload, .summary)
    }

    /// A hold the user chose is not a problem to report back to them.
    func testAUserChosenHoldIsNotSurfacedAsWaiting() {
        let status = ComputeStatus(
            gates: [
                ComputeGate(
                    workload: .summary,
                    allowed: false,
                    code: .modeEssential,
                    reason: "only essential work runs in this mode",
                    pending: 4
                ),
            ]
        )
        XCTAssertEqual(ComputeIndicator(status: status, now: Date()), .idle)
        XCTAssertFalse(status.isHeldByMachine)
        XCTAssertFalse(ComputeIndicator(status: status).isAccented)
    }

    func testAnExpiredPauseReadsAsNotPaused() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let status = ComputeStatus(
            pausedUntilMs: Int64((now.timeIntervalSince1970 - 5) * 1000)
        )
        XCTAssertFalse(status.isPaused(now: now))
        XCTAssertNil(status.pauseMinutesRemaining(now: now))
        XCTAssertEqual(ComputeIndicator(status: status, now: now), .idle)
    }

    /// Rounded up, so the last 40 seconds of a suspension never read as "0 min".
    func testPauseRemainderRoundsUp() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let status = ComputeStatus(
            pausedUntilMs: Int64((now.timeIntervalSince1970 + 61) * 1000)
        )
        XCTAssertEqual(status.pauseMinutesRemaining(now: now), 2)
    }

    // MARK: - Backlog and run now

    func testDecodesBacklogAndForceState() throws {
        let json = """
        {
          "mode": "full",
          "running": [],
          "gates": [
            {
              "workload": "summary",
              "allowed": true,
              "code": "allowed",
              "pending": 1,
              "backlog": 23,
              "forced_until_ms": 1750001800000
            }
          ],
          "machine": {
            "on_ac": false,
            "idle_seconds": 2.0,
            "gpu_utilization": 0.24
          },
          "thresholds": {
            "summary_min_battery_fraction": 0.3,
            "summary_min_idle_seconds": 120.0,
            "summary_max_load_per_core": 0.7,
            "summary_max_gpu_utilization": 0.5,
            "force_window_seconds": 1800
          },
          "resident_models": [],
          "capture_paused": false
        }
        """
        let status = try JSONDecoder().decode(ComputeStatus.self, from: Data(json.utf8))
        let summary = try XCTUnwrap(status.gate(for: .summary))
        XCTAssertEqual(summary.backlog, 23)
        XCTAssertEqual(summary.pending, 1)
        XCTAssertTrue(summary.isForced)
        XCTAssertEqual(status.thresholds.forceWindowSeconds, 1_800)
        XCTAssertEqual(status.thresholds.summaryMaxGpuUtilization, 0.5)
        XCTAssertEqual(status.machine.gpuUtilization, 0.24)
    }

    /// The queue count is a subset of the vault count, so the row must not add
    /// them and claim 24 when 23 are outstanding.
    func testRemainingDoesNotDoubleCountWorkInFlight() {
        let gate = ComputeGate(
            workload: .summary,
            allowed: true,
            code: .allowed,
            pending: 1,
            backlog: 23
        )
        XCTAssertEqual(gate.remaining, 23)
        // With no durable pile, the queue is all there is.
        XCTAssertEqual(
            ComputeGate(workload: .ocr, allowed: true, code: .allowed, pending: 4).remaining,
            4
        )
    }

    /// Whether the button is offered is the daemon's decision now — the client
    /// only has to carry it through, and must not invent a default of `true`.
    func testRunNowFlagComesFromTheDaemon() throws {
        let json = """
        {
          "workload": "summary", "allowed": false, "code": "on_battery",
          "backlog": 23, "can_run_now": true
        }
        """
        let offered = try JSONDecoder().decode(ComputeGate.self, from: Data(json.utf8))
        XCTAssertTrue(offered.canRunNow)
        XCTAssertEqual(offered.remaining, 23)

        let silent = """
        { "workload": "summary", "allowed": false, "code": "on_battery", "backlog": 23 }
        """
        XCTAssertFalse(
            try JSONDecoder().decode(ComputeGate.self, from: Data(silent.utf8)).canRunNow,
            "a daemon that says nothing must not be read as offering the button"
        )
    }

    // MARK: - Why it is not running

    /// The Info popover has to name the condition that is actually blocking, and
    /// mark the ones that already hold.
    func testAutomaticConditionsMarkTheBlockingOne() {
        let status = ComputeStatus(
            machine: ComputeMachine(
                onAc: true,
                batteryFraction: 0.9,
                idleSeconds: 4,
                loadPerCore: 0.2
            )
        )
        let conditions = status.automaticConditions(for: .summary)
        let idle = try? XCTUnwrap(conditions.first { $0.label.contains("Idle") })
        XCTAssertEqual(idle?.met, false, "4s idle against a 120s threshold")
        XCTAssertEqual(idle?.label, "Idle for 120s")
        XCTAssertEqual(idle?.detail, "last input 4s ago")
        XCTAssertTrue(conditions.first { $0.label == "Plugged in" }?.met == true)
        XCTAssertTrue(conditions.first { $0.label.contains("Battery") }?.met == true)
        XCTAssertTrue(conditions.first { $0.label.contains("Load") }?.met == true)
    }

    /// An unreadable load average counts as busy — the gate fails closed, and the
    /// explanation must not claim the condition is satisfied.
    func testAnUnreadableLoadReadsAsUnmet() {
        let status = ComputeStatus(
            machine: ComputeMachine(onAc: true, batteryFraction: 1, idleSeconds: 600)
        )
        let load = status.automaticConditions(for: .summary)
            .first { $0.label.contains("Load") }
        XCTAssertEqual(load?.met, false)
        XCTAssertEqual(load?.detail, "unreadable — treated as busy")
    }

    /// A desktop has no battery to conserve, so that condition must not read as
    /// permanently failing.
    func testADesktopWithoutABatteryPassesTheChargeCondition() {
        let status = ComputeStatus(
            machine: ComputeMachine(onAc: true, batteryFraction: nil, idleSeconds: 600, loadPerCore: 0.1)
        )
        let battery = status.automaticConditions(for: .summary)
            .first { $0.label.contains("Battery") }
        XCTAssertEqual(battery?.met, true)
        XCTAssertEqual(battery?.detail, "no battery to conserve")
    }

    func testTheUsersOwnChoicesAreListedAsConditionsToo() {
        let now = Date()
        let paused = ComputeStatus(
            pausedUntilMs: Int64((now.timeIntervalSince1970 + 1_800) * 1000)
        )
        let labels = paused.automaticConditions(for: .summary).map(\.label)
        XCTAssertTrue(labels.contains("Not suspended"), "got \(labels)")
        XCTAssertFalse(
            paused.automaticConditions(for: .ocr).contains { $0.label == "Not suspended" },
            "screen text is exempt from a suspension, so listing it would contradict the gate"
        )

        let off = ComputeStatus(mode: .off)
        XCTAssertTrue(
            off.automaticConditions(for: .summary)
                .contains { $0.label == "Local computation switched on" && !$0.met }
        )
    }

    /// Screen text and embeddings have no machine gate at all; the popover
    /// should say so rather than inventing conditions to look consistent.
    func testCheapWorkloadsHaveNoConditions() {
        let status = ComputeStatus(machine: ComputeMachine(onAc: false, idleSeconds: 0))
        XCTAssertTrue(status.automaticConditions(for: .ocr).isEmpty)
        XCTAssertTrue(status.automaticConditions(for: .embedding).isEmpty)
    }

    func testTranscriptionListsTheMachineConditionsItActuallyUses() {
        let status = ComputeStatus(
            machine: ComputeMachine(
                onAc: true,
                idleSeconds: 4,
                loadPerCore: 0.8,
                gpuUtilization: 0.9
            ),
            thresholds: ComputeThresholds(
                summaryMinIdleSeconds: 120,
                summaryMaxLoadPerCore: 0.7,
                summaryMaxGpuUtilization: 0.5
            )
        )

        let asr = status.automaticConditions(for: .asr)
        XCTAssertEqual(asr.count, 3)
        XCTAssertEqual(asr.map(\.met), [false, false, false])
        XCTAssertEqual(asr[0].label, "Idle for 120s")
        XCTAssertEqual(asr[0].detail, "last input 4s ago")
        XCTAssertEqual(asr[1].label, "Load below 0.70/core")
        XCTAssertEqual(asr[1].detail, "0.80/core")
        XCTAssertEqual(asr[2].label, "15s GPU average below 50%")
        XCTAssertEqual(asr[2].detail, "90%")
    }

    func testTranscriptionOnBatteryIsThrottledRatherThanBlocked() {
        let status = ComputeStatus(
            machine: ComputeMachine(
                onAc: false,
                idleSeconds: 600,
                loadPerCore: 0.1,
                gpuUtilization: 0.1
            ),
            thresholds: ComputeThresholds(summaryMaxGpuUtilization: 0.5)
        )

        let asr = status.automaticConditions(for: .asr)
        XCTAssertEqual(asr.count, 4)
        XCTAssertTrue(asr.allSatisfy { $0.met })
        XCTAssertTrue(asr[3].detail.contains("five times slower"))
    }

    func testTranscriptionGpuConditionMatchesProbeAvailability() {
        let machine = ComputeMachine(onAc: true, idleSeconds: 600, loadPerCore: 0.1)

        let disabled = ComputeStatus(machine: machine)
            .automaticConditions(for: .asr)
        XCTAssertFalse(disabled.contains { $0.label.contains("GPU") })

        let unavailable = ComputeStatus(
            machine: machine,
            thresholds: ComputeThresholds(summaryMaxGpuUtilization: 0.5)
        )
        .automaticConditions(for: .asr)
        .first { $0.label.contains("GPU") }
        XCTAssertEqual(unavailable?.met, false)
        XCTAssertEqual(unavailable?.detail, "unreadable — treated as busy")
    }

    // MARK: - Summary timing

    func testDecodesSummaryTimingFromTheDaemon() throws {
        let json = """
        {
          "mode": "full",
          "running": [],
          "gates": [],
          "machine": {"on_ac": true, "idle_seconds": 1.0},
          "resident_models": [],
          "recent_summaries": [
            {"slot_start_ms": 100, "finished_at_ms": 900, "duration_ms": 164000, "ok": true},
            {"slot_start_ms": 200, "finished_at_ms": 800, "duration_ms": 11000, "ok": false}
          ],
          "summary_typical_ms": 164000,
          "capture_paused": false
        }
        """
        let status = try JSONDecoder().decode(ComputeStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.recentSummaries.count, 2)
        XCTAssertEqual(status.recentSummaries.first?.durationMs, 164_000)
        XCTAssertFalse(status.recentSummaries[1].ok)
        XCTAssertEqual(status.summaryTypicalMs, 164_000)
    }

    /// The timing fields are additive: a daemon from before they existed sends
    /// neither, and the panel must still render.
    func testAReportWithoutTimingStillDecodes() throws {
        let json = """
        {
          "mode": "full",
          "running": [],
          "gates": [],
          "machine": {"on_ac": true, "idle_seconds": 1.0},
          "resident_models": [],
          "capture_paused": false
        }
        """
        let status = try JSONDecoder().decode(ComputeStatus.self, from: Data(json.utf8))
        XCTAssertTrue(status.recentSummaries.isEmpty)
        XCTAssertNil(status.summaryTypicalMs)
        XCTAssertNil(status.summaryRemainingSeconds())
    }

    func testRemainingEstimateCountsDownFromTheTypicalDuration() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let status = ComputeStatus(
            running: [
                ComputeTask(
                    id: "t2",
                    workload: .summary,
                    lane: .gpu,
                    detail: "qwen35-4b-mlx",
                    startedAtMs: Int64((now.timeIntervalSince1970 - 100) * 1000)
                ),
            ],
            summaryTypicalMs: 180_000
        )
        XCTAssertEqual(status.summaryRemainingSeconds(now: now), 80)
        XCTAssertEqual(ComputeFormat.remaining(seconds: 80), "about 1m 20s left")
    }

    /// A pass that has already outrun the typical one gets silence rather than a
    /// countdown pinned at zero — the estimate is a median, not a progress bar.
    func testRemainingEstimateGoesQuietOnceAPassOverruns() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let status = ComputeStatus(
            running: [
                ComputeTask(
                    id: "t2",
                    workload: .summary,
                    lane: .gpu,
                    detail: "qwen35-4b-mlx",
                    startedAtMs: Int64((now.timeIntervalSince1970 - 600) * 1000)
                ),
            ],
            summaryTypicalMs: 180_000
        )
        XCTAssertNil(status.summaryRemainingSeconds(now: now))
    }

    func testRemainingEstimateNeedsBothARunAndAHistory() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let running = ComputeTask(
            id: "t2",
            workload: .summary,
            lane: .gpu,
            detail: "qwen35-4b-mlx",
            startedAtMs: Int64((now.timeIntervalSince1970 - 10) * 1000)
        )
        // No history yet.
        XCTAssertNil(ComputeStatus(running: [running]).summaryRemainingSeconds(now: now))
        // History, but the running task is a different workload.
        let ocr = ComputeTask(
            id: "ocr",
            workload: .ocr,
            lane: .gpu,
            detail: "vision-ocr",
            startedAtMs: Int64(now.timeIntervalSince1970 * 1000)
        )
        XCTAssertNil(
            ComputeStatus(running: [ocr], summaryTypicalMs: 180_000)
                .summaryRemainingSeconds(now: now)
        )
    }

    /// The panel and the daemon log must render the same duration the same way,
    /// so a number in one can be matched against the other.
    func testDurationFormattingMatchesTheDaemonLog() {
        XCTAssertEqual(ComputeFormat.duration(ms: 41_000), "41s")
        XCTAssertEqual(ComputeFormat.duration(ms: 161_000), "2m 41s")
        XCTAssertEqual(ComputeFormat.duration(ms: 61_000), "1m 01s")
        XCTAssertEqual(ComputeFormat.duration(ms: 4_500_000), "1h 15m")
        XCTAssertEqual(ComputeFormat.duration(ms: -5), "0s")
    }

    func testAsrBacklogDurationDecodesFromTheDaemon() throws {
        let gate = try JSONDecoder().decode(
            ComputeGate.self,
            from: Data(#"{"workload":"asr","allowed":false,"code":"in_use","backlog":200,"backlog_duration_ms":720000}"#.utf8)
        )
        XCTAssertEqual(gate.backlogDurationMs, 720_000)
    }

    // MARK: - Formatting

    func testCpuPercentSaysIdleRatherThanRoundingToZero() {
        XCTAssertEqual(ComputeFormat.cpuPercent(0.02), "idle")
        XCTAssertEqual(ComputeFormat.cpuPercent(4.28), "4.3% CPU")
        XCTAssertNil(ComputeFormat.cpuPercent(nil))
        XCTAssertNil(ComputeFormat.cpuPercent(.nan))
    }

    /// A multi-thread encoder above one core must read honestly — that is the
    /// case the panel exists to explain.
    func testCpuPercentAboveOneCoreIsNotClamped() {
        XCTAssertEqual(ComputeFormat.cpuPercent(412.0), "412% CPU")
    }

    func testFootprintSwitchesUnitsAtAGigabyte() {
        // Delegates to the same formatter the Models page and storage bar use, so
        // one resident pack cannot read as two different sizes in two panels.
        XCTAssertEqual(
            ComputeFormat.footprint(5_368_709_120),
            AfterRayStorageSnapshot.byteCount(5_368_709_120)
        )
        XCTAssertNil(ComputeFormat.footprint(0), "zero means nothing to report")
    }

    func testElapsedStaysReadableAcrossScales() {
        let now = Date(timeIntervalSince1970: 1_750_003_700)
        XCTAssertEqual(
            ComputeFormat.elapsed(sinceMs: 1_750_003_695_000, now: now),
            "5s"
        )
        // One duration format across the panel: a running row and a history row
        // must not render the same magnitude two ways.
        XCTAssertEqual(
            ComputeFormat.elapsed(sinceMs: 1_750_003_500_000, now: now),
            ComputeFormat.duration(ms: 200_000)
        )
        XCTAssertEqual(
            ComputeFormat.elapsed(sinceMs: 1_750_000_000_000, now: now),
            ComputeFormat.duration(ms: 3_700_000)
        )
        // A clock that moved backwards must not render a negative age.
        XCTAssertEqual(
            ComputeFormat.elapsed(sinceMs: 1_750_009_999_000, now: now),
            "0s"
        )
    }

    func testEveryModeExplainsWhatItCosts() {
        for mode in ComputeMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.detail.isEmpty, "\(mode) must say what it costs")
        }
        XCTAssertTrue(ComputeMode.off.detail.contains("not indexed"))
    }
}
