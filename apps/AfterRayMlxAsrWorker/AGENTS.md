# AfterRay MLX ASR worker

Standalone SwiftPM helper that implements the Rust persistent NDJSON worker protocol for
Qwen3 ASR. It is deliberately outside the root Swift package: its MLX Audio
dependency has a separate tools/version graph from the Qwen3.5 VLM worker.

- stdin/stdout are one NDJSON request/response stream; stdout contains no diagnostics.
- The helper accepts `load` and `asr_generate`, and loads an already verified local model
  directory from `AFTERRAY_ASR_MODEL`; it never resolves a Hub repository.
- Capture audio is 48 kHz stereo AAC; Qwen3 ASR consumes 16 kHz mono samples and
  derives duration from that sample count. `loadAudioForASR` downmixes, resamples
  in chunks, and keeps the source wall-clock length — do not hand 48 kHz frames
  to `generate` or use a one-shot converter.
- The Rust downloader owns files and the ready marker. The helper must not
  repair, download, or mutate a pack.

Build with `swift build --package-path apps/AfterRayMlxAsrWorker --product afterray-mlx-asr-worker`.
