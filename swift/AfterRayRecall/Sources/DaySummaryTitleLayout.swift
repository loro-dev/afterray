import SwiftUI

// @dec:summary-inline-markdown-actions — docs/decisions/active/product/2026-08-20-summary-inline-markdown-actions.md
/// Places the action group immediately after the title's final rendered
/// character. The group keeps its space while hidden so entering a row never
/// reflows the document underneath the pointer.
struct DaySummaryTitleLayout: View {
    static let actionSpacing: CGFloat = 8
    static let actionWidth: CGFloat = 42

    let title: String
    let isEmphasized: Bool
    let actions: DaySummaryTitleActions?

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: isEmphasized ? .semibold : .regular))
            .foregroundStyle(isEmphasized ? .white.opacity(0.92) : .white.opacity(0.58))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.trailing, actions == nil ? 0 : Self.actionSpacing + Self.actionWidth)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { proxy in
                    if let actions,
                       let anchoredLayout = layouts.first,
                       let lastLine = anchoredLayout.layout.last
                    {
                        let textOrigin = proxy[anchoredLayout.origin]
                        let lineBounds = lastLine.typographicBounds
                        actions
                            .frame(width: Self.actionWidth, alignment: .leading)
                            .position(Self.actionPosition(
                                textOrigin: textOrigin,
                                lastLineBounds: lineBounds
                            ))
                    }
                }
            }
    }

    static func actionPosition(
        textOrigin: CGPoint,
        lastLineBounds: Text.Layout.TypographicBounds
    ) -> CGPoint {
        let lineRect = lastLineBounds.rect.offsetBy(
            dx: textOrigin.x,
            dy: textOrigin.y
        )
        return CGPoint(
            x: lineRect.maxX + actionSpacing + actionWidth / 2,
            y: lineRect.midY
        )
    }
}
