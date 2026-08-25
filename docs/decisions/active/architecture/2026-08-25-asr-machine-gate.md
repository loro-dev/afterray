# Decision: Transcription waits for an idle, quiet, GPU-free machine

Status: active
Area: models
Anchors:
- crates/afterrayd/src/compute.rs @dec:asr-machine-gate
Supersedes: —
Superseded-by: —

## Problem

The transcription sweeper ran whenever it fired — every 60 seconds, or 300 on battery —
regardless of whether the user was typing or the machine was already busy. Each run is a
multi-second Metal job on the same Apple Silicon GPU as everything else, so ASR could
pile onto an active machine exactly the way summaries were already forbidden to. The GPU
lane serializes AfterRay's own GPU jobs against each other, but says nothing about user
activity or external load. User direction (2026-08-25): ASR should infer only when load
is low and the user is idle, like LLM summaries.

## Decision

`asr_may_run` applies the summary gate's idle and load conditions — same constants
(`T2_MIN_IDLE_SECONDS`, `T2_MAX_LOAD_PER_CORE`), same refusal codes and measurement-bearing
reasons — and `decide` chains the machine-GPU check (`gpu_may_run`) onto transcription
exactly as it does for summaries. A forced "run now" skips these machine conditions for
ASR just as for summaries, and still reaches the battery throttle (`asr_sweep_interval`),
which is unchanged: on battery the durable audio backlog drains at the slower cadence
rather than stopping.

The power conditions are deliberately not shared. Summaries require AC and ≥30% charge;
transcription keeps its throttle-not-stop policy, because the audio rows are a durable
backlog — late is fine, never is not.

## Alternatives considered

**Apply the full summary gate, AC and battery included.** Rejected: it would silently
reverse the standing throttle-not-stop decision (`transcription_slows_down_on_battery_rather_than_stopping`),
and the user asked for idle + load, not power.

**Leave ASR ungated now that the GPU lane exists.** Rejected by the user direction above;
the lane orders AfterRay's own jobs but cannot see that the user is active or that another
app owns the GPU.

**Separate ASR thresholds.** Rejected: one set of constants for "the user would feel this"
keeps the panel's explanation coherent, and hand-copied thresholds have already drifted
once in this codebase.

## Consequences

On an actively used machine, transcription waits for the first two-minute idle gap with a
quiet CPU and GPU; the dashboard's ASR row now shows real refusal reasons ("in use 40s
ago, needs 120s") instead of running unconditionally. T2's fourth gate already tolerates
late transcripts (`asr_wait_verdict`, 30-minute cap), so cards degrade the same way they
did when ASR was merely slow. On battery with an idle machine the backlog still drains,
at 300-second cadence.
