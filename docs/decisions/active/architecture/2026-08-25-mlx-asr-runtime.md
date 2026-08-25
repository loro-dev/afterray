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
separate SwiftPM MLX helper that accepts only the existing one-shot worker
protocol and loads only the verified local model directory. It never contacts
Hugging Face or writes a cache at inference time.

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
background GPU serialization remain unchanged; the later persistent-worker
change may reuse this helper protocol only after its lifecycle is explicitly
validated.
