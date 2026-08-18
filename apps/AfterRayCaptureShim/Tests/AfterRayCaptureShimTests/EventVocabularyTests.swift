@testable import AfterRayCapturePolicy
import XCTest

/// The one guard left after CAP-005 was retired.
///
/// The guard itself lives in the shim: `InputEventMonitor` resolves the element
/// a keystroke landed on, asks these questions, and never accumulates a
/// character or reads a value when the answer is yes. Nothing on the Rust side
/// re-checks — a parser cannot know what the field was — so this is where the
/// rule is tested.
final class SecureInputGuardTests: XCTestCase {
    func testAPasswordFieldIsSecure() {
        XCTAssertTrue(SecureInputGuard.isSecure(subrole: "AXSecureTextField"))
    }

    func testAnOrdinaryFieldIsNot() {
        XCTAssertFalse(SecureInputGuard.isSecure(subrole: "AXSearchField", label: "Search"))
        XCTAssertFalse(SecureInputGuard.isSecure(subrole: nil, label: "Message"))
        XCTAssertFalse(SecureInputGuard.isSecure(subrole: nil, label: nil))
    }

    /// An app that puts the subrole on the wrapper instead of the field does not
    /// thereby get to leak the field.
    func testASecureAncestorIsSecure() {
        XCTAssertTrue(
            SecureInputGuard.isSecure(
                subrole: nil,
                label: "Enter",
                ancestorSubroles: ["AXStandardWindow", "AXSecureTextField"]
            )
        )
    }

    /// Electron and web apps often render a password box as a plain text field.
    func testASecretLookingLabelIsSecure() {
        XCTAssertTrue(SecureInputGuard.isSecure(subrole: "AXTextField", label: "Password"))
        XCTAssertTrue(SecureInputGuard.isSecure(subrole: nil, label: "Confirm passphrase"))
        XCTAssertTrue(SecureInputGuard.isSecure(subrole: nil, label: "请输入密码"))
        XCTAssertTrue(SecureInputGuard.isSecure(subrole: nil, label: "API Secret"))
    }

    /// False positives cost one field's text and nothing else, which is the
    /// direction this is allowed to be wrong in.
    func testTheLabelCheckIsDeliberatelyBroad() {
        XCTAssertTrue(SecureInputGuard.looksLikeSecretLabel("Secret Santa list"))
        XCTAssertFalse(SecureInputGuard.looksLikeSecretLabel("Passport number"))
    }
}

/// Keystream assembly — the secondary content channel.
final class TypedTextRunTests: XCTestCase {
    private func run(_ inputs: [String]) -> TypedTextRun {
        var run = TypedTextRun()
        for input in inputs { run.append(input) }
        return run
    }

    func testCharactersAccumulateInOrder() {
        XCTAssertEqual(run(["h", "e", "l", "l", "o"]).recorded, "hello")
    }

    func testBackspaceEditsTheRun() {
        XCTAssertEqual(run(["c", "a", "t", "\u{8}", "p"]).recorded, "cap")
        XCTAssertEqual(run(["a", "\u{7F}", "b"]).recorded, "b")
    }

    func testBackspaceOnAnEmptyRunIsHarmless() {
        XCTAssertNil(run(["\u{8}", "\u{8}"]).recorded)
    }

    /// Arrow keys, function keys and control chords carry no content.
    func testNonContentKeysAreDropped() {
        XCTAssertNil(run(["\u{F700}", "\u{F701}", "\u{1}", "\u{1B}"]).recorded)
        XCTAssertEqual(run(["a", "\u{F702}", "b"]).recorded, "ab")
    }

    func testSpacesAndCJKSurvive() {
        XCTAssertEqual(run(["w", "s", "m", " ", "t", "o"]).recorded, "wsm to")
        XCTAssertEqual(run(["你", "好"]).recorded, "你好")
    }

    func testALongRunIsClippedAndSaysSo() {
        var long = TypedTextRun()
        for _ in 0..<(TypedTextRun.maxChars + 20) { long.append("x") }
        let recorded = long.recorded ?? ""
        XCTAssertTrue(recorded.hasSuffix(TypedTextRun.truncationMarker))
        XCTAssertEqual(recorded.count, TypedTextRun.maxChars + TypedTextRun.truncationMarker.count)
    }
}

/// The primary content channel: what the field held at the event's instant.
final class ComposedFieldValueTests: XCTestCase {
    func testAShortValueIsKeptWhole() {
        XCTAssertEqual(ComposedFieldValue.windowed("你说得对"), "你说得对")
    }

    func testEmptyIsNothing() {
        XCTAssertNil(ComposedFieldValue.windowed(nil))
        XCTAssertNil(ComposedFieldValue.windowed(""))
    }

    func testALongValueIsClippedWithAnExplicitMarker() {
        let value = String(repeating: "a", count: ComposedFieldValue.maxChars + 100)
        let windowed = ComposedFieldValue.windowed(value) ?? ""
        XCTAssertTrue(windowed.hasSuffix(ComposedFieldValue.truncationMarker))
        XCTAssertTrue(windowed.contains("…"), "the cut itself is visible too")
    }

    /// A document's first 500 characters say nothing about the sentence being
    /// typed at its end.
    func testTheWindowFollowsTheCaret() {
        let value = String(repeating: "a", count: 2_000) + "NEEDLE" + String(repeating: "b", count: 2_000)
        let windowed = ComposedFieldValue.windowed(value, caret: 2_003) ?? ""
        XCTAssertTrue(windowed.contains("NEEDLE"))
        XCTAssertTrue(windowed.hasPrefix("…"))
        XCTAssertTrue(windowed.hasSuffix(ComposedFieldValue.truncationMarker))
    }

    func testACaretAtTheEndKeepsTheTail() {
        let value = String(repeating: "a", count: 1_000) + "TAIL"
        let windowed = ComposedFieldValue.windowed(value, caret: 1_004) ?? ""
        XCTAssertTrue(windowed.contains("TAIL"))
        XCTAssertFalse(windowed.hasSuffix("…" + ComposedFieldValue.truncationMarker))
    }

    func testTheWindowNeverExceedsTheBudget() {
        let value = String(repeating: "a", count: 5_000)
        let windowed = ComposedFieldValue.windowed(value, caret: 2_500) ?? ""
        let marker = ComposedFieldValue.truncationMarker.count
        XCTAssertLessThanOrEqual(windowed.count, ComposedFieldValue.maxChars + marker + 2)
    }
}

/// §3 attachment tiers, copied from the measurement.
final class TreeAttachmentTests: XCTestCase {
    func testTheEventsThatChangedTheScreenAskForATree() {
        XCTAssertEqual(TreeAttachment.tier(kind: "click"), .always)
        XCTAssertEqual(TreeAttachment.tier(kind: "drag"), .always)
        XCTAssertEqual(TreeAttachment.tier(kind: "window_changed"), .always)
        XCTAssertEqual(TreeAttachment.tier(kind: "command", command: "return"), .always)
        XCTAssertEqual(TreeAttachment.tier(kind: "command", command: "cmd-return"), .always)
    }

    /// A typing burst carries its own content; walking a window to re-read it
    /// would spend the app's main thread for nothing.
    func testTypingAndScrollingNeverWalk() {
        XCTAssertEqual(TreeAttachment.tier(kind: "burst"), .never)
        XCTAssertEqual(TreeAttachment.tier(kind: "scroll"), .never)
        XCTAssertEqual(TreeAttachment.tier(kind: "selection"), .never)
    }

    func testShortcutsAreThrottled() {
        XCTAssertEqual(TreeAttachment.tier(kind: "command", command: "cmd-c"), .throttled)
        XCTAssertEqual(TreeAttachment.tier(kind: "command", command: nil), .throttled)
        let attaching = (0..<60).filter { TreeAttachment.shortcutAttaches(shortcutIndex: $0) }.count
        XCTAssertEqual(attaching, 10, "one in six, the measured ~17%")
    }
}

final class DragGesturePolicyTests: XCTestCase {
    func testAWobbleIsNotADrag() {
        XCTAssertFalse(DragGesturePolicy.isDrag(dx: 3, dy: 4))
        XCTAssertFalse(DragGesturePolicy.isDrag(dx: 0, dy: 0))
    }

    func testAMoveAcrossTheScreenIs() {
        XCTAssertTrue(DragGesturePolicy.isDrag(dx: 400, dy: -120))
        XCTAssertTrue(DragGesturePolicy.isDrag(dx: 0, dy: 12))
    }
}
