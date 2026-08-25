# Decision: Show ASR backlog as recorded time

Status: active
Area: recall-ui
Anchors:
- crates/afterray-protocol/src/lib.rs @dec:asr-backlog-duration
- crates/afterray-store/src/lib.rs @dec:asr-backlog-duration
- swift/AfterRayRecall/Sources/ComputeActivityPanel.swift @dec:asr-backlog-duration
Supersedes: —
Superseded-by: —

## Problem

A transcription backlog expressed only as a segment count gives no usable sense
of the recording volume awaiting work. Segment boundaries are an implementation
detail and vary by capture behavior.

## Decision

The vault sums the recorded duration of every ASR-claimable and alignment-
claimable segment in the same cached backlog read that provides its count. The
compute status protocol carries that value as optional `backlog_duration_ms`.
Only ASR supplies it, and the work panel presents that duration as audio waiting
for transcription; every other workload continues to present a count.

## Alternatives considered

**Estimate duration from segment count.** Rejected because segment lengths are
not fixed and such an estimate would misrepresent the user’s recorded data.

**Show only a duration for fresh transcription work.** Rejected because forced
alignment still processes the same recorded timeline and belongs to the ASR
backlog the panel reports.

## Consequences

The ASR row answers how much audio is waiting without adding a polling query or
exposing the vault to Swift. A duration can coexist with the count in the wire
model for diagnostics, but the panel deliberately favors the human-readable
time value.
