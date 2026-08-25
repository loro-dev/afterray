import AppKit
import SwiftUI
import XCTest
@testable import AfterRayRecall

final class DaySummaryTitleLayoutTests: XCTestCase {
    @MainActor
    func testActionGroupFitsReservedWidth() {
        let host = NSHostingView(
            rootView: DaySummaryTitleActions(
                isVisible: true,
                onCopy: {},
                onOpenMarkdown: {}
            )
        )

        XCTAssertLessThanOrEqual(host.fittingSize.width, DaySummaryTitleLayout.actionWidth)
    }

    @MainActor
    func testHoverVisibilityDoesNotReflowWrappedTitle() {
        let hidden = titleHost(isVisible: false).fittingSize
        let visible = titleHost(isVisible: true).fittingSize

        XCTAssertEqual(hidden, visible)
    }

    func testActionPositionUsesRenderedLastLineBounds() {
        var bounds = Text.Layout.TypographicBounds()
        bounds.origin = CGPoint(x: 0, y: 27)
        bounds.width = 71
        bounds.ascent = 10
        bounds.descent = 3

        let textOrigin = CGPoint(x: 12, y: 5)
        let lineRect = bounds.rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y)
        let position = DaySummaryTitleLayout.actionPosition(
            textOrigin: textOrigin,
            lastLineBounds: bounds
        )
        let actionLeading = position.x - DaySummaryTitleLayout.actionWidth / 2

        XCTAssertEqual(actionLeading, 91)
        XCTAssertEqual(position.y, lineRect.midY)
    }

    @MainActor
    private func titleHost(isVisible: Bool) -> NSHostingView<some View> {
        NSHostingView(
            rootView: DaySummaryTitleLayout(
                title: "Review Loro Streams deep security audit report",
                isEmphasized: true,
                actions: DaySummaryTitleActions(
                    isVisible: isVisible,
                    onCopy: {},
                    onOpenMarkdown: {}
                )
            )
            .frame(width: 240, alignment: .leading)
        )
    }
}
