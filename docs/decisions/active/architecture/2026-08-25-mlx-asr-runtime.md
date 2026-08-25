# Decision: Qwen3 ASR runs through a local MLX helper

Status: active
Area: models
Anchors:
- crates/afterrayd/src/main.rs @dec:mlx-asr-runtime
Supersedes: —
Superseded-by: —

## Problem

The shipped Candle Qwen3 ASR worker loads a multi-gigabyte BF16 snapshot for
each audio job and consumes enough CPU during model orchestration to make the
computer unusable for users with an ASR backlog.

## Decision

The default `asr` pack is the SHA-256-pinned
`mlx-community/Qwen3-ASR-1.7B-4bit` snapshot. The daemon sends ASR jobs to a
separate SwiftPM MLX helper. The helper loads only the verified local model
directory, then serves serial NDJSON requests in one process. Its process and
idle-reclamation check share the same mutex, so an active transcription cannot
be mistaken for idle. The daemon reclaims the helper after 120 seconds without
a completed request; the next ASR job starts and verifies a fresh process. It
never contacts Hugging Face or writes a cache at inference time.

The helper remains separate from the Qwen3.5 VLM package because its dependency
graph has its own MLX runtime version. Forced alignment remains a distinct CPU
stage: a transcription is committed before alignment and an alignment failure
does not remove text.

## Alternatives considered

**Keep Candle ASR and wait for a broader evaluation.** Rejected because users
reported that the present CPU cost makes the app unusable.

**Run Python mlx-audio in production.** Rejected because model downloading and
inference workers are native Rust/Swift components, not a Python runtime.

**Put ASR in the existing VLM worker.** Rejected because independent helper
processes contain MLX runtime and allocator failures and keep the VLM pin
isolated.

## Consequences

ASR downloads a new approximately 1.61 GB model pack. Existing Candle packs
are not considered ready for the default ASR path. The queue contract and its
background GPU serialization remain unchanged. Cancellation kills the helper
instead of leaving a synchronous MLX generation's future stdout line to be
misread by the next job; the following job reloads in a new process.
