import AppKit
import XCTest
@testable import AfterRayRecall

final class RecallHotKeyTests: XCTestCase {
    func testDefaultShortcutReadsAsShiftCommandSpace() {
        XCTAssertEqual(RecallHotKey.default.displayString, "⇧⌘Space")
        XCTAssertEqual(RecallHotKey.default.segments, ["⇧", "⌘", "Space"])
    }

    func testModifiersPrintInAppleOrderRegardlessOfPressOrder() {
        let hotKey = RecallHotKey(
            keyCode: 15,
            modifiers: [.command, .control, .shift, .option],
            keyLabel: "R"
        )
        XCTAssertEqual(hotKey.displayString, "⌃⌥⇧⌘R")
    }

    func testCaptureAcceptsAGuardedCombination() {
        let result = RecallHotKey.capture(keyCode: 15, characters: "r", flags: [.command, .option])
        XCTAssertEqual(try result.get(), RecallHotKey(keyCode: 15, modifiers: [.command, .option], keyLabel: "R"))
    }

    func testCaptureRejectsShortcutsThatWouldFireWhileTyping() {
        XCTAssertEqual(
            issue(from: RecallHotKey.capture(keyCode: 15, characters: "r", flags: [])),
            .needsModifier
        )
        XCTAssertEqual(
            issue(from: RecallHotKey.capture(keyCode: 15, characters: "r", flags: [.shift])),
            .needsModifier
        )
    }

    func testCaptureRejectsBareCommandLetterButAllowsCommandPunctuation() {
        XCTAssertEqual(
            issue(from: RecallHotKey.capture(keyCode: 1, characters: "s", flags: [.command])),
            .commandAlone("⌘S")
        )
        XCTAssertEqual(
            issue(from: RecallHotKey.capture(keyCode: 29, characters: "0", flags: [.command])),
            .commandAlone("⌘0")
        )
        XCTAssertEqual(
            try RecallHotKey.capture(keyCode: 49, characters: " ", flags: [.command]).get().displayString,
            "⌘Space"
        )
    }

    func testCaptureRejectsKeysWithNothingToShow() {
        XCTAssertEqual(
            issue(from: RecallHotKey.capture(keyCode: 999, characters: nil, flags: [.command])),
            .unsupportedKey
        )
        XCTAssertEqual(
            issue(from: RecallHotKey.capture(keyCode: 999, characters: "\u{1B}", flags: [.command])),
            .unsupportedKey
        )
    }

    func testNamedKeysWinOverTheTypedCharacter() {
        XCTAssertEqual(RecallHotKey.keyLabel(keyCode: 49, characters: " "), "Space")
        XCTAssertEqual(RecallHotKey.keyLabel(keyCode: 126, characters: nil), "↑")
        XCTAssertEqual(RecallHotKey.keyLabel(keyCode: 122, characters: nil), "F1")
        XCTAssertEqual(RecallHotKey.keyLabel(keyCode: 15, characters: "r"), "R")
    }

    func testSystemConflictOnlyWarnsForTheSpaceShortcutsMacOSKeeps() {
        XCTAssertNil(RecallHotKey.default.systemConflictNote)
        XCTAssertNotNil(
            RecallHotKey(keyCode: 49, modifiers: [.command], keyLabel: "Space").systemConflictNote
        )
        XCTAssertNotNil(
            RecallHotKey(keyCode: 49, modifiers: [.control], keyLabel: "Space").systemConflictNote
        )
        XCTAssertNil(
            RecallHotKey(keyCode: 49, modifiers: [.option], keyLabel: "Space").systemConflictNote
        )
    }

    func testMenuKeyEquivalentSkipsKeysAppKitCannotDraw() {
        XCTAssertEqual(RecallHotKey.default.menuKeyEquivalent, " ")
        XCTAssertEqual(
            RecallHotKey(keyCode: 15, modifiers: [.command, .shift], keyLabel: "R").menuKeyEquivalent,
            "r"
        )
        XCTAssertEqual(
            RecallHotKey(keyCode: 126, modifiers: [.command], keyLabel: "↑").menuKeyEquivalent,
            ""
        )
    }

    func testModifiersRoundTripThroughAppKitFlags() {
        let flags: NSEvent.ModifierFlags = [.command, .option, .capsLock]
        let modifiers = RecallHotKey.Modifiers(flags)
        XCTAssertEqual(modifiers, [.command, .option])
        XCTAssertEqual(modifiers.eventFlags, [.command, .option])
    }

    func testCodableRoundTripKeepsTheRecordedLabel() throws {
        let hotKey = RecallHotKey(keyCode: 126, modifiers: [.control, .option], keyLabel: "↑")
        let decoded = try JSONDecoder().decode(
            RecallHotKey.self,
            from: JSONEncoder().encode(hotKey)
        )
        XCTAssertEqual(decoded, hotKey)
    }

    private func issue(from result: Result<RecallHotKey, RecallHotKeyIssue>) -> RecallHotKeyIssue? {
        guard case .failure(let issue) = result else { return nil }
        return issue
    }
}

@MainActor
final class RecallHotKeyStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "dev.afterray.tests.hotkey.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStartsOnTheDefaultShortcut() {
        XCTAssertEqual(makeStore().hotKey, .default)
        XCTAssertTrue(makeStore().isDefault)
    }

    func testCommitArmsThenPersistsSoALaterLaunchAgrees() {
        let store = makeStore()
        let binding = StubBinding()
        store.binding = binding

        let candidate = RecallHotKey(keyCode: 15, modifiers: [.command, .option], keyLabel: "R")
        XCTAssertTrue(store.commit(candidate))
        XCTAssertEqual(binding.applied, [candidate])
        XCTAssertEqual(store.hotKey, candidate)
        XCTAssertEqual(makeStore().hotKey, candidate)
    }

    func testARefusedShortcutKeepsTheOldOneAndExplainsItself() {
        let store = makeStore()
        let binding = StubBinding()
        binding.acceptsApply = false
        store.binding = binding

        let candidate = RecallHotKey(keyCode: 15, modifiers: [.command, .option], keyLabel: "R")
        XCTAssertFalse(store.commit(candidate))
        XCTAssertEqual(store.hotKey, .default)
        XCTAssertEqual(makeStore().hotKey, .default)
        XCTAssertEqual(
            store.failure,
            "macOS wouldn't hand over ⌥⌘R. Try another combination."
        )
    }

    func testRecordingReleasesTheShortcutAndCancellingPutsItBack() {
        let store = makeStore()
        let binding = StubBinding()
        store.binding = binding

        store.beginRecording()
        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(binding.suspends, 1)

        store.cancelRecording()
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(binding.resumes, 1)
    }

    func testRecordingTheSameShortcutJustStopsRecording() {
        let store = makeStore()
        let binding = StubBinding()
        store.binding = binding

        store.beginRecording()
        XCTAssertTrue(store.commit(.default))
        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(binding.applied.isEmpty)
        XCTAssertEqual(binding.resumes, 1)
    }

    func testRestoreDefaultComesBackFromACustomShortcut() {
        let store = makeStore()
        let binding = StubBinding()
        store.binding = binding
        store.commit(RecallHotKey(keyCode: 15, modifiers: [.command, .option], keyLabel: "R"))
        store.restoreDefault()
        XCTAssertNotNil(store.binding)
        XCTAssertEqual(store.hotKey, .default)
        XCTAssertTrue(store.isDefault)
    }

    func testRejectionMessageSurvivesUntilTheNextAttempt() {
        let store = makeStore()
        store.reject(.needsModifier)
        XCTAssertEqual(store.failure, RecallHotKeyIssue.needsModifier.message)
        store.beginRecording()
        XCTAssertNil(store.failure)
    }

    private func makeStore() -> RecallHotKeyStore {
        RecallHotKeyStore(defaults: defaults, storageKey: "hotkey")
    }
}

@MainActor
private final class StubBinding: RecallHotKeyBinding {
    var acceptsApply = true
    var applied: [RecallHotKey] = []
    var suspends = 0
    var resumes = 0

    func hotKeyBindingSuspend() { suspends += 1 }
    func hotKeyBindingResume() { resumes += 1 }

    func hotKeyBindingApply(_ hotKey: RecallHotKey) -> Bool {
        guard acceptsApply else { return false }
        applied.append(hotKey)
        return true
    }
}

final class AfterRayGreetingTests: XCTestCase {
    func testGreetingFollowsTheClock() {
        XCTAssertEqual(AfterRayGreeting.text(hour: 8), "Good morning.")
        XCTAssertEqual(AfterRayGreeting.text(hour: 13), "Good afternoon.")
        XCTAssertEqual(AfterRayGreeting.text(hour: 20), "Good evening.")
        XCTAssertEqual(AfterRayGreeting.text(hour: 2), "Still up?")
        XCTAssertEqual(AfterRayGreeting.text(hour: 23), "Still up?")
    }
}
