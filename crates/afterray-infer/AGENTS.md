# AGENTS.md — afterray-infer

In-process ASR (Qwen3-ASR via Candle/Metal), transcript forced alignment (Qwen3-ForcedAligner via CPU/Accelerate), and embedding (nomic GGUF via llama-cpp-2) backends, compiled into the `afterray-model-worker` one-shot binary that `afterrayd` spawns through `afterray_models::ProcessAdapter`. It deliberately rejects OCR (handled by the Swift Vision worker) and LLM (handled by `LlmRouterAdapter`).

## Layout

- `src/lib.rs:43 execute` — dispatches `ModelInput`; errors on `Ocr` and `Llm`. `sanitize_asr_text` (`:74`) drops hallucinated "thank you" ASR loops. `InferConfig::from_env` (`:28`) pulls model paths from the `afterray-models` catalog.
- `src/bin/afterray-model-worker.rs` — the shipped worker binary (`[[bin]]` in `Cargo.toml`); speaks the v2 one-shot protocol from `afterray-models`: one JSON request on stdin, one JSON response on stdout, logs/timing on stderr only.
- `src/asr.rs:19 transcribe` — Qwen3-ASR via `qwen3-asr`/Candle Metal; prepares the generated tokenizer through `afterray-models` before decoding audio, and reports preparation/load failures as non-retryable missing-model errors.
- `src/align.rs` — Qwen3 forced alignment via `qwen-asr`; normalizes the official language set and groups character/word timings into bounded sentence-sized cues.
- `src/embed.rs:19 embed_text` — nomic GGUF via llama-cpp-2, 2048-token batch, L2-normalized output.
- `src/audio.rs:15 load_mono_16k` — Symphonia decode + rubato resample to mono 16 kHz f32 before ASR.

## Watch out

- stdout is protocol-only: a stray `println!` kills the job as `InvalidOutput` at the parent. Log to stderr.
- Honor the wire retry semantics: `retryable: true` in `WorkerResponse` maps to a retried `AdapterError::Process`, `false` maps to `MissingModel` and never retries. Never return placeholder inference data.
- Model path overrides: `AFTERRAY_ASR_MODEL` / `AFTERRAY_ALIGNER_MODEL` / `AFTERRAY_EMBEDDING_MODEL` (surfaced in this crate's error messages); the daemon overrides the worker binary itself with `AFTERRAY_MODEL_WORKER`.
- ASR and embedding use Metal; the aligner is pure Rust CPU with Accelerate/vDSP on Apple Silicon. Each inference is a separate worker process, so these models are not resident together.
- Replacing Candle ASR with MLX is a proposal, not current behavior: [qwen3-asr-mlx-integration-plan.md](../../docs/qwen3-asr-mlx-integration-plan.md).

## Build / test

- `cargo test -p afterray-infer`
- `cargo build --release -p afterray-infer` → `target/release/afterray-model-worker`, which is the daemon's dev-default worker path (`afterrayd/src/main.rs:174`).
