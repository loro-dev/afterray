# AGENTS.md — apps/AfterRayNativeModelWorker

A one-shot macOS Vision OCR worker (root `Package.swift` target, product `afterray-native-model-worker`), spawned per request by the Rust daemon (`crates/afterray-models`). The whole worker is `Sources/main.swift` (~136 lines).

## Protocol (one-shot worker protocol, v1)

- Single JSON object in on stdin, single JSON object out on stdout; snake_case keys (`protocol_version`, `image_path`, …); `protocolVersion = 1` (`main.swift:6`)
- Errors are reported as `{error, retryable}` on stdout with a normal exit — do not crash on bad input (`main.swift:127-135`)
- Only handles `capability == "ocr"` with `input.type == "ocr"` (`main.swift:107`)

## Key behavior

- `VNRecognizeTextRequest` at `.accurate` with `zh-Hans`/`zh-Hant`/`en-US` (`main.swift:77-80`)
- Returned region geometry is Vision-normalized with **bottom-left origin** — consumers flip Y (`main.swift:41-42`)

## Build / run

- `swift build --product afterray-native-model-worker` (release binary at `.build/release/afterray-native-model-worker`)
- The daemon locates it via the `AFTERRAY_NATIVE_MODEL_WORKER` env var (`crates/afterrayd/src/main.rs:178`); `scripts/run-v0.sh` and `DaemonSupervisor` set it in dev
- Smoke test: pipe one request JSON to the binary, e.g. `echo '{"protocol_version":1,"capability":"ocr","input":{"type":"ocr","image_path":"/tmp/x.png"}}' | .build/release/afterray-native-model-worker`

## Watch out

- `scripts/download-models/afterray_model_worker.py` is legacy and unused — the daemon launches this Swift binary (OCR) and the Rust `afterray-model-worker`, not any Python.
