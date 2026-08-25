# Decision: An empty ASR result is a completed transcript

Status: active
Area: models
Anchors:
- crates/afterray-models/src/persistent_mlx.rs @dec:asr-empty-transcript-results
- apps/AfterRayMlxAsrWorker/Sources/main.swift @dec:asr-empty-transcript-results
- crates/afterray-store/src/lib.rs @dec:asr-empty-transcript-results
Supersedes: —
Superseded-by: —

## Problem

An audio segment can contain no intelligible speech. Treating that ordinary
result as a worker failure leaves the durable segment pending and repeatedly
spends GPU time on an input that has already been processed.

## Decision

The persistent MLX worker protocol uses `final` only for a successful
completion. An ASR `final` response requires a `text` field, and that field
may be the empty string. A non-empty result is committed as transcript
evidence. An empty result means there is no intelligible speech worth keeping:
the daemon deletes that segment and its encrypted audio artifact, does not
retry it, and retains only a bounded ASR-health timestamp. A worker failure
uses `error`, with a structured `retryable` boolean; scheduling never infers
retryability from error text.

The protocol is version 3. Both managed MLX workers and the Rust adapter use
the same version, so an old helper cannot silently reinterpret the result.

## Alternatives considered

**Use a separate `empty` terminal response.** Rejected because `final` already
states that the operation completed; adding a second successful terminal kind
would give the same durable state two wire representations.

**Reject empty text and rely on retries.** Rejected because silence, noise, and
unintelligible audio are input outcomes that retries cannot correct.

**Encode retryability in the error message.** Rejected because text is for a
human diagnosis and cannot be a stable scheduling interface.

## Consequences

Silent or unrecognised audio leaves no recording clip or playback entry,
rather than a failed ASR job. The ASR health gate still knows that the worker
successfully completed on a quiet machine. A missing `text` field on an ASR
`final` response remains a protocol error, so malformed responses are not
mistaken for silence.
