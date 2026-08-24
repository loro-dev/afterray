# Decision: Summaries wait while the machine's GPU is busy elsewhere

Status: active
Area: models
Anchors:
- crates/afterray-platform-macos/src/gpu.rs @dec:gpu-utilization-gate
- crates/afterrayd/src/compute.rs @dec:gpu-utilization-gate
Supersedes: —
Superseded-by: —

## Problem

The summary gate reads only CPU-side conditions: AC power, battery charge,
idle time, and the one-minute load average per core. Its most expensive
workload is a 200-second local model pass that runs on the GPU, and the load
average cannot see GPU load at all. A game, someone else's local LLM, or a
video export elsewhere on the machine saturates the same Apple Silicon GPU
the summary pass is about to pile onto — on a machine the gate reads as
completely quiet. The [GPU lane](2026-08-24-gpu-lane-serialization.md)
serializes AfterRay's own GPU jobs against each other, but says nothing about
load that is not AfterRay's.

## Decision

The daemon samples machine-wide GPU utilization once a second through public
IOKit: the `AGXAccelerator` service's `PerformanceStatistics` dictionary,
key `Device Utilization %` (falling back to `GPU Activity(%)`), exposed by
`afterray_platform_macos::gpu_utilization()`. The governor keeps the newest
fifteen readings; after the CPU gate passes, summaries may run only when the
average over the last fifteen seconds is at or below 0.5.

The gate is fail-closed, exactly like the load average: a failed probe
records no sample, so the window goes stale, and an empty or stale window
holds summaries with "GPU utilization unavailable" — an unanswered probe is
never read as "idle". `AFTERRAY_GPU_PROBE=0` at daemon launch skips the check
and never starts the sampler. A "run now" override bypasses the gate with the
rest of the machine conditions: the user pressing start is newer information
than any reading. Only summaries carry the check; see below for why ASR and
Archive do not.

## Alternatives considered

**Private IOReport `GPUPH` residency.** The mactop/macmon/apple-smi route:
per-cluster GPU residency through the private `IOReport` framework. Rejected
with the rest of private-framework FFI: it means linking a private framework
into a workspace that confines `unsafe_code` to one crate on purpose, plus a
notarization and OS-upgrade risk the public `PerformanceStatistics` key does
not carry.

**`powermetrics`.** Reports machine-wide GPU residency, but needs root. The
daemon runs as the user and stays that way.

**An OCR-duration proxy probe.** Infer GPU contention from how long AfterRay's
own OCR passes take. Rejected as the primary signal because the confounds are
unmanageable — OCR time moves with thermal pressure, memory pressure, and
model state as much as with external GPU load, and a gate that fires on its
own workload's slowdown is a feedback loop. Kept in mind as the fallback if
the AGX statistics key ever stops answering.

**GPU gates on ASR and Archive too.** Rejected. The ASR backlog is durable
(audio rows wait in the vault), is already serialized through the GPU lane,
and already throttles on battery — a wait costs minutes, never data. Archive
is an all-core CPU encode with no GPU to contend for.

**Per-process GPU accounting.** Still does not exist as a public macOS API;
that is why the dashboard reports lanes instead of percentages, and this gate
works from a machine-wide reading instead.

## Consequences

Summaries arrive later whenever something else keeps the GPU above half busy —
which is the intent: those are exactly the moments the user would feel a
200-second pass. The gate cannot distinguish AfterRay's own running summary
from external load, but it is consulted before a pass starts, so a pass in
flight never holds itself off; back-to-back passes of a backlog drain with
the sweep interval between them. On Intel Macs there is no `AGXAccelerator`
service, the probe always answers `None`, and summaries hold with "GPU
utilization unavailable" until `AFTERRAY_GPU_PROBE=0` — releases ship Apple
Silicon only, so this is a corner the fail-closed default accepts rather than
a gap.
