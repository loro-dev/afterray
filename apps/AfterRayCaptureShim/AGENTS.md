# AGENTS.md — apps/AfterRayCaptureShim

The ScreenCaptureKit boundary for the Rust daemon. It exists because the Rust workspace denies `unsafe_code` and ScreenCaptureKit delegates need unsafe FFI (see `README.md` here). A **standalone SwiftPM package** — its own `Package.swift` and `.build/`, deliberately not a target of the root package. The whole shim is one file: `Sources/AfterRayCaptureShim/main.swift` (~1026 lines).

## Key anchors

- `main.swift:25` `Options` (`parse` at :31) — CLI flags (`--output-dir`, `--jpeg-quality`, audio, …)
- `main.swift:99` `Event` — JSON-line event protocol emitted on stdout (`ready`, `artifact`, `warning`, `failed`, `stopped`)
- `main.swift:892` `InputCommand` — stdin commands; main loop at :962-990 handles `capture_screen` (requires `request_id`) and `stop`
- `main.swift:1002` `log()` — logging goes to **stderr only**

## Invariants

- stdout is reserved for JSON-line events — never print anything else there; the daemon parses it.
- Screenshots are pull-based: Rust decides timing (`capture_screen`), the shim adds no hidden frame scheduler (`main.swift:861-862`).
- Output dir is hardened to `0700`, artifact files to `0600` (`main.swift:13,20`).
- The shim excludes AfterRay's own windows from capture (`main.swift:941-948`).
- Requires **macOS 15** (`Package.swift:6`) while the rest of the app targets macOS 14 — intentional, not a bug.

## Build / test

- `make capture-shim` → `swift build --package-path apps/AfterRayCaptureShim --product AfterRayCaptureShim` (Makefile:14-15); binary at `.build/release/AfterRayCaptureShim` under this directory
- Smoke test: run the binary with `--output-dir /tmp/…`, then send `{"command":"capture_screen","request_id":"smoke-1"}` on stdin (see this directory's `README.md`)

## Watch out

- Building the root Swift package does not build this shim; `make build` includes it, plain `swift build` does not.
- Needs Screen Recording permission to produce frames — run via the signed dev app (`make v0`) for a stable TCC identity.
