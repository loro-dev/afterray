import AppKit
import Foundation

/// The one global shortcut that brings AfterRay back.
///
/// `keyLabel` is captured at record time instead of translated at draw time:
/// a Dvorak or AZERTY user sees the key they actually pressed, on every
/// launch, without AfterRay carrying a keyboard-layout table around.
public struct RecallHotKey: Equatable, Sendable, Codable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)

        /// Modifiers that keep a shortcut clear of ordinary typing.
        static let guarding: Modifiers = [.command, .option, .control]

        public init(_ flags: NSEvent.ModifierFlags) {
            var modifiers: Modifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            self = modifiers
        }

        /// Apple prints modifiers as ⌃ ⌥ ⇧ ⌘, never in the order they are held.
        public var glyphs: [String] {
            var glyphs: [String] = []
            if contains(.control) { glyphs.append("⌃") }
            if contains(.option) { glyphs.append("⌥") }
            if contains(.shift) { glyphs.append("⇧") }
            if contains(.command) { glyphs.append("⌘") }
            return glyphs
        }

        public var eventFlags: NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            if contains(.command) { flags.insert(.command) }
            if contains(.shift) { flags.insert(.shift) }
            if contains(.option) { flags.insert(.option) }
            if contains(.control) { flags.insert(.control) }
            return flags
        }
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var keyLabel: String

    public init(keyCode: UInt16, modifiers: Modifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// ANSI key codes for the stock screenshot numbers: 3, 4, 5, 6.
    public static let systemScreenshotNumberKeyCodes: Set<UInt16> = [20, 21, 23, 22]

    /// ⇧⌘Space: reachable with one hand. It is not a stock macOS shortcut
    /// on its own, but Carbon would steal the Space from the stock window-
    /// screenshot sequence (⇧⌘4, then Space) unless the app yields first.
    public static let `default` = RecallHotKey(
        keyCode: 49,
        modifiers: [.shift, .command],
        keyLabel: "Space"
    )

    /// One element per keycap, in reading order.
    public var segments: [String] { modifiers.glyphs + [keyLabel] }

    public var displayString: String { segments.joined() }

    /// macOS keeps a few combinations for itself. Registering them still
    /// succeeds, so warn rather than refuse — the user may have already
    /// turned the system shortcut off.
    public var systemConflictNote: String? {
        systemConflictNote(.english)
    }

    public func systemConflictNote(_ copy: AfterRayCopy) -> String? {
        if isSystemScreenshotShortcut { return copy.hotKey.screenshotConflict }
        guard keyCode == 49 else { return nil }
        if modifiers == [.command] { return copy.hotKey.spotlightConflict }
        if modifiers == [.control] { return copy.hotKey.inputSourceConflict }
        return nil
    }

    public var isSystemScreenshotShortcut: Bool {
        modifiers == [.shift, .command]
            && Self.systemScreenshotNumberKeyCodes.contains(keyCode)
    }

    // @dec:screenshot-hotkey-yield — docs/decisions/active/product/2026-08-21-screenshot-hotkey-yield.md
    /// `RegisterEventHotKey` consumes the chord before Screenshot sees it.
    /// ⇧⌘Space is AfterRay's default, and also the second press of ⇧⌘4 then
    /// Space. Seeing a screenshot number must drop the Carbon registration
    /// before that Space arrives — unless AfterRay itself is bound to the
    /// number, in which case Carbon already owns it.
    public func shouldYieldToSystemScreenshot(
        keyCode: UInt16,
        modifiers: Modifiers
    ) -> Bool {
        guard modifiers == [.shift, .command],
              Self.systemScreenshotNumberKeyCodes.contains(keyCode)
        else { return false }
        return keyCode != self.keyCode || self.modifiers != modifiers
    }

    /// Empty when the key has no menu representation, which keeps AppKit from
    /// drawing a half-finished shortcut next to a menu item.
    public var menuKeyEquivalent: String {
        if keyCode == 49 { return " " }
        guard keyLabel.count == 1, keyLabel.rangeOfCharacter(from: .alphanumerics) != nil else {
            return ""
        }
        return keyLabel.lowercased()
    }

    // MARK: Capture

    public static func capture(
        keyCode: UInt16,
        characters: String?,
        flags: NSEvent.ModifierFlags
    ) -> Result<RecallHotKey, RecallHotKeyIssue> {
        let modifiers = Modifiers(flags)
        guard let label = keyLabel(keyCode: keyCode, characters: characters) else {
            return .failure(.unsupportedKey)
        }
        guard !modifiers.isDisjoint(with: Modifiers.guarding) else {
            return .failure(.needsModifier)
        }
        if modifiers == [.command], isTypingKey(label) {
            return .failure(.commandAlone("⌘" + label))
        }
        return .success(RecallHotKey(keyCode: keyCode, modifiers: modifiers, keyLabel: label))
    }

    static func keyLabel(keyCode: UInt16, characters: String?) -> String? {
        if let named = namedKeys[keyCode] { return named }
        guard let scalar = characters?.unicodeScalars.first else { return nil }
        guard !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar),
              !CharacterSet.illegalCharacters.contains(scalar)
        else { return nil }
        return String(scalar).uppercased()
    }

    private static func isTypingKey(_ label: String) -> Bool {
        guard label.count == 1, let character = label.first else { return false }
        return character.isLetter || character.isNumber
    }

    private static let namedKeys: [UInt16: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Esc",
        76: "Enter",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        109: "F10",
        111: "F12",
        115: "Home",
        116: "Page Up",
        117: "⌦",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "←",
        124: "→",
        125: "↓",
        126: "↑",
    ]

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case keyLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = Modifiers(rawValue: try container.decode(Int.self, forKey: .modifiers))
        keyLabel = try container.decode(String.self, forKey: .keyLabel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers.rawValue, forKey: .modifiers)
        try container.encode(keyLabel, forKey: .keyLabel)
    }
}

/// Why the recorder turned a key press down, phrased for the person holding
/// the keyboard rather than for a log file.
public enum RecallHotKeyIssue: Error, Equatable, Sendable {
    case needsModifier
    case commandAlone(String)
    case unsupportedKey

    public var message: String { message(.english) }

    public func message(_ copy: AfterRayCopy) -> String {
        switch self {
        case .needsModifier:
            copy.hotKey.needsModifier
        case .commandAlone(let shortcut):
            copy.hotKey.commandAlone(shortcut)
        case .unsupportedKey:
            copy.hotKey.unsupportedKey
        }
    }
}

/// Implemented by whoever owns the live Carbon registration, so the store can
/// stay the single source of truth without importing Carbon itself.
@MainActor
public protocol RecallHotKeyBinding: AnyObject {
    /// Releases the shortcut so the recorder can capture it like any other key.
    func hotKeyBindingSuspend()
    /// Re-arms the shortcut the store already holds.
    func hotKeyBindingResume()
    /// Arms `hotKey`, returning `false` when macOS refuses the combination.
    func hotKeyBindingApply(_ hotKey: RecallHotKey) -> Bool
}

@MainActor
public final class RecallHotKeyStore: ObservableObject {
    public static let shared = RecallHotKeyStore()

    @Published public private(set) var hotKey: RecallHotKey
    @Published public private(set) var isRecording = false
    @Published public private(set) var failure: String?

    public weak var binding: RecallHotKeyBinding?

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "dev.afterray.hotkey.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        hotKey = Self.stored(in: defaults, key: storageKey) ?? .default
    }

    public var isDefault: Bool { hotKey == .default }

    public func beginRecording() {
        guard !isRecording else { return }
        failure = nil
        isRecording = true
        binding?.hotKeyBindingSuspend()
    }

    public func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        failure = nil
        binding?.hotKeyBindingResume()
    }

    /// Arms the candidate before persisting it, so a refused combination never
    /// leaves the user with a shortcut that silently does nothing.
    @discardableResult
    public func commit(_ candidate: RecallHotKey) -> Bool {
        guard candidate != hotKey else {
            cancelRecording()
            return true
        }
        if let binding, !binding.hotKeyBindingApply(candidate) {
            failure = "macOS wouldn't hand over \(candidate.displayString). Try another combination."
            return false
        }
        hotKey = candidate
        persist()
        isRecording = false
        failure = nil
        return true
    }

    public func reject(_ issue: RecallHotKeyIssue) {
        failure = issue.message
    }

    public func restoreDefault() {
        commit(.default)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hotKey) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func stored(in defaults: UserDefaults, key: String) -> RecallHotKey? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecallHotKey.self, from: data)
    }
}
