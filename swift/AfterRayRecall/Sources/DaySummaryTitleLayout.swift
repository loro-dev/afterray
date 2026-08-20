import AppKit
import CoreText
import SwiftUI

// @dec:summary-inline-markdown-actions — docs/decisions/active/product/2026-08-20-summary-inline-markdown-actions.md
/// Places the action group immediately after the title's final rendered
/// character. The group keeps its space while hidden so entering a row never
/// reflows the document underneath the pointer.
struct DaySummaryTitleLayout: Layout {
    static let actionSpacing: CGFloat = 8

    let title: String

    struct Cache {
        var title = ""
        var availableWidth: CGFloat = -1
        var actionSize = CGSize.zero
        var titleWidth: CGFloat = 0
        var titleSize = CGSize.zero
        var lastLineWidth: CGFloat = 0
    }

    struct ResolvedMetrics {
        let titleWidth: CGFloat
        let lastLineWidth: CGFloat
    }

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard subviews.count == 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        let actionSize = subviews[1].sizeThatFits(.unspecified)
        let idealTitleSize = subviews[0].sizeThatFits(.unspecified)
        let availableWidth = max(
            1,
            proposal.width ?? idealTitleSize.width + Self.actionSpacing + actionSize.width
        )
        updateCache(
            availableWidth: availableWidth,
            actionSize: actionSize,
            proposal: proposal,
            subviews: subviews,
            cache: &cache
        )

        return CGSize(
            width: proposal.width ?? min(
                availableWidth,
                cache.lastLineWidth + Self.actionSpacing + actionSize.width
            ),
            height: max(cache.titleSize.height, actionSize.height)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
            return
        }

        let actionSize = subviews[1].sizeThatFits(.unspecified)
        updateCache(
            availableWidth: max(1, bounds.width),
            actionSize: actionSize,
            proposal: proposal,
            subviews: subviews,
            cache: &cache
        )

        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: cache.titleWidth, height: proposal.height)
        )
        subviews[1].place(
            at: CGPoint(
                x: bounds.minX + cache.lastLineWidth + Self.actionSpacing,
                y: bounds.minY + max(0, cache.titleSize.height - actionSize.height)
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(actionSize)
        )
    }

    static func resolvedTitleWidth(
        title: String,
        availableWidth: CGFloat,
        actionWidth: CGFloat
    ) -> CGFloat {
        resolvedMetrics(
            title: title,
            availableWidth: availableWidth,
            actionWidth: actionWidth
        ).titleWidth
    }

    static func resolvedMetrics(
        title: String,
        availableWidth: CGFloat,
        actionWidth: CGFloat
    ) -> ResolvedMetrics {
        let fullWidth = max(1, availableWidth)
        let fullLastLineWidth = lastLineWidth(title: title, width: fullWidth)
        if fullLastLineWidth + actionSpacing + actionWidth <= fullWidth {
            return ResolvedMetrics(titleWidth: fullWidth, lastLineWidth: fullLastLineWidth)
        }
        let titleWidth = max(1, fullWidth - actionSpacing - actionWidth)
        return ResolvedMetrics(
            titleWidth: titleWidth,
            lastLineWidth: lastLineWidth(title: title, width: titleWidth)
        )
    }

    private func updateCache(
        availableWidth: CGFloat,
        actionSize: CGSize,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard cache.title != title
            || cache.availableWidth != availableWidth
            || cache.actionSize != actionSize
        else { return }

        let metrics = Self.resolvedMetrics(
            title: title,
            availableWidth: availableWidth,
            actionWidth: actionSize.width
        )
        cache.title = title
        cache.availableWidth = availableWidth
        cache.actionSize = actionSize
        cache.titleWidth = metrics.titleWidth
        cache.titleSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: metrics.titleWidth, height: proposal.height)
        )
        cache.lastLineWidth = metrics.lastLineWidth
    }

    static func lastLineWidth(title: String, width: CGFloat) -> CGFloat {
        guard !title.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .paragraphStyle: paragraph,
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: max(1, width), height: 10_000),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        guard let line = (CTFrameGetLines(frame) as? [CTLine])?.last else { return 0 }
        return max(
            0,
            CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        )
    }
}
