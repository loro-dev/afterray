# AGENTS.md — apps/AfterRayCaptureShim

The ScreenCaptureKit boundary for the Rust daemon. It exists because the Rust workspace denies `unsafe_code` and ScreenCaptureKit delegates need unsafe FFI (see `README.md` here). A **standalone SwiftPM package** — its own `Package.swift` and `.build/`, deliberately not a target of the root package. The executable is one file, `Sources/AfterRayCaptureShim/main.swift` (~2580 lines); everything pure and testable lives beside it in `Sources/AfterRayCapturePolicy`.

Deep dives: [event-capture-v2](../../context/event-capture-v2.md) (tree text, diff chains, input vocabulary, secure guard), [capture-pipeline](../../context/capture-pipeline.md), [acts-join](../../context/acts-join.md).

## Key anchors

- `main.swift:26` `Options` (`parse` at :32) — CLI flags (`--output-dir`, `--jpeg-quality`, audio, …)
- `main.swift:104` `Event` — JSON-line events on stdout (`ready`, `artifact`, `warning`, `failed`, `input_events`, `stopped`)
- `main.swift:359` `captureTreeChains` — process-wide `tree_text` chains; `captureAccessibilityTree` :801
- `main.swift:1608` `InputEventMonitor` — listen-only tap + coalescing worker; `requestTreeWalk` :2091, `captureEdgeSnapshot` :2127, `resolveTarget` :2269
- `main.swift:2394` `InputCommand` — stdin commands; the main loop handles `capture_screen` (requires `request_id`, :2492), `set_excluded_bundles`, `stop`
- `main.swift:1076` `ExcludedAudioGate`; `main.swift:2534` `log()` — logging goes to **stderr only**

## Invariants

- stdout is reserved for JSON-line events — never print anything else there; the daemon parses it.
- Screenshots are pull-based: Rust decides timing (`capture_screen`), the shim adds no hidden frame scheduler.
- Output dir is hardened to `0700`, artifact files to `0600`. The shim excludes AfterRay's own windows from capture.
- Each screenshot uses the display with the largest intersection with the AX focused window (`main window` is the AX fallback; no usable frame falls back to `CGMainDisplayID`). PID, window id, and frame are rechecked around it, and a changed context drops the tick. Keep the continuous audio stream separate from this per-tick display filter.
- **A screen artifact is never emitted without its accessibility artifact.** The daemon's only exclusion check lives in the accessibility branch, so an unpaired screenshot can never be evaluated and would be kept whatever the user excluded. Every path that cannot produce a snapshot returns before the screenshot — keep it that way.
- **Audio exclusions are enforced here, screen exclusions in the daemon**: a moment can be deleted once the snapshot names the app, a finished five-minute `m4a` cannot be sliced. `ExcludedAudioGate` therefore answers "which stretch of the recent past had no excluded app in front" — samples are **held** until a check vouches for the moment they arrived, and all audio is held until the daemon's list arrives. The frontmost app is polled (100 ms) because the main thread blocks in `readLine` and never services a run loop.
- **Every AX snapshot carries `tree_text`** beside `root` and `digest`, which stay byte-identical — existing consumers parse those. Chains are per (pid, window title, walk root); a diff decodes against its own chain's previous emission, named by `chain`+`seq`. Stage before writing, `commit` only after the artifact is sent.
- **Typed content may be captured; the secure guard is absolute** (CAP-005 retired). `SecureInputGuard` reads the subrole, the ancestors' subroles, and a secret-looking label; when it says yes, neither keystream nor value is read and the burst keeps its count alone. An unresolvable focus counts as secure — fail closed.
- Input events: a listen-only `CGEventTap` on its own thread emits coalesced `input_events`. Kinds `burst`, `command`, `click`, `scroll`, `drag`, `window_changed` — **additive, never renamed**, the store's act join matches these strings. Excluded apps and AfterRay itself are never recorded; fails closed before the daemon's list arrives, fails open (warning) when the tap cannot be created. Pointer coordinates never outlive the tap callback or the element resolution they feed.
- Attached tree walks (`requestTreeWalk` → `EdgeSnapshotPacing` → `captureEdgeSnapshot`) only *ask*; pacing decides (settle 500ms re-armed by any input, ≥5s apart, ≤6/min; a refused candidate is dropped, not queued) and spend goes through `fire(nowMs:walk:)` only, so a declined walk cannot burn the allowance. One window, `accessibility_edge`, and **never a screenshot** — an event-driven frame would outlive the 48h events behind it. Browsers are skipped: the private-browsing gate needs an async probe a 1s tick cannot afford.
- AX walk costs are bounded: the `AXMenuBar` subtree is stubbed (80–90% of walked nodes in native apps; deliberately not `truncated`), and the walk is time-boxed — 100ms per AX call process-wide + a 500ms whole-walk deadline → `truncated`, same as the 20k node cap. A fresh Electron app's first snapshot may time out once; the next heartbeat recovers.
- Requires **macOS 15** (`Package.swift:6`) while the rest of the app targets macOS 14 — intentional, not a bug.

## Build / test

- `make capture-shim` → `swift build --package-path apps/AfterRayCaptureShim --product AfterRayCaptureShim`; binary at `.build/release/AfterRayCaptureShim` here.
- `swift test --package-path apps/AfterRayCaptureShim` — XCTest over the pure `AfterRayCapturePolicy` target: browser privacy, display selection, pacing, `CaptureTree`→`TreeText`→`TreeDiff`→`KeyframePolicy`→`CaptureTreeChains`, and the v2 input policies (`SecureInputGuard`, `TypedTextRun`, `ComposedFieldValue`, `TreeAttachment`, `DragGesturePolicy`). `make test` runs it; plain `swift test` at the root does not. **Logic that must be tested belongs in that target** — the executable needs live TCC, so `main.swift` wiring is only ever verified by a signed dev run.
- Smoke test: run the binary with `--output-dir /tmp/…`, then send `{"command":"capture_screen","request_id":"smoke-1"}` on stdin (see `README.md` here).

## Watch out

- Building the root Swift package does not build this shim; `make build` includes it, plain `swift build` does not.
- Needs Screen Recording permission to produce frames — run via the signed dev app (`make v0`) for a stable TCC identity.
