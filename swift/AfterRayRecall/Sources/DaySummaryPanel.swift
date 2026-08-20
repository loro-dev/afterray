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

/// The history-summary panel. The list is windowed (`HistoryListScrollView`);
/// see `context/history-list-scrolling.md` for what makes that safe and for
/// the budget every row body has to live inside. Copy is structured (this
/// slot, this day, all loaded days).
///
/// This outer type is a shell whose only job is to collapse the two per-frame
/// inputs and hand the result to an `Equatable` body. Scrubbing the timeline
/// rebuilds `RecallView` on every frame, and the panel is a large subtree —
/// windowed list, glass chrome, a blurred shadow. Skipping it wholesale when
/// nothing it draws has changed is the difference between a scrub that drops
/// frames and one that does not.
public struct DaySummaryPanel: View {
    var style: DaySummaryPanelStyle = .overlay
    var onPopOut: (() -> Void)? = nil
    let summaries: [DaySummary]
    /// The slot the playhead sits in — resolved once in `init`, not a stored
    /// `playheadMs`.
    ///
    /// Scrubbing the timeline republishes `playheadMs` every frame, but the
    /// panel only ever asks which slot to highlight, and that changes when the
    /// playhead crosses a slot boundary — every half hour of recorded time,
    /// not 60 times a second. Storing the raw playhead made every stored
    /// property of this view differ on every frame, which rebuilt all ~90 rows
    /// for a highlight that had not moved. It was also read once *per row*
    /// (`isCurrent:`), so the O(days x slots) scan ran ~90 times a pass.
    let highlightedSlotStart: Int64?
    /// Local midnight, not a live clock — see `DaySummaryLayout.dayStartMs`.
    let todayStartMs: Int64
    let hasMore: Bool
    let totalDays: Int?
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
        totalDays: Int? = nil,
        isLoadingMore: Bool,
        followPulse: Int,
        onSelectSlot: @escaping (DaySlotSummary) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.style = style
        self.onPopOut = onPopOut
        self.summaries = summaries
        // Both collapse a per-frame value to one that only changes when the
        // panel would actually look different.
        self.highlightedSlotStart = summaries.lazy.compactMap {
            DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: $0.slots)
        }.first
        self.todayStartMs = DaySummaryLayout.dayStartMs(atMs: nowMs)
        self.hasMore = hasMore
        self.totalDays = totalDays
        self.isLoadingMore = isLoadingMore
        self.followPulse = followPulse
        self.onSelectSlot = onSelectSlot
        self.onLoadMore = onLoadMore
    }

    public var body: some View {
        content.equatable()
    }

    /// Split out so the equality this relies on is directly testable; `body`
    /// hands SwiftUI an `EquatableView`, which a test cannot look inside.
    var content: DaySummaryPanelContent {
        DaySummaryPanelContent(
            style: style,
            onPopOut: onPopOut,
            summaries: summaries,
            highlightedSlotStart: highlightedSlotStart,
            todayStartMs: todayStartMs,
            hasMore: hasMore,
            totalDays: totalDays,
            isLoadingMore: isLoadingMore,
            followPulse: followPulse,
            onSelectSlot: onSelectSlot,
            onLoadMore: onLoadMore
        )
    }
}

/// Everything the panel actually draws, behind one equality check.
///
/// `==` compares data only. The closures are new instances on every pass and
/// would make the panel unequal forever, which is exactly the update this
/// exists to skip — the same trade `DaySummaryRow` makes, and it bounds
/// closure staleness the same way: a held closure is at most one *data*
/// change old, not one frame old, because any change to what the panel draws
/// refreshes it. Do not add a closure here that captures something absent
/// from `==`.
// Internal, not private, so `DaySummaryPanelScrubTests` can assert the
// equality that the whole optimisation rests on.
struct DaySummaryPanelContent: View, Equatable {
    @State private var expandedSlotStarts: Set<Int64> = []
    @State private var followedSlot: Int64?
    @State private var followGeneration = 0
    @State private var stickyChip: DayHeadingChip?
    let style: DaySummaryPanelStyle
    let onPopOut: (() -> Void)?
    let summaries: [DaySummary]
    let highlightedSlotStart: Int64?
    let todayStartMs: Int64
    let hasMore: Bool
    let totalDays: Int?
    let isLoadingMore: Bool
    let followPulse: Int
    let onSelectSlot: (DaySlotSummary) -> Void
    let onLoadMore: () -> Void

    static func == (lhs: DaySummaryPanelContent, rhs: DaySummaryPanelContent) -> Bool {
        lhs.highlightedSlotStart == rhs.highlightedSlotStart
            && lhs.followPulse == rhs.followPulse
            && lhs.isLoadingMore == rhs.isLoadingMore
            && lhs.hasMore == rhs.hasMore
            && lhs.totalDays == rhs.totalDays
            && lhs.todayStartMs == rhs.todayStartMs
            && lhs.style == rhs.style
            && (lhs.onPopOut == nil) == (rhs.onPopOut == nil)
            && lhs.summaries == rhs.summaries
    }


    private var dayCountLabel: String {
        HistoryDayCount.label(totalDays: totalDays)
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
            Text("Summaries")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 8)
            if !dayCountLabel.isEmpty {
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
                .help("Open as a window")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contextMenu {
            Button("Copy All Loaded Days") {
                copyToPasteboard(DaySummaryClipboard.historyText(summaries))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing recorded yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
            Text("Your past days will appear here as AfterRay captures them.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var listItems: [HistoryListItem] {
        HistoryListItems.build(
            summaries: summaries,
            nowMs: todayStartMs,
            expandedSlotStarts: expandedSlotStarts,
            hasMore: hasMore
        )
    }

    private var historyList: some View {
        HistoryListScrollView(
            items: listItems,
            isLoadingMore: isLoadingMore,
            hasMore: hasMore,
            showsIndicator: style == .window,
            followID: highlightedSlotStart.map { HistoryListItem.slotID(slotStartMs: $0) },
            followGeneration: followGeneration,
            onLoadMore: {
                if hasMore, !isLoadingMore { onLoadMore() }
            },
            onStickyChip: { chip in
                if chip != stickyChip { stickyChip = chip }
            },
            row: { item in listRow(for: item) }
        )
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(width: 1)
                .padding(.leading, 6 + DaySummaryMetrics.spineX)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            if let stickyChip {
                Text(stickyChip.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        stickyChip.isToday
                            ? RecallPalette.ray.opacity(0.9)
                            : .white.opacity(0.62)
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color(red: 0.055, green: 0.05, blue: 0.06).opacity(0.96),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .padding(.leading, 6 + DaySummaryMetrics.textX)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
                    .animation(nil, value: stickyChip.label)
            }
        }
        .frame(
            maxHeight: style == .overlay ? RecallGeometry.daySummaryListMaxHeight : .infinity
        )
        .onAppear { requestFollow(settle: true) }
        .onChange(of: highlightedSlotStart) { _, _ in
            requestFollow(settle: false)
        }
        .onChange(of: followPulse) { _, _ in
            requestFollow(settle: true)
        }
    }

    private func requestFollow(settle: Bool) {
        let current = highlightedSlotStart
        guard HistoryDocumentFollow.shouldFollow(
            previousSlot: followedSlot,
            currentSlot: current,
            settleRequested: settle
        ) else { return }
        if ScrollFenceRegistry.shared.pointerInsideAnyFence() { return }
        followGeneration += 1
        followedSlot = current
    }

    private func toggleDetails(slotStartMs: Int64) {
        if expandedSlotStarts.contains(slotStartMs) {
            expandedSlotStarts.remove(slotStartMs)
        } else {
            expandedSlotStarts.insert(slotStartMs)
        }
    }

    @ViewBuilder
    private func listRow(for item: HistoryListItem) -> some View {
        switch item {
        case let .heading(dayStartMs, label, isToday):
            DaySummaryHeadingRow(
                dayStartMs: dayStartMs,
                label: label,
                isToday: isToday,
                onCopyDay: {
                    guard let day = summaries.first(where: { $0.dayStartMs == dayStartMs })
                    else { return }
                    copyToPasteboard(DaySummaryClipboard.dayText(day))
                }
            )
        case let .slot(slot, expanded):
            // `.equatable()` is load-bearing, not a micro-optimization. The
            // list is eager, so without it every enclosing update re-runs all
            // ~90 row bodies — and the panel is rebuilt by anything upstream
            // that changes, including closures that are recreated every pass
            // and so can never compare equal. With it, a pass that moved
            // nothing but the playhead touches only the two rows whose
            // `isCurrent` actually flipped.
            DaySummaryRow(
                slot: slot,
                isCurrent: slot.slotStartMs == highlightedSlotStart,
                isExpanded: expanded,
                onSelect: { onSelectSlot(slot) },
                onToggleDetails: { toggleDetails(slotStartMs: slot.slotStartMs) }
            )
            .equatable()
        case .loadMore:
            HistorySummaryLoadTrigger(isLoading: isLoadingMore)
        }
    }
}


private struct DaySummaryHeadingRow: View {
    let dayStartMs: Int64
    let label: String
    let isToday: Bool
    let onCopyDay: () -> Void

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(
                isToday ? RecallPalette.ray.opacity(0.9) : .white.opacity(0.55)
            )
            .padding(.leading, DaySummaryMetrics.textX)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Copy This Day", action: onCopyDay)
            }
    }
}

private struct DaySummaryRow: View, Equatable {
    let slot: DaySlotSummary
    let isCurrent: Bool
    let isExpanded: Bool
    let onSelect: () -> Void
    let onToggleDetails: () -> Void
    @State private var isHovering = false

    /// Data only — closures are recreated on every pass and would make every
    /// row unequal forever, which is exactly the update this is here to skip.
    ///
    /// Safe because neither closure outlives its data: `onSelect` captures
    /// `slot`, which is compared here, and `onToggleDetails` captures only
    /// `slot.slotStartMs` and writes through `@State`, whose storage SwiftUI
    /// owns and keeps current regardless of which copy of the struct calls it.
    /// Hover is `@State` and invalidates the row directly, so it does not need
    /// to participate.
    static func == (lhs: DaySummaryRow, rhs: DaySummaryRow) -> Bool {
        lhs.isCurrent == rhs.isCurrent
            && lhs.isExpanded == rhs.isExpanded
            && lhs.slot == rhs.slot
    }

    var body: some View {
        // Bound once. These were computed properties, so `text.time`,
        // `text.primary`, `text.detail` and `text.badge` each re-derived the
        // whole thing, and `sections` re-parsed the card's Markdown — on every
        // body pass, which is every scroll frame and every playhead tick.
        let text = DaySummaryLayout.rowText(slot: slot)
        let hasDetail = DaySummaryLayout.hasExpandableDetail(slot: slot)

        // Not a button: the prose is content to read, select and copy. The
        // time chip is the deliberate jump onto the timeline.
        return HStack(alignment: .top, spacing: 0) {
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

                if hasDetail {
                    Button(action: onToggleDetails) {
                        Text(isExpanded ? "Hide details" : "Full details")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .underline()
                    }
                    .buttonStyle(.plain)

                    // Parsed only for the card the user actually opened.
                    if isExpanded {
                        let sections = DaySummaryLayout.expandedSections(slot: slot)
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
            Button("Copy This Slot") {
                copyToPasteboard(DaySummaryClipboard.slotText(slot))
            }
        }
        // One element per card instead of one per Text, button and icon.
        //
        // Accessibility attachments are rebuilt on every AttributeGraph
        // update and each rebuild walks the node's ancestors, so the cost is
        // nodes x depth x frames — and the panel is drawn inside the same
        // hosting view as the timeline, which relayouts on every frame of a
        // scrub. The panel's share of that was ~3.1ms of the ~8.7ms it added
        // to each frame.
        //
        // `.combine` drops the descendants' own actions, so both are restated
        // here; a card read as one item with two actions is better VoiceOver
        // than eight fragments anyway.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .accessibilityAction(named: "Open in timeline", onSelect)
        .accessibilityAction(
            named: isExpanded ? "Hide details" : "Show full details",
            onToggleDetails
        )
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

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(RecallPalette.ray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                Color.clear.frame(height: 1)
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
