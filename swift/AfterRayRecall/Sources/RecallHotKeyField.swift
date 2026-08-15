import AppKit
import SwiftUI

/// A single physical-looking key. Modifier glyphs and word keys share one
/// shape so a shortcut reads as one object rather than a row of chips.
public struct RecallKeycap: View {
    public enum Size {
        case hero
        case compact

        var height: CGFloat { self == .hero ? 52 : 26 }
        var minWidth: CGFloat { self == .hero ? 52 : 30 }
        var radius: CGFloat { self == .hero ? 13 : 7 }
        var font: Font {
            .system(size: self == .hero ? 19 : 11.5, weight: .medium, design: .rounded)
        }

        var horizontalPadding: CGFloat { self == .hero ? 18 : 8 }
        var gap: CGFloat { self == .hero ? 10 : 5 }
    }

    public enum Tone: Equatable {
        case idle
        case live
        case pressed
        case waiting
    }

    let label: String
    var size: Size = .hero
    var tone: Tone = .idle

    public init(label: String, size: Size = .hero, tone: Tone = .idle) {
        self.label = label
        self.size = size
        self.tone = tone
    }

    public var body: some View {
        Text(label)
            .font(size.font)
            .foregroundStyle(tone == .live || tone == .pressed ? Color.white : RecallPalette.textSecondary)
            .monospacedDigit()
            .padding(.horizontal, label.count > 1 ? size.horizontalPadding : 4)
            .frame(minWidth: size.minWidth, minHeight: size.height)
            .frame(height: size.height)
            .background(shape.fill(fill))
            .overlay {
                // Keys catch light along their top edge; a single hairline is
                // enough to read as a bevel without a fake 3D stack.
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.26), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(
                color: .black.opacity(0.42),
                radius: tone == .pressed ? 2 : size == .hero ? 8 : 3,
                y: tone == .pressed ? 1 : size == .hero ? 3 : 1
            )
            .shadow(color: glow, radius: 14)
            .scaleEffect(tone == .pressed ? 0.96 : 1)
            .offset(y: tone == .pressed ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: tone)
            .fixedSize()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size.radius, style: .continuous)
    }

    private var fill: LinearGradient {
        switch tone {
        case .idle:
            LinearGradient(
                colors: [.white.opacity(0.135), .white.opacity(0.065)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .live:
            LinearGradient(
                colors: [RecallPalette.ray.opacity(0.92), RecallPalette.ray.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .pressed:
            LinearGradient(
                colors: [RecallPalette.ray.opacity(0.66), RecallPalette.ray.opacity(0.84)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .waiting:
            LinearGradient(
                colors: [.white.opacity(0.07), .white.opacity(0.03)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var glow: Color {
        switch tone {
        case .live: RecallPalette.ray.opacity(0.42)
        case .pressed: RecallPalette.ray.opacity(0.20)
        case .idle, .waiting: .clear
        }
    }
}

/// Shows the current shortcut, and records a new one in place.
public struct RecallHotKeyField: View {
    @ObservedObject private var store: RecallHotKeyStore
    private let size: RecallKeycap.Size
    private let isHighlighted: Bool
    private let pressedSegments: Set<String>
    private let highlightedSegments: Set<String>
    private let onBeginRecording: (() -> Void)?

    @State private var liveModifiers: RecallHotKey.Modifiers = []
    @State private var breathe = false

    public init(
        store: RecallHotKeyStore,
        size: RecallKeycap.Size = .compact,
        isHighlighted: Bool = false,
        pressedSegments: Set<String> = [],
        highlightedSegments: Set<String> = [],
        onBeginRecording: (() -> Void)? = nil
    ) {
        self.store = store
        self.size = size
        self.isHighlighted = isHighlighted
        self.pressedSegments = pressedSegments
        self.highlightedSegments = highlightedSegments
        self.onBeginRecording = onBeginRecording
    }

    public var body: some View {
        Group {
            if store.isRecording {
                recorder
            } else {
                display
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: store.isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHighlighted)
        .animation(.easeOut(duration: 0.12), value: pressedSegments)
        .animation(.easeOut(duration: 0.18), value: highlightedSegments)
        .onChange(of: store.isRecording) { _, recording in
            if recording { liveModifiers = [] }
        }
    }

    private var display: some View {
        Button {
            if let onBeginRecording {
                onBeginRecording()
            } else {
                store.beginRecording()
            }
        } label: {
            HStack(spacing: size.gap) {
                ForEach(Array(store.hotKey.segments.enumerated()), id: \.offset) { _, segment in
                    RecallKeycap(label: segment, size: size, tone: tone(for: segment))
                }
            }
            .scaleEffect(isHighlighted ? 1.06 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Record a new shortcut")
        .accessibilityLabel("Shortcut \(store.hotKey.displayString). Activate to record a new one.")
    }

    private func tone(for segment: String) -> RecallKeycap.Tone {
        if pressedSegments.contains(segment) { return .pressed }
        if isHighlighted || highlightedSegments.contains(segment) { return .live }
        return .idle
    }

    private var recorder: some View {
        HStack(spacing: size.gap) {
            if liveModifiers.isEmpty {
                Text("Press the keys you want")
                    .font(.system(size: size == .hero ? 14 : 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(RecallPalette.textTertiary)
            } else {
                ForEach(liveModifiers.glyphs, id: \.self) { glyph in
                    RecallKeycap(label: glyph, size: size, tone: .live)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
                RecallKeycap(label: "…", size: size, tone: .waiting)
            }
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: liveModifiers)
        .padding(.horizontal, size == .hero ? 22 : 10)
        .frame(minHeight: size.height + (size == .hero ? 14 : 6))
        .background {
            RoundedRectangle(cornerRadius: size == .hero ? 16 : 8, style: .continuous)
                .fill(RecallPalette.ray.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: size == .hero ? 16 : 8, style: .continuous)
                        .strokeBorder(
                            RecallPalette.ray.opacity(breathe ? 0.85 : 0.35),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                }
        }
        .overlay {
            HotKeyCatcher(
                onFlags: { liveModifiers = RecallHotKey.Modifiers($0) },
                onKey: capture,
                onCancel: store.cancelRecording
            )
            .allowsHitTesting(false)
        }
        .onAppear {
            breathe = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        // Closing the window mid-recording must not leave the shortcut
        // released — that would make AfterRay unreachable by keyboard.
        .onDisappear { store.cancelRecording() }
    }

    private func capture(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) {
        switch RecallHotKey.capture(keyCode: keyCode, characters: characters, flags: flags) {
        case .success(let candidate):
            store.commit(candidate)
        case .failure(let issue):
            store.reject(issue)
        }
    }
}

/// AppKit owns the keyboard here: `performKeyEquivalent` is the only hook that
/// sees ⌘-combinations before the menu bar swallows them.
private struct HotKeyCatcher: NSViewRepresentable {
    let onFlags: (NSEvent.ModifierFlags) -> Void
    let onKey: (UInt16, String?, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotKeyCatcherView {
        let view = HotKeyCatcherView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: HotKeyCatcherView, context: Context) {
        apply(to: view)
        view.claimKeyboard()
    }

    static func dismantleNSView(_ view: HotKeyCatcherView, coordinator: ()) {
        view.releaseKeyboard()
    }

    private func apply(to view: HotKeyCatcherView) {
        view.onFlags = onFlags
        view.onKey = onKey
        view.onCancel = onCancel
    }
}

private final class HotKeyCatcherView: NSView {
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?
    var onKey: ((UInt16, String?, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimKeyboard()
    }

    func claimKeyboard() {
        guard let window, window.firstResponder !== self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    func releaseKeyboard() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(nil)
    }

    override func flagsChanged(with event: NSEvent) {
        onFlags?(event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53, RecallHotKey.Modifiers(event.modifierFlags).isEmpty {
            onCancel?()
            return
        }
        onKey?(event.keyCode, event.charactersIgnoringModifiers, event.modifierFlags)
    }
}
