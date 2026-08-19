import AppKit
import SwiftUI

@MainActor
private func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// How the panel is being hosted. The overlay pins its size and wears
/// glass; a standalone window fills whatever the user resizes it to.
public enum DaySummaryPanelStyle: Sendable {
    case overlay
    case window
}

/// Timeline metrics shared by the gutter, the spine overlay, and the
/// current-slot rail so those three pieces stay on one vertical line.
private enum DaySummaryMetrics {
    static let spineX: CGFloat = 44
    static let textLeading: CGFloat = 12
    static var textX: CGFloat { spineX + textLeading }
    static let cardRadius: CGFloat = 9
    static let iconLimit = 8
}

/// The history-summary panel is a virtualized list: `LazyVStack` only
/// mounts the days (and their rows) in view, and the store pages older
/// days from the daemon. Cross-row drag-select is not a text document —
/// copy is structured (this slot, this day, all loaded days).
public struct DaySummaryPanel: View {
    @Environment(\.afterRayCopy) private var copy
    @State private var expandedSlotStarts: Set<Int64> = []
    @State private var followedSlot: Int64?
    var style: DaySummaryPanelStyle = .overlay
    var onPopOut: (() -> Void)? = nil
    let summaries: [DaySummary]
    let playheadMs: Int64
    let nowMs: Int64
    let hasMore: Bool
    let isLoadingMore: Bool
    /// Bumped when a scrub settles for one final alignment correction.
    /// Live following is throttled to highlighted slot changes.
    let followPulse: Int
    let onSelectSlot: (DaySlotSummary) -> Void
    let onLoadMore: () -> Void

    public init(
        style: DaySummaryPanelStyle = .overlay,
        onPopOut: (() -> Void)? = nil,
        summaries: [DaySummary],
        playheadMs: Int64,
        nowMs: Int64,
        hasMore: Bool,
        isLoadingMore: Bool,
        followPulse: Int,
        onSelectSlot: @escaping (DaySlotSummary) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.style = style
        self.onPopOut = onPopOut
        self.summaries = summaries
        self.playheadMs = playheadMs
        self.nowMs = nowMs
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.followPulse = followPulse
        self.onSelectSlot = onSelectSlot
        self.onLoadMore = onLoadMore
    }

    private var dayCountLabel: String {
        let count = summaries.count
        return count == 1 ? "1 day" : "\(count) days"
    }

    private var highlightedSlotStart: Int64? {
        summaries.lazy.compactMap {
            DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: $0.slots)
        }.first
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .modifier(DaySummaryPanelChrome(style: style))
        .accessibilityIdentifier("history-summary-panel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(copy.compute.summaries)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 8)
            if !summaries.isEmpty {
                Text(dayCountLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
            }
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 22, height: 22)
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .recallHoverFill(
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(RecallGlassPressStyle())
                .help(copy.recall.openAsWindow)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contextMenu {
            Button(copy.recall.copyAllLoadedDays) {
                copyToPasteboard(DaySummaryClipboard.historyText(summaries))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.recall.nothingRecorded)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
            Text(copy.recall.pastDaysWillAppear)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: style == .window) {
                // Pinned headers: while a day's rows scroll, its date stays
                // put at the top of the list — the reader always knows which
                // day they are inside.
                LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    ForEach(summaries, id: \.dayStartMs) { summary in
                        DaySummarySection(
                            summary: summary,
                            nowMs: nowMs,
                            highlightedSlotStart: highlightedSlotStart,
                            expandedSlotStarts: expandedSlotStarts,
                            onSelectSlot: onSelectSlot,
                            onToggleDetails: toggleDetails
                        )
                        .id(summary.dayStartMs)
                    }
                    if hasMore {
                        HistorySummaryLoadTrigger(isLoading: isLoadingMore, onAppear: onLoadMore)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(width: 1)
                    .padding(.leading, 6 + DaySummaryMetrics.spineX)
                    .allowsHitTesting(false)
            }
            .frame(
                maxHeight: style == .overlay ? RecallGeometry.daySummaryListMaxHeight : .infinity
            )
            .background(ScrollFenceView())
            .onAppear { follow(proxy, settle: true) }
            .onChange(of: highlightedSlotStart) { _, _ in
                follow(proxy, settle: false)
            }
            .onChange(of: followPulse) { _, _ in
                follow(proxy, settle: true)
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy, settle: Bool) {
        let current = highlightedSlotStart
        guard HistoryDocumentFollow.shouldFollow(
            previousSlot: followedSlot,
            currentSlot: current,
            settleRequested: settle
        ) else { return }
        // The user reading the panel outranks the playhead.
        if ScrollFenceRegistry.shared.pointerInsideAnyFence() { return }
        // LazyVStack cannot scroll to a row inside an unmaterialised day
        // section; target the section first so its rows exist, then the row.
        if let current,
           let day = summaries.first(where: {
               DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: $0.slots) != nil
           })
        {
            proxy.scrollTo(day.dayStartMs, anchor: .top)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(current, anchor: .top)
            }
        }
        followedSlot = current
    }

    private func toggleDetails(slotStartMs: Int64) {
        if expandedSlotStarts.contains(slotStartMs) {
            expandedSlotStarts.remove(slotStartMs)
        } else {
            expandedSlotStarts.insert(slotStartMs)
        }
    }
}

private struct DaySummarySection: View {
    @Environment(\.afterRayCopy) private var copy
    @Environment(\.afterRayLocale) private var afterRayLocale
    let summary: DaySummary
    let nowMs: Int64
    let highlightedSlotStart: Int64?
    let expandedSlotStarts: Set<Int64>
    let onSelectSlot: (DaySlotSummary) -> Void
    let onToggleDetails: (Int64) -> Void

    private var heading: DaySummaryHeading {
        DaySummaryLayout.dateHeading(
            dayStartMs: summary.dayStartMs,
            nowMs: nowMs,
            copy: copy,
            locale: afterRayLocale
        )
    }

    private var visibleSlots: [DaySlotSummary] {
        DaySummaryLayout.displayOrder(summary.slots)
    }

    var body: some View {
        // A real Section: `pinnedViews: [.sectionHeaders]` can only pin a
        // Section's header, so the date stays visible while its rows scroll
        // beneath it. The header wears an opaque backdrop for exactly that
        // moment of overlap.
        Section {
            if visibleSlots.isEmpty {
                Text(copy.recall.noRecordings)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.leading, DaySummaryMetrics.textX)
                    .padding(.vertical, 7)
            } else {
                ForEach(visibleSlots) { slot in
                    DaySummaryRow(
                        slot: slot,
                        isCurrent: slot.slotStartMs == highlightedSlotStart,
                        isExpanded: expandedSlotStarts.contains(slot.slotStartMs),
                        onSelect: { onSelectSlot(slot) },
                        onToggleDetails: { onToggleDetails(slot.slotStartMs) }
                    )
                    .id(slot.slotStartMs)
                }
            }
        } header: {
            Text(DaySummaryLayout.headingLabel(heading))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    heading.isToday ? RecallPalette.ray.opacity(0.9) : .white.opacity(0.55)
                )
                .padding(.leading, DaySummaryMetrics.textX)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.055, green: 0.05, blue: 0.06).opacity(0.94))
                .contextMenu {
                    Button(copy.recall.copyThisDay) {
                        copyToPasteboard(DaySummaryClipboard.dayText(summary))
                    }
                }
        }
    }
}

private struct DaySummaryRow: View {
    @Environment(\.afterRayCopy) private var copy
    let slot: DaySlotSummary
    let isCurrent: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleDetails: () -> Void
    @State private var isHovering = false

    private var text: DaySummaryRowText {
        DaySummaryLayout.rowText(slot: slot)
    }

    private var sections: [DaySummaryExpandedSection] {
        DaySummaryLayout.expandedSections(slot: slot)
    }

    var body: some View {
        // Not a button: the prose is content to read, select and copy. The
        // time chip is the deliberate jump onto the timeline.
        HStack(alignment: .top, spacing: 0) {
            Button(action: onSelect) {
                Text(text.time)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(
                        isCurrent
                            ? RecallPalette.ray
                            : RecallPalette.ray.opacity(isHovering ? 0.88 : 0.72)
                    )
                    .underline(isCurrent || isHovering, color: RecallPalette.ray.opacity(0.7))
                    .frame(width: DaySummaryMetrics.spineX, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this slot in the timeline")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(text.primary)
                    .font(.system(size: 12, weight: text.isT2 ? .semibold : .regular))
                    .foregroundStyle(text.isT2 ? .white.opacity(0.92) : .white.opacity(0.58))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                ForEach(Array(text.detail.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                if !sections.isEmpty {
                    Button(action: onToggleDetails) {
                        Text(isExpanded ? "Hide details" : "Full details")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .underline()
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            if let heading = section.heading {
                                Text(heading)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.78))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Text(section.body)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.64))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }

                if let badge = text.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(
                            badge == "Summary failed"
                                ? RecallPalette.ray.opacity(0.85)
                                : .white.opacity(0.35)
                        )
                }

                if !slot.facts.apps.isEmpty {
                    SlotAppIconStrip(apps: slot.facts.apps)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DaySummaryMetrics.textLeading)
            .padding(.trailing, 8)
        }
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: DaySummaryMetrics.cardRadius, style: .continuous)
                .fill(rowFill)
        }
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(RecallPalette.ray)
                    .frame(width: 2)
                    .padding(.leading, DaySummaryMetrics.spineX - 0.5)
                    .padding(.vertical, 4)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(copy.recall.copyThisSlot) {
                copyToPasteboard(DaySummaryClipboard.slotText(slot))
            }
        }
    }

    private var rowFill: Color {
        if isCurrent { return RecallPalette.ray.opacity(0.10) }
        if isHovering { return Color.white.opacity(0.035) }
        return .clear
    }
}

/// Overlay hosting wears the glass card; a real window supplies its own
/// chrome, so the panel just fills it.
private struct DaySummaryPanelChrome: ViewModifier {
    let style: DaySummaryPanelStyle

    func body(content: Content) -> some View {
        switch style {
        case .overlay:
            content
                .frame(width: RecallGeometry.daySummaryPanelWidth, alignment: .topLeading)
                .frame(maxHeight: RecallGeometry.daySummaryMaxHeight, alignment: .top)
                .recallGlass(in: .rounded(RecallGeometry.daySummaryCornerRadius))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: RecallGeometry.daySummaryCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        case .window:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(red: 0.045, green: 0.04, blue: 0.05))
        }
    }
}

private struct HistorySummaryLoadTrigger: View {
    let isLoading: Bool
    let onAppear: () -> Void

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(RecallPalette.ray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: onAppear)
            }
        }
        .accessibilityLabel(isLoading ? "Loading older summaries" : "Load older summaries")
    }
}

/// Every application the slot touched, as icons in time order. An app whose
/// icon cannot resolve (uninstalled since capture) collapses to nothing —
/// an empty placeholder square only says "something failed here".
private struct SlotAppIconStrip: View {
    let apps: [DayAppFact]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(apps.prefix(DaySummaryMetrics.iconLimit).enumerated()), id: \.offset) { _, app in
                SlotAppIcon(app: app)
            }
            if apps.count > DaySummaryMetrics.iconLimit {
                Text("+\(apps.count - DaySummaryMetrics.iconLimit)")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .accessibilityLabel("Apps used: \(apps.map(\.name).joined(separator: ", "))")
    }
}

private struct SlotAppIcon: View {
    let app: DayAppFact

    private enum Resolution: Equatable {
        case loading
        case loaded(NSImage)
        case absent
    }

    @State private var resolution = Resolution.loading

    var body: some View {
        switch resolution {
        case .loading:
            Color.clear
                .frame(width: 14, height: 14)
                .task(id: app.bundleIdentifier) { await resolve() }
        case .loaded(let icon):
            Image(nsImage: icon)
                .resizable()
                .interpolation(.medium)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .help("\(app.name) · \(DaySummaryLayout.formatDuration(ms: app.ms))")
        case .absent:
            EmptyView()
        }
    }

    private func resolve() async {
        if let hit = AppIconLookup.cachedIcon(bundleIdentifier: app.bundleIdentifier) {
            resolution = .loaded(hit)
            return
        }
        if let icon = await AppIconLookup.iconAsync(bundleIdentifier: app.bundleIdentifier) {
            resolution = .loaded(icon)
        } else {
            resolution = .absent
        }
    }
}
