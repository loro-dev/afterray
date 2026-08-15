# AfterRay Capture Shim

This executable is the narrow Apple-framework boundary for `afterrayd`. It uses
ScreenCaptureKit for display, system-audio, and microphone capture. It does not
own recording policy or persistence.

For a normal V0 development run, use the repository-level runner instead of
starting this helper directly:

```sh
make v0
```

It builds the shim, Rust workspace, and Swift app, then starts `afterrayd` with
one temporary socket and data directory. It prints exact CLI commands for
starting and stopping a recording. Recording is not started automatically, so
the runner does not claim that Screen Recording or Microphone permission has
already been granted. It also does not download models.

Use `make v0-daemon` to keep only the daemon in the foreground, or
`make v0-build` to compile all three pieces without starting anything.

The workspace denies unsafe Rust. Calling Objective-C delegates directly from
Rust currently requires unsafe FFI, so keeping this boundary in Swift makes the
capture path compile-time checked without moving daemon logic out of Rust.

Build it:

```sh
swift build --package-path apps/AfterRayCaptureShim -c release
```

Run a real smoke test (macOS prompts for Screen Recording and Microphone):

```sh
apps/AfterRayCaptureShim/.build/release/AfterRayCaptureShim \
  --output-dir /tmp/afterray-capture-smoke \
  --audio-segment-seconds 30 \
  --jpeg-quality 0.95
```

After the `ready` event, enter one command per line:

```json
{"command":"capture_screen","request_id":"smoke-1"}
{"command":"stop"}
```

Stdout is reserved for JSON-line events. JPEG and bounded M4A segments are
written beneath `--output-dir`; Rust consumes the paths and imports them into
the AfterRay store.

Before taking a screenshot, the shim checks the foreground browser's private
window state. Supported Chromium browsers expose a read-only AppleScript
window mode; Firefox and Accessibility chrome provide positive fallbacks. The
script never requests a tab URL or title. macOS may ask for Automation access
to the active Chromium browser. If that access is denied or a browser does not
expose a stable signal, detection remains best-effort rather than treating an
unknown result as a regular window.
