/// Which events are worth an AX walk (docs/event-capture-v2-plan.md §3).
package enum TreeAttachmentTier: Equatable, Sendable {
    /// Ask for a walk. The pacing may still refuse it.
    case always
    /// Ask for one occasionally — the event is frequent and mostly repeats
    /// itself.
    case throttled
    /// Never walk. Either the event already carries its content, or the tree it
    /// would produce says nothing the last one did not.
    case never
}

/// The attachment tiers, copied from the measurement rather than reasoned out
/// (docs/event-capture-v2-plan.md §3): submit 31/31, click 149/157,
/// window.changed 130/135 came with a tree; `text_input` 0/195 and selection
/// 0/86 did not; shortcuts about 17%.
///
/// The rule behind the numbers is that a tree is worth walking when the event
/// *changed* what is on screen and the event record cannot say how. A typing
/// burst is the counter-example: its value field already holds the content, so
/// a whole-window walk would spend an app's main thread to re-read what the
/// record contains.
package enum TreeAttachment {
    /// Commands that mean "submit", not "shortcut". The distinction is the
    /// reason `submit` is 31/31: it is the instant a piece of work leaves the
    /// user's hands, and the tree just after it is the result.
    package static let submitCommands: Set<String> = ["return", "cmd-return"]

    /// One in this many shortcuts asks for a walk (~17%, the measured share).
    package static let shortcutEveryNth = 6

    package static func tier(kind: String, command: String? = nil) -> TreeAttachmentTier {
        switch kind {
        case "click", "drag", "window_changed":
            return .always
        case "command":
            guard let command, submitCommands.contains(command) else { return .throttled }
            return .always
        default:
            // Typing bursts, scrolls, and anything a later shim invents.
            return .never
        }
    }

    /// Whether the `shortcutIndex`-th shortcut since the shim started is the one
    /// that asks for a walk. Counting rather than sampling at random keeps the
    /// rate honest over short sessions, where a coin flip would happily produce
    /// six walks in a row.
    package static func shortcutAttaches(shortcutIndex: Int) -> Bool {
        guard shortcutEveryNth > 0 else { return false }
        return shortcutIndex % shortcutEveryNth == 0
    }
}

/// Telling a drag from a click that wobbled (docs/event-capture-v2-plan.md §2).
///
/// A drag is a causal edge between two elements — the same shape as a ⌘C → ⌘V
/// pair — and it is only that if the pointer actually went somewhere. The test
/// runs on the tap thread against two coordinates that are discarded the
/// instant it answers; only the `Bool` travels on.
package enum DragGesturePolicy {
    /// Points the pointer must cover between mouse-down and mouse-up.
    /// Below this the "drag" is a click on a trackpad, and both ends would
    /// resolve to the same element anyway.
    package static let minimumDistancePoints = 12.0

    package static func isDrag(dx: Double, dy: Double) -> Bool {
        dx * dx + dy * dy >= minimumDistancePoints * minimumDistancePoints
    }
}
