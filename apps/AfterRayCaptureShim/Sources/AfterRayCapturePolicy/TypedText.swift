/// The characters of one typing run, assembled as they arrive
/// (docs/event-capture-v2-plan.md §2).
///
/// The keystream is the *secondary* content channel and the measurement says
/// why: 1,796 `text_input` events in the reference corpus contained no Chinese
/// at all, because a CJK user's keystrokes are pinyin fragments — `wsm
/// tongyini` — and the sentence only exists in the field's value. What the run
/// is good for is the Latin case, the shape of an edit, and the timing.
///
/// Runs are cut by pause, not by field: `InputEventMonitor` closes a burst
/// after `pauseMs` of silence (measured median gap 3.0s, median chunk 5
/// characters), and one closed burst is one run.
package struct TypedTextRun: Equatable, Sendable {
    /// Silence that ends a run. The shim's existing burst gap, named here so
    /// the chunking rule reads in one place.
    package static let pauseMs: Int64 = 2_000
    /// Longest run kept. Runs are seconds long, so this is a guard against a
    /// paste-shaped keystream, not a normal path.
    package static let maxChars = 500
    package static let truncationMarker = " [truncated]"

    private var characters: [Character] = []
    private var overflowed = false

    package init() {}

    /// Applies one keystroke's characters.
    ///
    /// Backspace and forward delete edit the run rather than appending, so what
    /// is stored is what the user left standing, not every key they regretted.
    /// Control characters and the private-use scalars macOS uses for arrows and
    /// function keys are dropped: they carry no content, and a raw `\u{1}` in a
    /// record is only ever noise.
    package mutating func append(_ input: String) {
        for scalar in input.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x7F:
                if !characters.isEmpty { characters.removeLast() }
            case 0x00...0x1F:
                continue
            case 0xF700...0xF8FF:
                continue
            default:
                guard characters.count < Self.maxChars else {
                    overflowed = true
                    continue
                }
                characters.append(Character(scalar))
            }
        }
    }

    package var isEmpty: Bool { characters.isEmpty }

    /// The run as recorded, or `nil` when nothing printable survived — a run of
    /// arrow keys is not text and should not be stored as empty text.
    package var recorded: String? {
        guard !characters.isEmpty else { return nil }
        let text = String(characters)
        return overflowed ? text + Self.truncationMarker : text
    }
}

/// The value of the field an event landed in, clipped for storage
/// (docs/event-capture-v2-plan.md §2).
///
/// This is the **primary** content channel: measured, 451 target values carried
/// Chinese against zero in the keystream. A composed message, a search query
/// completed by the IME, dictated text and an AI completion all show up here and
/// nowhere else.
package enum ComposedFieldValue {
    /// Characters kept. A text area can hold a whole document; past this a
    /// single event has stopped being context.
    package static let maxChars = 500
    /// Announced, never silent — a reader must not take a clipped value for the
    /// whole field.
    package static let truncationMarker = " [truncated to visible range]"

    /// The stored form of a field's value: the whole thing when it fits, else a
    /// `maxChars` window around the caret.
    ///
    /// The window follows the caret because that is where the user is working;
    /// the first 500 characters of a long document say nothing about the
    /// sentence just typed at the end of it. With no caret to go on the window
    /// starts at the beginning, which is right for the short fields — search
    /// boxes, message composers — that have no caret information worth reading.
    package static func windowed(_ value: String?, caret: Int? = nil) -> String? {
        guard let value else { return nil }
        let characters = Array(value)
        guard !characters.isEmpty else { return nil }
        guard characters.count > maxChars else { return value }

        let start: Int
        if let caret {
            let centred = caret - maxChars / 2
            start = max(0, min(centred, characters.count - maxChars))
        } else {
            start = 0
        }
        let end = min(characters.count, start + maxChars)
        var text = String(characters[start..<end])
        if start > 0 { text = "…" + text }
        if end < characters.count { text += "…" }
        return text + truncationMarker
    }
}
