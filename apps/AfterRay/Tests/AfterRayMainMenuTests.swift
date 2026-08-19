import AppKit
import XCTest
@testable import AfterRayApp

final class AfterRayMainMenuTests: XCTestCase {
    func testEditMenuTurnsStandardShortcutsIntoFirstResponderActions() {
        let items = AfterRayMainMenu.editMenuItem().submenu?.items ?? []
        XCTAssertEqual(title(of: items, matching: "z", includingShift: false), "Undo")
        XCTAssertEqual(title(of: items, matching: "z", includingShift: true), "Redo")
        XCTAssertEqual(title(of: items, matching: "x", includingShift: false), "Cut")
        XCTAssertEqual(title(of: items, matching: "c", includingShift: false), "Copy")
        XCTAssertEqual(title(of: items, matching: "v", includingShift: false), "Paste")
        XCTAssertEqual(title(of: items, matching: "a", includingShift: false), "Select All")

        let paste = items.first { $0.title == "Paste" }
        XCTAssertEqual(paste?.action, #selector(NSText.paste(_:)))
        XCTAssertNil(paste?.target, "target must be nil so the first responder (the composer) gets paste:")
    }

    private func title(
        of items: [NSMenuItem],
        matching key: String,
        includingShift: Bool
    ) -> String? {
        items.first { item in
            item.keyEquivalent == key
                && item.keyEquivalentModifierMask.contains(.shift) == includingShift
        }?.title
    }
}
