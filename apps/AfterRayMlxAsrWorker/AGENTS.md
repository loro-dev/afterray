# AfterRay MLX ASR worker

Standalone SwiftPM helper that implements the Rust one-shot worker protocol for
Qwen3 ASR. It is deliberately outside the root Swift package: its MLX Audio
dependency has a separate tools/version graph from the Qwen3.5 VLM worker.

- stdin/stdout are one JSON request/response; stdout contains no diagnostics.
- The helper accepts only `asr` input and loads an already verified local model
  directory from `AFTERRAY_ASR_MODEL`; it never resolves a Hub repository.
- The Rust downloader owns files and the ready marker. The helper must not
  repair, download, or mutate a pack.

Build with `swift build --package-path apps/AfterRayMlxAsrWorker --product afterray-mlx-asr-worker`.
