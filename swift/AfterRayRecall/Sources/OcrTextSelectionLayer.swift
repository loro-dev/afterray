import AppKit
import SwiftUI

/// Main-thread handshake between the AppKit text layer and the SwiftUI scrub
/// gesture.
///
/// `recallDrag` is attached with `simultaneousGesture`, which by definition
/// still fires when a subview claims the mouse down — without an explicit veto,
/// starting a text selection also flings the timeline. A SwiftUI `@State` flag
/// cannot serve as that veto: the gesture closure would not observe the new
/// value until the next body evaluation, a frame after the drag has begun.
/// Reading a reference type inside the closure is synchronous.
@MainActor
final class OcrTextSelectionCoordinator {
    private(set) var isSelecting = false

    fileprivate weak var view: OcrTextSelectionView?

    /// Called when the frame changes, motion starts, or the layer unmounts.
    func clearSelection() {
        isSelecting = false
        view?.clearSelection()
    }

    fileprivate func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
    }
}

/// Makes the OCR text of the settled frame behave like text: I-beam on hover,
/// drag to select, ⌘C to copy.
struct OcrTextSelectionLayer: NSViewRepresentable {
    /// How long the picture must sit still — no scrub, no scroll, no frame
    /// change — before the layer is mounted at all. Nothing about the layer is
    /// visible, so paying for it during motion buys the user nothing.
    static let quietDuration = Duration.seconds(1)

    let regions: [OcrRegion]
    let pixelSize: CGSize
    let selection: OcrTextSelectionCoordinator

    func makeNSView(context _: Context) -> OcrTextSelectionView {
        let view = OcrTextSelectionView()
        attach(view)
        return view
    }

    func updateNSView(_ nsView: OcrTextSelectionView, context _: Context) {
        attach(nsView)
    }

    static func dismantleNSView(_ nsView: OcrTextSelectionView, coordinator _: ()) {
        nsView.teardown()
    }

    private func attach(_ view: OcrTextSelectionView) {
        view.selection = selection
        selection.view = view
        view.update(regions: regions, pixelSize: pixelSize)
    }
}

/// A transparent layer over the still that owns nothing but the selection.
///
/// It draws no glyphs. Painting transparent text over the picture — the obvious
/// reading of "overlay the text" — puts a compositing layer on top of the very
/// pixels the user is reading and buys nothing: the boxes are enough to hit
/// test, and what ⌘C yields is the recognized string either way.
final class OcrTextSelectionView: NSView {
    /// Slack around a box, so the pointer does not have to be inside the glyph
    /// ink to count as being over text.
    private static let hitPadding: CGFloat = 3
    /// `RecallPalette.ray` at a wash strength that stays legible over both a
    /// bright document and a dark terminal.
    private static let selectionColor = NSColor(srgbRed: 1.0, green: 0.20, blue: 0.14, alpha: 0.34)

    weak var selection: OcrTextSelectionCoordinator?

    private var regions: [OcrRegion] = []
    private var pixelSize: CGSize = .zero
    private var textLayout = OcrTextLayout.empty
    private var caretOffsets: [Int: [CGFloat]] = [:]
    private var laidOutSize: CGSize = .zero
    private var anchor: OcrTextPosition?
    private var range: OcrTextRange?
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    /// True only after this view called `NSCursor.iBeam.set()`. Restoring
    /// blindly would fight the chrome stacked above the still.
    private var showingIBeam = false

    override var isFlipped: Bool { true }

    var hasSelection: Bool {
        guard let range else { return false }
        return !range.isEmpty
    }

    func update(regions: [OcrRegion], pixelSize: CGSize) {
        guard regions != self.regions || pixelSize != self.pixelSize else { return }
        self.regions = regions
        self.pixelSize = pixelSize
        clearSelection()
        rebuild()
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            teardown()
        } else {
            installEventMonitor()
            window?.invalidateCursorRects(for: self)
        }
    }

    func teardown() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        restoreArrowIfNeeded()
        anchor = nil
        range = nil
        selection?.setSelecting(false)
    }

    func clearSelection() {
        guard range != nil || anchor != nil else { return }
        range = nil
        anchor = nil
        needsDisplay = true
    }

    private func rebuild() {
        laidOutSize = bounds.size
        textLayout = OcrTextLayout.build(
            regions: regions,
            contentRect: OcrHighlight.contentRect(pixelSize: pixelSize, viewSize: bounds.size)
        )
        caretOffsets.removeAll()
        if textLayout.isEmpty { clearSelection() }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Pointer

    /// Only the glyph boxes belong to this view. Everywhere else the mouse
    /// falls through to the recall surface, so dragging the picture still
    /// scrubs the timeline.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview?.convert(point, to: self), bounds.contains(local) else {
            return nil
        }
        return textLayout.lineIndex(at: local, padding: Self.hitPadding) != nil ? self : nil
    }

    /// Cursor rects still run where AppKit honours them, but an `NSView`
    /// hosted inside SwiftUI's `NSHostingView` often never gets them applied:
    /// the hosting view owns a full-bounds arrow tracking area and `rebuild`
    /// can run before the layer is in a window, so `invalidateCursorRects`
    /// is a no-op. Tracking + `cursorUpdate` is what actually shows the
    /// I-beam. We only set it when this view owns the hit test — otherwise
    /// the timeline chrome stacked above the still would lose its pointers.
    override func resetCursorRects() {
        super.resetCursorRects()
        for line in textLayout.lines {
            addCursorRect(
                line.rect.insetBy(dx: -Self.hitPadding, dy: -Self.hitPadding),
                cursor: .iBeam
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .cursorUpdate,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        syncCursor(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        syncCursor(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        syncCursor(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        restoreArrowIfNeeded()
    }

    private func syncCursor(with event: NSEvent) {
        let hit = window?.contentView?.hitTest(event.locationInWindow)
        if hit === self {
            NSCursor.iBeam.set()
            showingIBeam = true
        } else {
            restoreArrowIfNeeded()
        }
    }

    private func restoreArrowIfNeeded() {
        guard showingIBeam else { return }
        NSCursor.arrow.set()
        showingIBeam = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let position = position(at: point) else { return }
        // Claimed before SwiftUI's simultaneous drag gesture sees the same
        // press: from here until mouse-up the picture must not scrub.
        selection?.setSelecting(true)
        switch event.clickCount {
        case 2:
            range = textLayout.wordRange(at: position)
            anchor = range?.start
        case 3...:
            range = textLayout.lineRange(at: position)
            anchor = range?.start
        default:
            if event.modifierFlags.contains(.shift), let anchor {
                range = OcrTextRange(anchor: anchor, head: position)
            } else {
                anchor = position
                range = OcrTextRange(anchor: position, head: position)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let head = position(at: point) else { return }
        range = OcrTextRange(anchor: anchor, head: head)
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        selection?.setSelecting(false)
        if range?.isEmpty ?? false {
            range = nil
            anchor = nil
        }
        needsDisplay = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard textLayout.lineIndex(at: point, padding: Self.hitPadding) != nil else { return nil }
        let menu = NSMenu()
        if hasSelection {
            menu.addItem(
                withTitle: "Copy",
                action: #selector(copySelection),
                keyEquivalent: ""
            ).target = self
        }
        menu.addItem(
            withTitle: "Copy All Text",
            action: #selector(copyEverything),
            keyEquivalent: ""
        ).target = self
        return menu
    }

    private func position(at point: CGPoint) -> OcrTextPosition? {
        guard let index = textLayout.nearestLineIndex(at: point) else { return nil }
        return OcrTextPosition(
            line: index,
            character: OcrCaretMetrics.characterIndex(forX: point.x, offsets: offsets(forLine: index))
        )
    }

    /// CoreText metrics are built the first time a line takes part in a
    /// selection. Hovering, hit testing and the I-beam need boxes only, so a
    /// frame the user never selects on never measures a glyph.
    private func offsets(forLine index: Int) -> [CGFloat] {
        if let hit = caretOffsets[index] { return hit }
        guard textLayout.lines.indices.contains(index) else { return [] }
        let built = OcrCaretMetrics.caretOffsets(for: textLayout.lines[index])
        caretOffsets[index] = built
        return built
    }

    private func caretX(_ position: OcrTextPosition) -> CGFloat {
        let offsets = offsets(forLine: position.line)
        guard !offsets.isEmpty else { return 0 }
        guard offsets.indices.contains(position.character) else { return offsets[offsets.count - 1] }
        return offsets[position.character]
    }

    // MARK: - Drawing

    override func draw(_: NSRect) {
        guard let range, !range.isEmpty else { return }
        Self.selectionColor.setFill()
        for rect in textLayout.selectionRects(for: range, caretX: { self.caretX($0) }) {
            NSBezierPath(
                roundedRect: rect.insetBy(dx: 0, dy: -1),
                xRadius: 2.5,
                yRadius: 2.5
            ).fill()
        }
    }

    // MARK: - Keyboard and clipboard

    /// ⌘C, ⌘A and Escape without touching the responder chain.
    ///
    /// The overlay is a borderless panel in an accessory app whose menu has no
    /// Edit item, so a key equivalent has nowhere to be dispatched from; and
    /// making this view first responder would steal the arrow keys and space
    /// that drive the playhead. A local monitor sidesteps both, and only acts
    /// while a selection exists.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else {
            // The user moved to another window; a selection left glowing on a
            // frame behind it would keep claiming ⌘C.
            clearSelection()
            return event
        }
        // Never swallow a shortcut aimed at a field the user is typing in.
        if window.firstResponder is NSText { return event }

        switch event.type {
        case .leftMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            if textLayout.lineIndex(at: point, padding: Self.hitPadding) == nil { clearSelection() }
            return event
        case .keyDown:
            guard hasSelection || event.modifierFlags.contains(.command) else { return event }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c" where hasSelection:
                    copySelectedText()
                    return nil
                case "a" where !textLayout.isEmpty:
                    range = textLayout.fullRange
                    anchor = range?.start
                    needsDisplay = true
                    return nil
                default:
                    return event
                }
            }
            // Escape clears the selection before anything else can read it as
            // "dismiss the overlay".
            if event.keyCode == 53 {
                clearSelection()
                return nil
            }
            return event
        default:
            return event
        }
    }

    @objc private func copySelection() {
        copySelectedText()
    }

    @objc private func copyEverything() {
        guard let all = textLayout.fullRange else { return }
        write(textLayout.string(for: all))
    }

    private func copySelectedText() {
        guard let range, !range.isEmpty else { return }
        write(textLayout.string(for: range))
    }

    private func write(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
