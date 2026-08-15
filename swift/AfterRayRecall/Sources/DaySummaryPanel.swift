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

/// The history-summary panel renders as one attributed document in an
/// `NSTextView`, so text selection is continuous across bullets, rows and
/// days — a list of SwiftUI views can never extend a selection past a single
/// `Text`. The date that used to pin as a section header becomes a chip
/// under the panel header, tracking whichever day is scrolled into view.
public struct DaySummaryPanel: View {
    @State private var topDayHeading: String?
    var style: DaySummaryPanelStyle = .overlay
    var onPopOut: (() -> Void)? = nil
    let summaries: [DaySummary]
    let playheadMs: Int64
    let nowMs: Int64
    let hasMore: Bool
    let isLoadingMore: Bool
    /// Bumped by the overlay when a scrub settles; the one moment the list
    /// follows the playhead. Following every half-hour crossing mid-glide
    /// was a scrollTo storm that churned rows (and their thumbnails) faster
    /// than the main thread could keep up.
    let followPulse: Int
    let onSelectSlot: (Int64) -> Void
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
        onSelectSlot: @escaping (Int64) -> Void,
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

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                historyList
                    .overlay(alignment: .topLeading) { dayChip }
            }
        }
        .modifier(DaySummaryPanelChrome(style: style))
        .accessibilityIdentifier("history-summary-panel")
    }

    /// The scroll-tracking replacement for the pinned section header: the
    /// document flow cannot pin a view, so once a day's own heading scrolls
    /// off the top, this chip floats over the list carrying the same text.
    @ViewBuilder
    private var dayChip: some View {
        if let topDayHeading {
            Text(topDayHeading)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    topDayHeading.hasPrefix("Today")
                        ? RecallPalette.ray.opacity(0.9)
                        : .white.opacity(0.62)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Color(red: 0.055, green: 0.05, blue: 0.06).opacity(0.94),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                // Lands on the document's own text edge, so the chip reads as
                // the heading it stands in for rather than a second element.
                .padding(.leading, 62)
                .padding(.top, 2)
                .animation(nil, value: topDayHeading)
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Summaries")
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
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    private var historyList: some View {
        HistoryDocumentView(
            summaries: summaries,
            playheadMs: playheadMs,
            nowMs: nowMs,
            hasMore: hasMore,
            isLoadingMore: isLoadingMore,
            followPulse: followPulse,
            fillsHeight: style == .window,
            onSelectSlot: onSelectSlot,
            onLoadMore: onLoadMore,
            onTopDayChange: { heading in
                if topDayHeading != heading { topDayHeading = heading }
            }
        )
        .frame(
            maxHeight: style == .overlay ? RecallGeometry.daySummaryListMaxHeight : .infinity,
            alignment: .top
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
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
