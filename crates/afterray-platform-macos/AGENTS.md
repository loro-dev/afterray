# crates/afterray-platform-macos — capture shim & machine probes

macOS platform glue for the daemon: owns the `AfterRayCaptureShim` child process (ScreenCaptureKit lives in Swift, not here) and its JSON-lines stdin/stdout protocol, plus the power/idle/load/locale probes that feed the daemon's fail-closed gates. Capture *policy* (when to screenshot) stays in `afterrayd`; this crate only manages the process and protocol.

## Key anchors

- `lib.rs:151 MacOsCaptureBackend` — spawns/owns the shim child; commands `capture_screen`/`set_excluded_bundles`/`stop` to stdin, `CaptureEvent` stream (`ready`/`artifact`/`warning`/`failed`/`stopped`) from stdout. Bounded channel of 128 (`EVENT_BUFFER_CAPACITY`, lib.rs:31) for backpressure; single-consumer `next_event`.
- `set_excluded_bundle_ids` — remembers the list and pushes it to a running shim; `start_capture` writes it into the child's stdin *before* returning, so the helper has it before the first audio sample buffer. Screen exclusions are not sent here — they stay in the daemon.
- `lib.rs:108 ArtifactKind` — `screen | system_audio | microphone | accessibility`.
- `power.rs` — `on_ac_power`, `battery_fraction`, `seconds_since_user_input`, `load_per_core`, `apply_background_qos` (used by the T2 gate and the GOP packer thread).
- `locale.rs` — `preferred_languages`.

## Build / test

- `cargo test -p afterray-platform-macos`. The shim itself is built by `make capture-shim` (SwiftPM, `apps/AfterRayCaptureShim`); override its path with `AFTERRAY_CAPTURE_SHIM`.

## Watch out

- **Only workspace crate allowed `unsafe_code`** (`#![allow(unsafe_code)]`, lib.rs:7; the workspace denies it). Keep Apple-framework FFI minimal and confined to this crate.
- Probes feed fail-closed gates: return `None`/conservative values on failure, never guess — a fabricated "idle" or "on AC" answer makes the daemon burn battery on T2 summaries.
- Don't add capture scheduling or artifact storage here; events go to the daemon, which imports them into `afterray-store`.
