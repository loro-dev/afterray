# Selectable text on a recalled frame

Verified against code 2026-08-18.

The frame under the playhead behaves like text: I-beam on hover, drag to select,
⌘C to copy. No wire change — it is built entirely from the OCR boxes the vault
already holds, so `PROTOCOL_VERSION` is untouched.

## Where the pieces live

| Piece | File |
|---|---|
| Vision OCR, line-level boxes | `apps/AfterRayNativeModelWorker/Sources/main.swift:70` |
| Persisted as `text_evidence.layout_json` | `crates/afterray-store/src/lib.rs:3001` |
| `evidence_ocr` → `OcrEvidence.regions` | `crates/afterray-protocol/src/lib.rs:754` |
| Unit-square → view points (letterbox + Y flip) | `swift/AfterRayRecall/Sources/OcrHighlight.swift` |
| Selection model (pure, tested) | `swift/AfterRayRecall/Sources/OcrTextLayout.swift` |
| AppKit layer, pointer, clipboard | `swift/AfterRayRecall/Sources/OcrTextSelectionLayer.swift` |
| Bounded region cache | `swift/AfterRayRecall/Sources/OcrRegionCache.swift` |
| Mount gate + gesture veto | `swift/AfterRayRecall/Sources/RecallView.swift` (`textLayerKey`, `prepareTextLayer`) |

## Decisions that are not obvious from the code

- **Nothing is drawn but the selection.** Painting transparent glyphs over the
  still — the intuitive reading of "overlay the text" — adds a compositing layer
  on top of the pixels the user is reading and buys nothing: boxes are enough to
  hit-test, and ⌘C yields the recognized string either way.
- **The mount gate is a `.task(id:)` key**, not a timer. `textLayerKey` folds in
  moment id, settled still id, `isScrubbing`, zoom and live state; any change
  cancels the task, so the one-second quiet period restarts on every scrub,
  scroll or frame change. `isScrubbing` only clears after the scroll inertia
  runs out, so the glide is already inside it. The layer is invisible until a
  selection exists, so mounting late costs the user nothing.
- **`OcrTextSelectionCoordinator` is a reference type on purpose.** `recallDrag`
  is a `simultaneousGesture`: it fires even when a subview claims the mouse
  down, so starting a selection would otherwise also fling the timeline. A
  SwiftUI `@State` flag cannot veto it — the gesture closure would not see the
  new value until the next body evaluation, one frame too late.
- **`hitTest` returns the view only over glyph boxes** (+3pt slack). Everywhere
  else the mouse falls through, so dragging the picture still scrubs. This is
  the whole activation model — there is no mode and no toggle.
- **Keyboard goes through a local `NSEvent` monitor**, not the responder chain.
  The overlay is a borderless panel in an accessory app whose menu has no Edit
  item, so ⌘C has nowhere to dispatch from; and making the layer first responder
  would steal the arrow keys and space that drive the playhead. The monitor
  passes events through untouched when the first responder is an `NSText`.
- **Cursor rects, not a tracking area.** AppKit unions them per view and
  restores the previous cursor on exit, which is what keeps the I-beam from
  fighting the chrome drawn above the layer.
- **CoreText metrics are lazy.** Hover, hit test and I-beam need boxes only;
  `OcrCaretMetrics` runs the first time a line takes part in a selection, so a
  frame nobody selects on never measures a glyph.
- **Font size cancels out.** A line is typeset once and scaled horizontally onto
  its box; advances scale linearly with point size, so the size chosen is
  irrelevant. The approximation that remains is the *font*, and it moves only
  the highlight — the copied text is the recognized string.

## Limits, by design

- Intra-line caret positions are estimated, so the wash can sit a few points off
  the glyphs. What lands on the pasteboard is always exact OCR text.
- Vision runs with `usesLanguageCorrection`, so OCR text ≠ screen text. Pre-existing.
- Side-by-side columns collapse into shared rows (`OcrTextLayout.readingOrder`).
  macOS Live Text has the same limitation; a column detector fails in less
  predictable ways.
- Horizontal LTR only. No vertical or RTL text.
- The layer is bound to the moment's `displayCacheKey` frame — the same one OCR
  ran on, and the same assumption the search-highlight overlay already makes.

## Security

OCR text is decrypted screen content. `OcrRegionCache` is bounded (32 frames),
insertion-ordered rather than an `NSCache` so eviction is predictable, and
cleared from `AfterRayApp`'s lock/sleep teardown beside the image caches
(`apps/AfterRay/Sources/AfterRayApp.swift`, `.afterRaySystemSessionWillSuspend`).
Any new cache of decrypted content must join that list.

## Testing

`swift test --filter OcrTextSelectionTests` covers reading order, hit testing,
range assembly, word/line selection and caret metrics — everything except the
mouse plumbing. `make visual-lab` draws real strings on the mock frame
(`MockScreenText`, `swift/AfterRayMockData/Sources/RecallScenarios.swift`) whose
boxes are measured from the same table, which is the only way the layer can be
judged against glyphs it is actually drawn over.
