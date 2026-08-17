import Foundation

/// How much local computation the daemon may do when nobody is waiting on it.
///
/// Interactive work — a chat turn streaming on screen — is never governed by
/// this, and the panel says so. A switch that silently broke chat would read as
/// a broken app rather than a power setting.
public enum ComputeMode: String, Codable, Equatable, Sendable, CaseIterable {
    case full
    case essential
    case off

    /// One word each. As phrases these were wider than the control that held
    /// them, and the detail line underneath already said the rest.
    public var title: String {
        switch self {
        case .full: "Full"
        case .essential: "Essential"
        case .off: "Off"
        }
    }

    /// What choosing this costs, in the terms the user is deciding in.
    public var detail: String {
        switch self {
        case .full: "Everything runs, when the machine can afford it."
        case .essential: "Screen text and transcripts keep up. No summaries, no compression."
        case .off: "Nothing runs in the background — new screens are not indexed."
        }
    }
}

/// The resource a task competes for.
///
/// Shown instead of a GPU percentage: macOS publishes no per-process GPU
/// accounting, so a per-task percentage would be invented. The lane is true.
public enum ComputeLane: String, Codable, Equatable, Sendable {
    case gpu
    case cpu

    public var label: String {
        switch self {
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }
}

public enum ComputeWorkload: String, Codable, Equatable, Sendable {
    case ocr
    case asr
    case embedding
    case summary
    case archive

    public var title: String {
        switch self {
        case .ocr: "Screen text"
        case .asr: "Transcription"
        case .embedding: "Search index"
        case .summary: "Summaries"
        case .archive: "Archive compression"
        }
    }

    /// The engine behind the row, for the line under the title.
    public var engine: String {
        switch self {
        case .ocr: "Apple Vision"
        case .asr: "Qwen3-ASR"
        case .embedding: "Local embedder"
        case .summary: "Local language model"
        case .archive: "AV1 (rav1e)"
        }
    }

    public var symbol: String {
        switch self {
        case .ocr: "text.viewfinder"
        case .asr: "waveform"
        case .embedding: "point.3.filled.connected.trianglepath.dotted"
        case .summary: "sparkles"
        case .archive: "archivebox"
        }
    }
}

/// Why a workload is or is not running.
public enum ComputeGateCode: String, Codable, Equatable, Sendable {
    case allowed
    case modeOff = "mode_off"
    case modeEssential = "mode_essential"
    case paused
    case onBattery = "on_battery"
    case batteryLow = "battery_low"
    case inUse = "in_use"
    case machineBusy = "machine_busy"
    case unavailable
    case disabledByEnv = "disabled_by_env"

    /// Whether this is the user's own doing. A refusal the user chose reads
    /// differently from one the machine imposed, and should not look like a
    /// warning.
    public var isUserChoice: Bool {
        switch self {
        case .modeOff, .modeEssential, .paused: true
        case .allowed, .onBattery, .batteryLow, .inUse, .machineBusy, .unavailable, .disabledByEnv:
            false
        }
    }
}

public struct ComputeGate: Codable, Equatable, Sendable, Identifiable {
    public let workload: ComputeWorkload
    public let allowed: Bool
    public let code: ComputeGateCode
    public let reason: String?
    /// Work already handed to the job queue — seconds of it.
    public let pending: Int
    /// Work counted from the vault: the pile behind `pending`, and what "run
    /// now" promises to drain.
    public let backlog: Int
    /// Set while a user-requested override is running for this workload.
    public let forcedUntilMs: Int64?
    /// Whether offering "run now" here would change anything. Decided by the
    /// daemon: the answer depends on which workloads have a machine gate or a
    /// throttle of their own, which only the gate knows.
    public let canRunNow: Bool

    public var id: String { workload.rawValue }

    /// What the row shows as "remaining". The queue count is a subset of the
    /// vault count for the workloads that have both, so showing their sum would
    /// double-count the few items in flight.
    public var remaining: Int { max(pending, backlog) }

    public var isForced: Bool { forcedUntilMs != nil }

    public init(
        workload: ComputeWorkload,
        allowed: Bool,
        code: ComputeGateCode,
        reason: String? = nil,
        pending: Int = 0,
        backlog: Int = 0,
        forcedUntilMs: Int64? = nil,
        canRunNow: Bool = false
    ) {
        self.workload = workload
        self.allowed = allowed
        self.code = code
        self.reason = reason
        self.pending = pending
        self.backlog = backlog
        self.forcedUntilMs = forcedUntilMs
        self.canRunNow = canRunNow
    }

    enum CodingKeys: String, CodingKey {
        case workload
        case allowed
        case code
        case reason
        case pending
        case backlog
        case forcedUntilMs = "forced_until_ms"
        case canRunNow = "can_run_now"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workload = try container.decode(ComputeWorkload.self, forKey: .workload)
        allowed = try container.decode(Bool.self, forKey: .allowed)
        code = try container.decode(ComputeGateCode.self, forKey: .code)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        pending = try container.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        backlog = try container.decodeIfPresent(Int.self, forKey: .backlog) ?? 0
        forcedUntilMs = try container.decodeIfPresent(Int64.self, forKey: .forcedUntilMs)
        canRunNow = try container.decodeIfPresent(Bool.self, forKey: .canRunNow) ?? false
    }
}

/// The numbers the automatic triggers compare against.
///
/// Sent by the daemon rather than hardcoded here, so the explanation the user
/// reads cannot drift from the gate that actually decides.
public struct ComputeThresholds: Codable, Equatable, Sendable {
    public let summaryMinBatteryFraction: Double
    public let summaryMinIdleSeconds: Double
    public let summaryMaxLoadPerCore: Double
    public let forceWindowSeconds: Int

    public init(
        summaryMinBatteryFraction: Double = 0.30,
        summaryMinIdleSeconds: Double = 30,
        summaryMaxLoadPerCore: Double = 0.7,
        forceWindowSeconds: Int = 1_800
    ) {
        self.summaryMinBatteryFraction = summaryMinBatteryFraction
        self.summaryMinIdleSeconds = summaryMinIdleSeconds
        self.summaryMaxLoadPerCore = summaryMaxLoadPerCore
        self.forceWindowSeconds = forceWindowSeconds
    }

    enum CodingKeys: String, CodingKey {
        case summaryMinBatteryFraction = "summary_min_battery_fraction"
        case summaryMinIdleSeconds = "summary_min_idle_seconds"
        case summaryMaxLoadPerCore = "summary_max_load_per_core"
        case forceWindowSeconds = "force_window_seconds"
    }
}

/// One line of the "why isn't this running?" explanation: a condition, whether
/// it currently holds, and the live reading behind it.
public struct ComputeCondition: Equatable, Sendable, Identifiable {
    public let label: String
    public let detail: String
    public let met: Bool

    public var id: String { label }

    public init(label: String, detail: String, met: Bool) {
        self.label = label
        self.detail = detail
        self.met = met
    }
}

public struct ComputeTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let workload: ComputeWorkload
    public let lane: ComputeLane
    public let detail: String
    public let startedAtMs: Int64
    /// Share of one core. Above 100 is not a bug: a four-thread encoder really
    /// is taking four cores, and clamping it would hide the case the user
    /// opened the panel to find.
    public let cpuPercent: Double?
    public let footprintBytes: UInt64?

    public init(
        id: String,
        workload: ComputeWorkload,
        lane: ComputeLane,
        detail: String,
        startedAtMs: Int64,
        cpuPercent: Double? = nil,
        footprintBytes: UInt64? = nil
    ) {
        self.id = id
        self.workload = workload
        self.lane = lane
        self.detail = detail
        self.startedAtMs = startedAtMs
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workload
        case lane
        case detail
        case startedAtMs = "started_at_ms"
        case cpuPercent = "cpu_percent"
        case footprintBytes = "footprint_bytes"
    }
}

/// A model process that stays loaded between jobs.
public struct ComputeResidentModel: Codable, Equatable, Sendable, Identifiable {
    public let packId: String
    public let name: String
    public let pid: UInt32?
    public let footprintBytes: UInt64?
    public let cpuPercent: Double?

    public var id: String { packId }

    public init(
        packId: String,
        name: String,
        pid: UInt32? = nil,
        footprintBytes: UInt64? = nil,
        cpuPercent: Double? = nil
    ) {
        self.packId = packId
        self.name = name
        self.pid = pid
        self.footprintBytes = footprintBytes
        self.cpuPercent = cpuPercent
    }

    enum CodingKeys: String, CodingKey {
        case packId = "pack_id"
        case name
        case pid
        case footprintBytes = "footprint_bytes"
        case cpuPercent = "cpu_percent"
    }
}

/// One finished summary pass and what it cost.
///
/// Summaries are the only workload whose single run is long enough that the user
/// feels it start and then wonders when it will end. A history of durations is
/// what turns "my Mac is slow" into "this ends in about a minute".
public struct ComputeRun: Codable, Equatable, Sendable, Identifiable {
    public let slotStartMs: Int64
    public let finishedAtMs: Int64
    public let durationMs: Int64
    /// A failed pass still cost its duration, so it is shown, not hidden.
    public let ok: Bool

    public var id: Int64 { finishedAtMs }

    public init(slotStartMs: Int64, finishedAtMs: Int64, durationMs: Int64, ok: Bool = true) {
        self.slotStartMs = slotStartMs
        self.finishedAtMs = finishedAtMs
        self.durationMs = durationMs
        self.ok = ok
    }

    enum CodingKeys: String, CodingKey {
        case slotStartMs = "slot_start_ms"
        case finishedAtMs = "finished_at_ms"
        case durationMs = "duration_ms"
        case ok
    }
}

public struct ComputeMachine: Codable, Equatable, Sendable {
    public let onAc: Bool
    public let batteryFraction: Double?
    public let idleSeconds: Double
    public let loadPerCore: Double?
    public let thermalLevel: UInt32?
    public let daemonCpuPercent: Double?
    public let daemonFootprintBytes: UInt64?

    public init(
        onAc: Bool = true,
        batteryFraction: Double? = nil,
        idleSeconds: Double = 0,
        loadPerCore: Double? = nil,
        thermalLevel: UInt32? = nil,
        daemonCpuPercent: Double? = nil,
        daemonFootprintBytes: UInt64? = nil
    ) {
        self.onAc = onAc
        self.batteryFraction = batteryFraction
        self.idleSeconds = idleSeconds
        self.loadPerCore = loadPerCore
        self.thermalLevel = thermalLevel
        self.daemonCpuPercent = daemonCpuPercent
        self.daemonFootprintBytes = daemonFootprintBytes
    }

    enum CodingKeys: String, CodingKey {
        case onAc = "on_ac"
        case batteryFraction = "battery_fraction"
        case idleSeconds = "idle_seconds"
        case loadPerCore = "load_per_core"
        case thermalLevel = "thermal_level"
        case daemonCpuPercent = "daemon_cpu_percent"
        case daemonFootprintBytes = "daemon_footprint_bytes"
    }
}

public struct ComputeStatus: Codable, Equatable, Sendable {
    // `var` rather than `let`: fixtures and previews change one field at a time,
    // and with `let` every mutation had to re-list all ten — which is how a new
    // wire field silently goes missing from the Visual Lab.
    public var mode: ComputeMode
    public var pausedUntilMs: Int64?
    public var running: [ComputeTask]
    public var gates: [ComputeGate]
    public var machine: ComputeMachine
    /// The numbers the automatic triggers compare against.
    public var thresholds: ComputeThresholds
    public var residentModels: [ComputeResidentModel]
    /// Recent summary passes, newest first.
    public var recentSummaries: [ComputeRun]
    /// Median duration of the recent successful passes, computed by the daemon.
    public var summaryTypicalMs: Int64?
    /// True while the app's own overlay is suppressing capture.
    public var capturePaused: Bool

    public init(
        mode: ComputeMode = .full,
        pausedUntilMs: Int64? = nil,
        running: [ComputeTask] = [],
        gates: [ComputeGate] = [],
        machine: ComputeMachine = ComputeMachine(),
        thresholds: ComputeThresholds = ComputeThresholds(),
        residentModels: [ComputeResidentModel] = [],
        recentSummaries: [ComputeRun] = [],
        summaryTypicalMs: Int64? = nil,
        capturePaused: Bool = false
    ) {
        self.mode = mode
        self.pausedUntilMs = pausedUntilMs
        self.running = running
        self.gates = gates
        self.machine = machine
        self.thresholds = thresholds
        self.residentModels = residentModels
        self.recentSummaries = recentSummaries
        self.summaryTypicalMs = summaryTypicalMs
        self.capturePaused = capturePaused
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case pausedUntilMs = "paused_until_ms"
        case running
        case gates
        case machine
        case thresholds
        case residentModels = "resident_models"
        case recentSummaries = "recent_summaries"
        case summaryTypicalMs = "summary_typical_ms"
        case capturePaused = "capture_paused"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(ComputeMode.self, forKey: .mode)
        pausedUntilMs = try container.decodeIfPresent(Int64.self, forKey: .pausedUntilMs)
        running = try container.decode([ComputeTask].self, forKey: .running)
        gates = try container.decode([ComputeGate].self, forKey: .gates)
        machine = try container.decode(ComputeMachine.self, forKey: .machine)
        thresholds = try container.decodeIfPresent(
            ComputeThresholds.self, forKey: .thresholds
        ) ?? ComputeThresholds()
        residentModels = try container.decode([ComputeResidentModel].self, forKey: .residentModels)
        // Additive fields: a daemon from before summary timing sends neither.
        recentSummaries = try container.decodeIfPresent(
            [ComputeRun].self, forKey: .recentSummaries
        ) ?? []
        summaryTypicalMs = try container.decodeIfPresent(Int64.self, forKey: .summaryTypicalMs)
        capturePaused = try container.decode(Bool.self, forKey: .capturePaused)
    }

    public static let idle = ComputeStatus()

    public var isBusy: Bool { !running.isEmpty }

    public var pendingTotal: Int { gates.reduce(0) { $0 + $1.pending } }

    /// Whether anything is held back by something other than the user's own
    /// choice — the case worth surfacing on the button.
    public var machineHold: ComputeGate? {
        gates.first { !$0.allowed && !$0.code.isUserChoice && $0.remaining > 0 }
    }

    public var isHeldByMachine: Bool { machineHold != nil }

    public func isPaused(now: Date = Date()) -> Bool {
        guard let pausedUntilMs else { return false }
        return Double(pausedUntilMs) / 1000 > now.timeIntervalSince1970
    }

    /// The conditions that have to hold for `workload` to start on its own,
    /// each paired with the live reading behind it.
    ///
    /// This is the panel's answer to "why isn't this running?" — and, just as
    /// importantly, to "what would make it run?". Built from thresholds the
    /// daemon sent rather than numbers written into the UI, so it cannot drift
    /// from the gate that actually decides.
    public func automaticConditions(for workload: ComputeWorkload) -> [ComputeCondition] {
        var conditions: [ComputeCondition] = []
        if mode == .off {
            conditions.append(
                ComputeCondition(
                    label: "Local computation switched on",
                    detail: "currently off",
                    met: false
                )
            )
        }
        // Screen text is exempt from a suspension (there is no OCR backlog, so a
        // skipped frame is never indexed later), so listing it as a condition
        // here would contradict the gate.
        if workload != .ocr, let minutes = pauseMinutesRemaining() {
            conditions.append(
                ComputeCondition(
                    label: "Not suspended",
                    detail: "you suspended it — \(minutes) min left",
                    met: false
                )
            )
        }
        switch workload {
        case .summary, .archive:
            conditions.append(
                ComputeCondition(
                    label: "Plugged in",
                    detail: machine.onAc ? "on power" : "on battery",
                    met: machine.onAc
                )
            )
        case .ocr, .asr, .embedding:
            break
        }
        guard workload == .summary else {
            if workload == .asr, !machine.onAc {
                conditions.append(
                    ComputeCondition(
                        label: "Full speed",
                        detail: "on battery it runs five times slower, not never",
                        met: true
                    )
                )
            }
            return conditions
        }
        // Summaries are the only workload with the full machine gate, and the
        // only one where knowing the exact threshold changes what a user does.
        let battery = machine.batteryFraction
        conditions.append(
            ComputeCondition(
                label: "Battery above \(Int(thresholds.summaryMinBatteryFraction * 100))%",
                detail: ComputeFormat.battery(battery) ?? "no battery to conserve",
                met: battery.map { $0 >= thresholds.summaryMinBatteryFraction } ?? true
            )
        )
        conditions.append(
            ComputeCondition(
                label: "Idle for \(Int(thresholds.summaryMinIdleSeconds))s",
                detail: "last input \(Int(machine.idleSeconds))s ago",
                met: machine.idleSeconds >= thresholds.summaryMinIdleSeconds
            )
        )
        conditions.append(
            ComputeCondition(
                label: String(format: "Load below %.2f/core", thresholds.summaryMaxLoadPerCore),
                detail: ComputeFormat.load(machine.loadPerCore) ?? "unreadable — treated as busy",
                met: machine.loadPerCore.map { $0 <= thresholds.summaryMaxLoadPerCore } ?? false
            )
        )
        return conditions
    }

    /// The gate row for a workload, if the daemon reported one.
    public func gate(for workload: ComputeWorkload) -> ComputeGate? {
        gates.first { $0.workload == workload }
    }

    /// Everything outstanding, so the size of the pile is one number.
    ///
    /// `max(pending, backlog)` per row, not their sum: the queue count is a
    /// subset of the vault count.
    public var totalRemaining: Int {
        gates.reduce(0) { $0 + $1.remaining }
    }

    /// The summary pass running right now, if any. Named because it is the one
    /// task with a duration history to compare against.
    public var runningSummary: ComputeTask? {
        running.first { $0.workload == .summary }
    }

    /// Roughly how much longer the running summary has, from the typical
    /// duration and how long this one has already been going.
    ///
    /// `nil` when there is no history to compare against, or when this pass has
    /// already outrun the typical one — at that point the honest answer is "no
    /// idea", and a countdown stuck at "about 0s left" would be worse than
    /// silence.
    public func summaryRemainingSeconds(now: Date = Date()) -> Int? {
        guard let task = runningSummary, let typical = summaryTypicalMs, typical > 0 else {
            return nil
        }
        let elapsedMs = now.timeIntervalSince1970 * 1000 - Double(task.startedAtMs)
        let remainingMs = Double(typical) - elapsedMs
        guard remainingMs > 1_000 else { return nil }
        return Int((remainingMs / 1000).rounded())
    }

    /// Minutes left in the suspension, rounded up so "1 min" never means zero.
    public func pauseMinutesRemaining(now: Date = Date()) -> Int? {
        guard let pausedUntilMs else { return nil }
        let seconds = Double(pausedUntilMs) / 1000 - now.timeIntervalSince1970
        guard seconds > 0 else { return nil }
        return Int((seconds / 60).rounded(.up))
    }
}

/// What the entry-point button shows without being opened.
///
/// The button lives in two places — the menu bar and the overlay's top-right
/// cluster — and both need the same one-glance answer. The menu-bar icon can be
/// hidden by a crowded menu bar, which is exactly why the overlay carries one
/// too.
public enum ComputeIndicator: Equatable, Sendable {
    case idle
    case working(count: Int)
    case paused(minutesRemaining: Int?)
    case off
    /// Work is queued but the machine will not allow it yet.
    case waiting(reason: String)

    public init(status: ComputeStatus, now: Date = Date()) {
        if status.mode == .off {
            self = .off
        } else if status.isPaused(now: now) {
            self = .paused(minutesRemaining: status.pauseMinutesRemaining(now: now))
        } else if status.isBusy {
            self = .working(count: status.running.count)
        } else if let held = status.machineHold, let reason = held.reason {
            self = .waiting(reason: reason)
        } else {
            self = .idle
        }
    }

    /// Filled only while something is actually running: outline is the resting
    /// variant, fill marks the active state, and nothing else in the cluster
    /// should read as "busy" when the machine is not.
    public var symbol: String {
        switch self {
        case .working: "hammer.fill"
        // Idle and waiting are both "not working right now"; the tooltip is
        // what distinguishes them, not a second glyph.
        case .idle, .waiting: "hammer"
        case .paused: "pause.circle"
        case .off: "moon.zzz"
        }
    }

    /// The tooltip, which is the only text most users will ever read here.
    public var help: String {
        switch self {
        case .idle: "Local computation is idle"
        case let .working(count):
            count == 1 ? "1 local task running" : "\(count) local tasks running"
        case let .paused(minutes):
            if let minutes { "Background computation suspended for \(minutes) more min" }
            else { "Background computation suspended" }
        case .off: "Local computation is switched off"
        case let .waiting(reason): "Waiting — \(reason)"
        }
    }

    /// Whether the button should draw attention. Idle and user-chosen states
    /// must not: a switch the user set is not a problem to be fixed.
    public var isAccented: Bool {
        switch self {
        case .working: true
        case .idle, .paused, .off, .waiting: false
        }
    }
}

/// Formats the numbers in the panel.
///
/// Free functions rather than view code so the rounding is testable: a task
/// reading "0%" while a fan spins is worse than no number at all.
public enum ComputeFormat {
    public static func cpuPercent(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        // Below a tenth of a percent, say idle rather than round to 0%.
        if value < 0.1 { return "idle" }
        return value < 10
            ? String(format: "%.1f%% CPU", value)
            : String(format: "%.0f%% CPU", value)
    }

    /// Zero means "nothing to report" rather than "0 bytes", which is why this
    /// returns an optional; the number itself is formatted the way the Models
    /// page and the storage bar format bytes, so one resident pack does not read
    /// as two different sizes in two panels.
    public static func footprint(_ bytes: UInt64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return AfterRayStorageSnapshot.byteCount(bytes)
    }

    /// How long a task has been running. The same formatting as every other
    /// duration in the panel — a running row and a history row sit 60 points
    /// apart, and rendering the same magnitude two ways reads as a bug.
    public static func elapsed(sinceMs startedAtMs: Int64, now: Date = Date()) -> String {
        let elapsedMs = now.timeIntervalSince1970 * 1000 - Double(startedAtMs)
        return duration(ms: Int64(max(0, elapsedMs)))
    }

    /// A duration a person can read: `41s`, `2m 41s`, `1h 15m`. Matches the
    /// daemon's log formatting, so a number in the panel and a number in the log
    /// look like the same number.
    public static func duration(ms: Int64) -> String {
        let seconds = max(0, ms) / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3_600)h \(String(format: "%02d", (seconds % 3_600) / 60))m"
    }

    /// "about 1m 20s left". Deliberately hedged: it is a median of past runs,
    /// not a progress bar, and pretending otherwise invites the user to trust a
    /// number that can be wrong by minutes.
    public static func remaining(seconds: Int) -> String {
        "about \(duration(ms: Int64(seconds) * 1000)) left"
    }

    /// Wall-clock time of day for a past run, so a duration can be placed
    /// against what the user was doing then.
    ///
    /// The formatter is hoisted: building one costs more than formatting with it,
    /// and the history renders six rows on every two-second poll.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    public static func clock(atMs: Int64) -> String {
        clockFormatter.string(from: Date(timeIntervalSince1970: Double(atMs) / 1000))
    }

    public static func battery(_ fraction: Double?) -> String? {
        guard let fraction, fraction.isFinite else { return nil }
        return String(format: "%.0f%%", fraction * 100)
    }

    public static func load(_ perCore: Double?) -> String? {
        guard let perCore, perCore.isFinite else { return nil }
        return String(format: "%.2f/core", perCore)
    }
}
