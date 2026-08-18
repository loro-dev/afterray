# AGENTS.md — apps/AfterRayCaptureShim

The ScreenCaptureKit boundary for the Rust daemon. It exists because the Rust workspace denies `unsafe_code` and ScreenCaptureKit delegates need unsafe FFI (see `README.md` here). A **standalone SwiftPM package** — its own `Package.swift` and `.build/`, deliberately not a target of the root package. The whole shim is one file: `Sources/AfterRayCaptureShim/main.swift` (~2160 lines).

## Key anchors

- `main.swift:26` `Options` (`parse` at :32) — CLI flags (`--output-dir`, `--jpeg-quality`, audio, …)
- `main.swift:104` `Event` — JSON-line event protocol emitted on stdout (`ready`, `artifact`, `warning`, `failed`, `input_events`, `stopped`)
- `main.swift:1461` `InputEventMonitor` — listen-only tap + coalescing worker (see Invariants)
- `main.swift:1978` `InputCommand` — stdin commands; main loop at :2071-2098 handles `capture_screen` (requires `request_id`), `set_excluded_bundles` (carries `bundle_ids`), and `stop`
- `main.swift:971` `ExcludedAudioGate` — drops audio while an excluded app is frontmost (see Invariants)
- `main.swift:2112` `log()` — logging goes to **stderr only**

## Invariants

- stdout is reserved for JSON-line events — never print anything else there; the daemon parses it.
- Screenshots are pull-based: Rust decides timing (`capture_screen`), the shim adds no hidden frame scheduler.
- Output dir is hardened to `0700`, artifact files to `0600` (`main.swift:12,19`).
- The shim excludes AfterRay's own windows from capture (`main.swift:2034-2036`).
- Each screenshot uses the display with the largest intersection with the AX focused window (`main window` is the AX fallback); no usable window frame falls back to `CGMainDisplayID`. The foreground PID, window id, and frame are rechecked around the screenshot. Keep the continuous audio stream separate from this per-tick display filter.
- **A screen artifact is never emitted without its accessibility artifact** (`main.swift:1323`). The daemon's only exclusion check lives in the accessibility branch, so an unpaired screenshot can never be evaluated and would be kept whatever the user excluded. Every path that cannot produce a snapshot returns before the screenshot — keep it that way.
- **Audio exclusions are enforced here, screen exclusions in the daemon.** A moment can be deleted once the snapshot names the app; a finished five-minute `m4a` cannot be sliced. `ExcludedAudioGate` (`main.swift:971`) therefore answers "which stretch of the recent past had no excluded app in front", not "is one in front now": samples are **held** (`AudioSegmentWriter.hold`) until a check vouches for the moment they arrived, and dropped otherwise. Writing first and cutting on the next check would leave every sample since the previous check inside a file the daemon imports and transcribes. The frontmost app is polled (100 ms — latency, not exposure) because the main thread blocks in `readLine` and never services a run loop, so `NSWorkspace` notifications would not arrive; the helper also holds all audio until the daemon's list arrives, since an app in front before that cannot be judged.
- Input events: a listen-only `CGEventTap` on its own thread emits coalesced `input_events` batches — typing-burst counts (key codes classify command keys and never leave the callback), command keys (⌘-combos, Return/Tab/Esc), click/scroll targets resolved to element identity (coordinates dropped after resolution); a typing burst whose focus is not a text-entry role is attributed to the last click instead (`TypingTarget` — Electron and Zed report `AXWebArea`/`AXWindow`, and a landing point that coarse drags the run's scope to the whole window). Excluded apps and AfterRay itself are never recorded; fails closed before the daemon's list arrives, fails open (warning) when the tap cannot be created. See docs/input-events-and-t1-acts-plan.md.
- R3 edge snapshots (`captureEdgeSnapshot`, :1801): a frontmost-bundle change or a click arms a candidate, paced by the pure `EdgeSnapshotPacing` (settle 500ms re-armed by any input, ≥5s apart, ≤6/min; a refused candidate is dropped, not queued). Spend goes through `fire(nowMs:walk:)` only, so a walk the guards decline cannot burn the minute's allowance. Walks the trigger's AXWindow with the same bounded encoder, emits `accessibility_edge`, and **never a screenshot** — an event-driven frame would outlive the 48h events behind it. Excluded apps, AfterRay, and all known browsers are skipped (the private-browsing gate needs an async probe a 1s tick cannot afford). Why: [acts-join](../../context/acts-join.md).
- AX walk costs are bounded: the `AXMenuBar` subtree is stubbed (menus were 80–90% of walked nodes in native apps; every consumer treats them as chrome; deliberately not `truncated`), and the walk is time-boxed — process-global 100ms `AXUIElementSetMessagingTimeout` at startup + 500ms whole-walk deadline → `truncated`, same as the 20k node cap. A fresh Electron app's first snapshot may time out once while it builds its AX tree; the next heartbeat recovers.
- Missing microphone input must never disable system-audio capture: gate `captureMicrophone`, its writer, and its stream output with `AudioCapturePlan`, while leaving `capturesAudio` enabled.
- Requires **macOS 15** (`Package.swift:6`) while the rest of the app targets macOS 14 — intentional, not a bug.

## Build / test

- `make capture-shim` → `swift build --package-path apps/AfterRayCaptureShim --product AfterRayCaptureShim` (Makefile:14-15); binary at `.build/release/AfterRayCaptureShim` under this directory
- `swift test --package-path apps/AfterRayCaptureShim` — the package's own XCTest suite (`Tests/AfterRayCaptureShimTests`), covering the pure policy target `Sources/AfterRayCapturePolicy` (browser privacy, display selection, R3 pacing). `make test` runs it; plain `swift test` at the root does not. Logic that must be tested belongs in that target — the executable needs live TCC permissions.
- Smoke test: run the binary with `--output-dir /tmp/…`, then send `{"command":"capture_screen","request_id":"smoke-1"}` on stdin (see this directory's `README.md`)

## Watch out

- Building the root Swift package does not build this shim; `make build` includes it, plain `swift build` does not.
- Needs Screen Recording permission to produce frames — run via the signed dev app (`make v0`) for a stable TCC identity.
