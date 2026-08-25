import SwiftUI

/// The local-computation dashboard: what is running, what is held back and
/// why, what it costs, and the two controls that stop it.
///
/// The design bet is that the most valuable thing here is not a percentage but
/// a sentence. "Summaries — held: battery at 18% is below 30%" answers the
/// question people actually have ("why has nothing been summarised?"), and no
/// gauge can.
/// Panel metrics. A separate enum because a generic type cannot hold static
/// stored properties.
private enum ComputePanelMetrics {
    /// Room for the overlay scroller to the right of the text.
    ///
    /// macOS floats the scroller over the content, so without this the numbers
    /// in the right-hand column sit underneath it the moment the list scrolls.
    static let scrollerGutter: CGFloat = 16
    static let gutter: CGFloat = 18
}

public struct ComputeActivityPanel<Model: ComputeActivityPresenting>: View {
    @ObservedObject var model: Model
    @ObservedObject private var localization = AfterRayLocalization.shared

    private var copy: AfterRayCopy { localization.copy }
    /// Which row's explanation is open. One at a time: two popovers of
    /// conditions side by side would be unreadable.
    @State private var explainedWorkload: ComputeWorkload?
    @State private var explainingModes = false

    public init(model: Model) {
        self.model = model
    }

    private var status: ComputeStatus { model.status }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ComputePanelMetrics.gutter)
                .padding(.top, 12)
                .padding(.bottom, 12)
            Divider().overlay(RecallPalette.panelStroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runningSection
                    workloadSection
                    summaryTimingSection
                    residentSection
                    machineSection
                }
                .padding(.leading, ComputePanelMetrics.gutter)
                .padding(.trailing, ComputePanelMetrics.gutter - 4 + ComputePanelMetrics.scrollerGutter)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider().overlay(RecallPalette.panelStroke)
            controls
                .padding(.horizontal, ComputePanelMetrics.gutter)
                .padding(.vertical, 14)
        }
        // The window supplies the surface. Drawing a rounded, glassed card in
        // here left the card's own corners inside the window's, which is what
        // made the background appear to bleed past the radius.
        .frame(minWidth: 380, minHeight: 420)
        .background(RecallPalette.background)
        .preferredColorScheme(.dark)
        .afterRayLocalized()
        // Polling is started and stopped by whoever hosts this view, not here.
        // Both hosts are AppKit windows that are ordered out rather than torn
        // down, so `onDisappear` never fires and a view-owned watcher would poll
        // for the life of the process — the exact background load this panel
        // exists to report on.
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.indicator.help(copy))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RecallPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let message = model.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(RecallPalette.ray)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 150)
            }
            // Up here rather than beside the controls: down there it needed a
            // column of its own, and an empty vertical strip next to two
            // full-width buttons read as a layout mistake.
            Button {
                explainingModes.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help(copy.compute.howItDecides)
            .popover(isPresented: $explainingModes, arrowEdge: .bottom) {
                modesPopover
            }
        }
    }

    // MARK: - Running

    private var runningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(copy.compute.runningNow)
            if status.running.isEmpty {
                Text(status.totalRemaining > 0
                    ? copy.compute.nothingRunningWaiting(status.totalRemaining)
                    : copy.compute.nothingRunning)
                    .font(.caption)
                    .foregroundStyle(RecallPalette.textTertiary)
            } else {
                ForEach(status.running) { task in
                    runningRow(task)
                }
            }
        }
    }

    private func runningRow(_ task: ComputeTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.workload.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(RecallPalette.ray)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.workload.title(copy))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(RecallPalette.textPrimary)
                    // The lane, not a GPU percentage. macOS does not publish
                    // per-process GPU use, so a number here would be invented.
                    Text(task.lane.label)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(RecallPalette.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            Capsule().stroke(RecallPalette.panelStroke, lineWidth: 1)
                        )
                }
                Text(task.detail)
                    .font(.caption2)
                    .foregroundStyle(RecallPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ComputeFormat.elapsed(sinceMs: task.startedAtMs, now: model.tick))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RecallPalette.textSecondary)
                // The answer to "how much longer will I be slow?" belongs on the
                // row that is making them slow, not only in the history below.
                if task.workload == .summary,
                   let remaining = status.summaryRemainingSeconds(now: model.tick)
                {
                    Text(ComputeFormat.remaining(seconds: remaining))
                        .font(.system(size: 10))
                        .foregroundStyle(RecallPalette.ray)
                } else if let cpu = ComputeFormat.cpuPercent(task.cpuPercent) {
                    Text(cpu)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RecallPalette.textTertiary)
                }
            }
        }
    }

    // MARK: - Summary timing

    /// How long summaries have been taking. The expensive workload is the one
    /// worth a history: a user who can see "these run about three minutes" can
    /// decide whether to wait or to hold work off, which is the whole point of
    /// the panel.
    @ViewBuilder
    private var summaryTimingSection: some View {
        if !status.recentSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(copy.compute.summaryTiming)
                if let typical = status.summaryTypicalMs {
                    HStack(spacing: 6) {
                        Text(copy.compute.usually)
                            .font(.caption)
                            .foregroundStyle(RecallPalette.textTertiary)
                        Text(ComputeFormat.duration(ms: typical))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(RecallPalette.textPrimary)
                        Text(copy.compute.perSlot(successfulRunCount))
                            .font(.caption2)
                            .foregroundStyle(RecallPalette.textTertiary)
                    }
                }
                ForEach(status.recentSummaries.prefix(6)) { run in
                    HStack(spacing: 8) {
                        Image(systemName: run.ok ? "checkmark" : "exclamationmark.triangle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(run.ok
                                ? RecallPalette.textTertiary
                                : RecallPalette.ray)
                            .frame(width: 16)
                        Text(ComputeFormat.duration(ms: run.durationMs))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(run.ok
                                ? RecallPalette.textSecondary
                                : RecallPalette.textTertiary)
                            .frame(width: 56, alignment: .leading)
                        Text(run.ok ? copy.compute.finished : copy.compute.gaveUp)
                            .font(.caption2)
                            .foregroundStyle(RecallPalette.textTertiary)
                        Spacer(minLength: 6)
                        Text(ComputeFormat.clock(atMs: run.finishedAtMs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(RecallPalette.textTertiary)
                    }
                }
            }
        }
    }

    private var successfulRunCount: Int {
        status.recentSummaries.filter(\.ok).count
    }

    // MARK: - Workloads

    private var workloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionTitle(copy.compute.workTypes)
                Spacer(minLength: 4)
                if status.totalRemaining > 0 {
                    Text(copy.compute.itemsWaiting(status.totalRemaining))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(RecallPalette.textTertiary)
                }
            }
            ForEach(status.gates) { gate in
                gateRow(gate)
            }
        }
    }

    private func gateRow(_ gate: ComputeGate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: gate.workload.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(gate.allowed
                    ? RecallPalette.textSecondary
                    : RecallPalette.textTertiary.opacity(0.7))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(gate.workload.title(copy))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(gate.allowed
                            ? RecallPalette.textPrimary
                            : RecallPalette.textSecondary)
                    Text(waitingLabel(gate))
                        .font(.system(size: 10))
                        .foregroundStyle(gate.remaining > 0
                            ? (gate.allowed ? RecallPalette.textSecondary : RecallPalette.ray)
                            : RecallPalette.textTertiary.opacity(0.7))
                }
                // The reason line is the point of this panel. An allowed row
                // says what engine does the work; a held row says which
                // measurement stopped it.
                Text(gateSubtitle(gate))
                    .font(.caption2)
                    .foregroundStyle(gate.allowed
                        ? RecallPalette.textTertiary
                        : RecallPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if gate.canRunNow || !gate.allowed {
                    gateActions(gate)
                }
            }
            Spacer(minLength: 6)
            Text(gateStateLabel(gate))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(gate.isForced
                    ? RecallPalette.ray
                    : (gate.allowed ? RecallPalette.textSecondary : RecallPalette.textTertiary))
        }
    }

    private func gateSubtitle(_ gate: ComputeGate) -> String {
        if gate.isForced { return copy.compute.runningNowAtRequest }
        return gate.allowed ? gate.workload.engine : (gate.reason ?? copy.compute.heldShort)
    }

    // @dec:asr-backlog-duration — docs/decisions/active/product/2026-08-25-asr-backlog-duration.md
    private func waitingLabel(_ gate: ComputeGate) -> String {
        guard gate.remaining > 0 else { return copy.compute.upToDate }
        if gate.workload == .asr, let durationMs = gate.backlogDurationMs, durationMs > 0 {
            return copy.compute.waitingAudioDuration(ComputeFormat.duration(ms: durationMs))
        }
        return copy.compute.waitingCount(gate.remaining)
    }

    private func gateStateLabel(_ gate: ComputeGate) -> String {
        if gate.isForced { return copy.compute.forced }
        return gate.allowed ? copy.common.on : copy.compute.held
    }

    /// "Start" and the explanation beside it.
    ///
    /// Both live on the row rather than in a global button so it is unambiguous
    /// which pile is about to start moving — and so the explanation can name the
    /// conditions that particular workload waits for.
    private func gateActions(_ gate: ComputeGate) -> some View {
        HStack(spacing: 8) {
            if gate.canRunNow {
                Button {
                    Task { await model.runNow(gate.workload) }
                } label: {
                    Text(copy.compute.startNow)
                        .font(.system(size: 11, weight: .medium))
                }
                // Bordered, not borderless: as bare text this was the one
                // actionable control on the row and nobody could tell it was a
                // button.
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isApplying)
                .help(runNowHelp(gate))
            }
            Button {
                explainedWorkload = explainedWorkload == gate.workload ? nil : gate.workload
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(copy.compute.conditionsHelp)
            .popover(
                isPresented: Binding(
                    get: { explainedWorkload == gate.workload },
                    set: { shown in explainedWorkload = shown ? gate.workload : nil }
                ),
                arrowEdge: .bottom
            ) {
                conditionsPopover(gate)
            }
        }
    }

    /// Accurate per state: a held row is being overridden, an allowed row is
    /// being told to work through its pile now instead of a couple of items
    /// every five minutes.
    private func runNowHelp(_ gate: ComputeGate) -> String {
        gate.allowed
            ? copy.compute.startAllNow(gate.remaining)
            : copy.compute.startRemainingNow(gate.remaining)
    }

    /// Every condition, with the live reading next to it. The unmet ones are the
    /// answer to "why is this not running", and the met ones are what stops the
    /// list reading as a wall of complaints.
    private func conditionsPopover(_ gate: ComputeGate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.compute.startsWhen(gate.workload.title(copy)))
                .font(.system(size: 12, weight: .semibold))
            let conditions = status.automaticConditions(for: gate.workload, copy: copy)
            if conditions.isEmpty {
                Text(copy.compute.noConditions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(conditions) { condition in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: condition.met ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(condition.met ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(condition.label)
                                .font(.caption)
                            Text(condition.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if gate.workload == .summary {
                Divider()
                Text(copy.compute.summariesExpensive)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    // MARK: - Resident models

    @ViewBuilder
    private var residentSection: some View {
        if !status.residentModels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(copy.compute.loadedModels)
                // Worth its own section: a resident pack holds gigabytes of
                // unified memory whether or not it is generating, which
                // explains more "my Mac got slow" than any percentage.
                ForEach(status.residentModels) { resident in
                    HStack(spacing: 10) {
                        Image(systemName: "cpu")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RecallPalette.textSecondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resident.packId)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(RecallPalette.textPrimary)
                            Text(resident.name)
                                .font(.caption2)
                                .foregroundStyle(RecallPalette.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 2) {
                            if let footprint = ComputeFormat.footprint(resident.footprintBytes) {
                                Text(footprint)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(RecallPalette.textSecondary)
                            }
                            if let cpu = ComputeFormat.cpuPercent(resident.cpuPercent) {
                                Text(cpu)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RecallPalette.textTertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Machine

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(copy.compute.thisMachine)
            VStack(alignment: .leading, spacing: 4) {
                machineRow(
                    copy.compute.power,
                    status.machine.onAc ? copy.compute.pluggedIn : copy.compute.onBattery,
                    detail: ComputeFormat.battery(status.machine.batteryFraction)
                )
                machineRow(copy.compute.load, ComputeFormat.load(status.machine.loadPerCore) ?? copy.compute.unavailable)
                if let thermal = status.machine.thermalLevel, thermal > 0 {
                    machineRow(copy.compute.thermalName, copy.compute.thermal("\(thermal)"))
                }
                machineRow(
                    "AfterRay",
                    ComputeFormat.cpuPercent(status.machine.daemonCpuPercent) ?? "—",
                    detail: ComputeFormat.footprint(status.machine.daemonFootprintBytes)
                )
            }
            if !status.machine.onAc {
                // The behaviour the app used to claim and not have. Said plainly
                // so nobody has to infer it from a quiet machine.
                calloutText(copy.compute.onBatteryNote)
            }
            if status.capturePaused {
                // Without this, the panel is circular: the overlay it is shown
                // in resets the idle timer that summaries wait on.
                calloutText(copy.compute.overlayOpenNote)
            }
        }
    }

    private func machineRow(_ label: String, _ value: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(RecallPalette.textTertiary)
                .frame(width: 70, alignment: .leading)
            Text(detail.map { "\(value) · \($0)" } ?? value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RecallPalette.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func calloutText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(RecallPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.togglePause() }
            } label: {
                Label(
                    pauseButtonTitle,
                    systemImage: status.isPaused(now: model.tick) ? "play.fill" : "pause.fill"
                )
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.isApplying || status.mode == .off)
            .help(status.mode == .off
                ? copy.compute.nothingToSuspend
                : copy.compute.suspendHelp)

            // Hand-rolled rather than `Picker(.segmented)`: that style sizes
            // itself to its widest label and ignores `maxWidth: .infinity`,
            // which left this row visibly narrower than the button above it.
            HStack(spacing: 2) {
                ForEach(ComputeMode.allCases, id: \.self) { mode in
                    modeSegment(mode)
                }
            }
            .padding(2)
            .background(
                // Concentric with the segments inside it: 6 + 2 padding = 8.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func modeSegment(_ mode: ComputeMode) -> some View {
        let selected = status.mode == mode
        return Button {
            Task { await model.setMode(mode) }
        } label: {
            Text(mode.title(copy))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? RecallPalette.textPrimary : RecallPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isApplying)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    /// The per-mode copy and the chat guarantee, behind the info button.
    ///
    /// These were two lines of grey small print under the picker, which is
    /// where text goes to be skipped — and the chat guarantee is the one thing
    /// here a user would be alarmed to be unsure about.
    private var modesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ComputeMode.allCases, id: \.self) { mode in
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title(copy))
                        .font(.system(size: 12, weight: .semibold))
                    Text(mode.detail(copy))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text(copy.compute.chatAlwaysRuns)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 260)
    }

    private var pauseButtonTitle: String {
        if let minutes = status.pauseMinutesRemaining(now: model.tick) {
            return copy.compute.resumeNow(minutes)
        }
        return copy.compute.pauseForHour
    }

    /// Sentence case, not caps. Shouting a five-word label at the reader buys
    /// nothing that weight and colour do not already do.
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RecallPalette.textTertiary)
    }
}

/// The entry point that appears in the overlay's chrome cluster and in the
/// menu bar.
///
/// Both exist deliberately: the menu bar is where a user goes when they want
/// to free the machine without opening a full-screen recall overlay, but menu
/// bar space is scarce and the icon is often hidden, so the overlay carries one
/// too.
public struct ComputeActivityButton: View {
    let indicator: ComputeIndicator
    let action: () -> Void

    public init(indicator: ComputeIndicator, action: @escaping () -> Void) {
        self.indicator = indicator
        self.action = action
    }

    public var body: some View {
        RecallChromeIconButton(
            symbol: indicator.symbol,
            help: indicator.help(AfterRayLocalization.shared.copy),
            tint: indicator.isAccented ? RecallPalette.ray : .white,
            action: action
        )
    }
}
