# AGENTS.md — apps/AfterRayCaptureShim

The ScreenCaptureKit boundary for the Rust daemon. It exists because the Rust workspace denies `unsafe_code` and ScreenCaptureKit delegates need unsafe FFI (see `README.md` here). A **standalone SwiftPM package** — its own `Package.swift` and `.build/`, deliberately not a target of the root package. The whole shim is one file: `Sources/AfterRayCaptureShim/main.swift` (~1350 lines).

## Key anchors

- `main.swift:25` `Options` (`parse` at :31) — CLI flags (`--output-dir`, `--jpeg-quality`, audio, …)
- `main.swift:99` `Event` — JSON-line event protocol emitted on stdout (`ready`, `artifact`, `warning`, `failed`, `stopped`)
- `main.swift:1213` `InputCommand` — stdin commands; main loop at :1289-1320 handles `capture_screen` (requires `request_id`), `set_excluded_bundles` (carries `bundle_ids`), and `stop`
- `main.swift:894` `ExcludedAudioGate` — drops audio while an excluded app is frontmost (see Invariants)
- `main.swift:1332` `log()` — logging goes to **stderr only**

## Invariants

- stdout is reserved for JSON-line events — never print anything else there; the daemon parses it.
- Screenshots are pull-based: Rust decides timing (`capture_screen`), the shim adds no hidden frame scheduler.
- Output dir is hardened to `0700`, artifact files to `0600` (`main.swift:13,20`).
- The shim excludes AfterRay's own windows from capture (`main.swift:1258-1265`).
- **A screen artifact is never emitted without its accessibility artifact** (`main.swift:1157`). The daemon's only exclusion check lives in the accessibility branch, so an unpaired screenshot can never be evaluated and would be kept whatever the user excluded. Every path that cannot produce a snapshot returns before the screenshot — keep it that way.
- **Audio exclusions are enforced here, screen exclusions in the daemon.** A moment can be deleted once the snapshot names the app; a finished five-minute `m4a` cannot be sliced. `ExcludedAudioGate` (`main.swift:901`) therefore answers "which stretch of the recent past had no excluded app in front", not "is one in front now": samples are **held** (`AudioSegmentWriter.hold`) until a check vouches for the moment they arrived, and dropped otherwise. Writing first and cutting on the next check would leave every sample since the previous check inside a file the daemon imports and transcribes. The frontmost app is polled (100 ms — latency, not exposure) because the main thread blocks in `readLine` and never services a run loop, so `NSWorkspace` notifications would not arrive; the helper also holds all audio until the daemon's list arrives, since an app in front before that cannot be judged.
- Requires **macOS 15** (`Package.swift:6`) while the rest of the app targets macOS 14 — intentional, not a bug.

## Build / test

- `make capture-shim` → `swift build --package-path apps/AfterRayCaptureShim --product AfterRayCaptureShim` (Makefile:14-15); binary at `.build/release/AfterRayCaptureShim` under this directory
- Smoke test: run the binary with `--output-dir /tmp/…`, then send `{"command":"capture_screen","request_id":"smoke-1"}` on stdin (see this directory's `README.md`)

## Watch out

- Building the root Swift package does not build this shim; `make build` includes it, plain `swift build` does not.
- Needs Screen Recording permission to produce frames — run via the signed dev app (`make v0`) for a stable TCC identity.
