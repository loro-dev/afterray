import SwiftUI

// @dec:summary-inline-markdown-actions — docs/decisions/active/product/2026-08-20-summary-inline-markdown-actions.md
struct DaySummaryTitleActions: View {
    @Environment(\.afterRayCopy) private var copy
    let isVisible: Bool
    let onCopy: () -> Void
    let onOpenMarkdown: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(copy.recall.copySummary, systemImage: "doc.on.doc", action: onCopy)
                .labelStyle(.iconOnly)
                .help(copy.recall.copySummary)

            Button(
                copy.recall.openSummaryAsMarkdown,
                systemImage: "doc.text",
                action: onOpenMarkdown
            )
            .labelStyle(.iconOnly)
            .help(copy.recall.openSummaryAsMarkdown)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .buttonStyle(RecallGlassPressStyle())
        .controlSize(.mini)
        .fixedSize()
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }
}
