import XCTest
@testable import AfterRayRecall

final class SettingsDeveloperUnlockTests: XCTestCase {
    func testLoroUnlocksOnlyAfterTheCompleteSequence() {
        var sequence = SettingsDeveloperUnlockSequence()

        XCTAssertFalse(sequence.consume("l", at: 0.0))
        XCTAssertFalse(sequence.consume("o", at: 0.1))
        XCTAssertFalse(sequence.consume("r", at: 0.2))
        XCTAssertTrue(sequence.consume("o", at: 0.3))
    }

    func testUnlockSequenceIsCaseInsensitiveAndRestartsFromANewL() {
        var sequence = SettingsDeveloperUnlockSequence()

        XCTAssertFalse(sequence.consume("l", at: 0.0))
        XCTAssertFalse(sequence.consume("L", at: 0.1))
        XCTAssertFalse(sequence.consume("O", at: 0.2))
        XCTAssertFalse(sequence.consume("R", at: 0.3))
        XCTAssertTrue(sequence.consume("O", at: 0.4))
    }

    func testUnlockSequenceExpiresAfterAPause() {
        var sequence = SettingsDeveloperUnlockSequence()

        XCTAssertFalse(sequence.consume("l", at: 0.0))
        XCTAssertFalse(sequence.consume("o", at: 2.1))
        XCTAssertFalse(sequence.consume("l", at: 2.2))
        XCTAssertFalse(sequence.consume("o", at: 2.3))
        XCTAssertFalse(sequence.consume("r", at: 2.4))
        XCTAssertTrue(sequence.consume("o", at: 2.5))
    }

    func testDeveloperPageOnlyAppearsWhenEnabled() {
        XCTAssertFalse(
            AfterRaySettingsPage.visiblePages(developerOptionsEnabled: false).contains(.developer)
        )
        XCTAssertEqual(
            AfterRaySettingsPage.visiblePages(developerOptionsEnabled: true),
            [.general, .models, .advanced, .developer, .diagnostics]
        )
    }
}
