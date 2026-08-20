import XCTest
@testable import AfterRayRecall

final class DaySummaryTitleLayoutTests: XCTestCase {
    func testLongEnglishTitleLeavesRoomAfterItsLastRenderedCharacter() {
        assertActionsFit(
            title: "Lody search logic debug and overlay scroll listener fix",
            availableWidth: 240,
            actionWidth: 42
        )
    }

    func testLongChineseTitleLeavesRoomAfterItsLastRenderedCharacter() {
        assertActionsFit(
            title: "AfterRay 多线推进：退出竞态回修、麦克风权限简化、记忆迁移合入",
            availableWidth: 240,
            actionWidth: 42
        )
    }

    private func assertActionsFit(
        title: String,
        availableWidth: CGFloat,
        actionWidth: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let titleWidth = DaySummaryTitleLayout.resolvedTitleWidth(
            title: title,
            availableWidth: availableWidth,
            actionWidth: actionWidth
        )
        let lastLineWidth = DaySummaryTitleLayout.lastLineWidth(
            title: title,
            width: titleWidth
        )
        XCTAssertGreaterThan(titleWidth, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(titleWidth, availableWidth, file: file, line: line)
        XCTAssertLessThanOrEqual(
            lastLineWidth + DaySummaryTitleLayout.actionSpacing + actionWidth,
            availableWidth,
            file: file,
            line: line
        )
    }
}
