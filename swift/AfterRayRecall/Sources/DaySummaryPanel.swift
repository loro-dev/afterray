import SwiftUI

/// The history-summary panel is deliberately a single lazy scroll view: it
/// can keep walking toward the earliest capture without retaining every row
/// in the SwiftUI view tree or asking each row to hit the daemon.
struct DaySummaryPanel: View {
    let summaries: [DaySummary]
    let playheadMs: Int64
    let nowMs: Int64
    let hasMore: Bool
    let isLoadingMore: Bool
    let onSelectSlot: (Int64) -> Void
    let onLoadMore: () -> Void

    private var highlightedStart: Int64? {
        summaries.lazy.compactMap {
            DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: $0.slots)
        }.first
    }

    private var dayCountLabel: String {
        let count = summaries.count
        return count == 1 ? "1 DAY" : "\(count) DAYS"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .frame(width: RecallGeometry.daySummaryPanelWidth, alignment: .topLeading)
        .frame(maxHeight: RecallGeometry.daySummaryMaxHeight, alignment: .top)
        .recallGlass(in: .rounded(RecallGeometry.daySummaryCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: RecallGeometry.daySummaryCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        .accessibilityIdentifier("history-summary-panel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HISTORY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(RecallPalette.ray.opacity(0.78))
                Text("Summaries")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            Spacer(minLength: 8)
            if !summaries.isEmpty {
                Text(dayCountLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
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

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(summaries, id: \.dayStartMs) { summary in
                        DaySummarySection(
                            summary: summary,
                            playheadMs: playheadMs,
                            nowMs: nowMs,
                            onSelectSlot: onSelectSlot
                        )
                    }
                    if hasMore {
                        HistorySummaryLoadTrigger(isLoading: isLoadingMore, onAppear: onLoadMore)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: RecallGeometry.daySummaryListMaxHeight)
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: highlightedStart) { _, _ in
                scrollToCurrent(proxy)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let highlightedStart else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(highlightedStart, anchor: .center)
        }
    }
}

private struct DaySummarySection: View {
    let summary: DaySummary
    let playheadMs: Int64
    let nowMs: Int64
    let onSelectSlot: (Int64) -> Void

    private var heading: DaySummaryHeading {
        DaySummaryLayout.dateHeading(dayStartMs: summary.dayStartMs, nowMs: nowMs)
    }

    private var highlightedStart: Int64? {
        DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: summary.slots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading.kicker)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.25)
                    .foregroundStyle(heading.isToday ? RecallPalette.ray.opacity(0.85) : .white.opacity(0.45))
                Text(heading.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                Text("\(summary.slots.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.32))
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 4)

            if summary.slots.isEmpty {
                Text("No recordings")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            } else {
                ForEach(summary.slots) { slot in
                    DaySummaryRow(
                        slot: slot,
                        isCurrent: slot.slotStartMs == highlightedStart,
                        onSelect: { onSelectSlot(slot.slotStartMs) }
                    )
                    .id(slot.slotStartMs)
                }
            }
        }
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

private struct DaySummaryRow: View {
    let slot: DaySlotSummary
    let isCurrent: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    private var text: DaySummaryRowText {
        DaySummaryLayout.rowText(slot: slot)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text.time)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? RecallPalette.ray : .white.opacity(0.38))
                    .frame(width: 42, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.primary)
                        .font(.system(size: 12, weight: text.isT2 ? .medium : .regular))
                        .foregroundStyle(text.isT2 ? .white.opacity(0.92) : .white.opacity(0.56))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !text.detail.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(text.detail.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("·")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.3))
                                    Text(line)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.66))
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 1)
                    }

                    if let badge = text.badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(badgeTint(badge).opacity(0.9))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(badgeTint(badge).opacity(0.14), in: Capsule())
                            .accessibilityLabel("Summary status: \(badge)")
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            }
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(RecallPalette.ray)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
        .help(text.primary)
    }

    private func badgeTint(_ badge: String) -> Color {
        badge == "Summary failed" ? RecallPalette.ray : .white.opacity(0.5)
    }

    private var rowFill: Color {
        if isCurrent { return RecallPalette.ray.opacity(0.13) }
        if isHovering { return Color.white.opacity(0.05) }
        return .clear
    }
}
