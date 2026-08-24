# Decision: Managed MLX workers load on demand and exit after two idle minutes

Status: active
Area: models
Anchors:
- crates/afterray-models/src/persistent_mlx.rs @dec:mlx-idle-lifetime
- crates/afterrayd/src/compute.rs @dec:mlx-idle-lifetime
- crates/afterrayd/src/main.rs @dec:mlx-idle-lifetime
Supersedes: —
Superseded-by: —

This narrows [MLX requests are isolated and Qwen3.5 prefill is
windowed](2026-08-20-mlx-prefill-and-request-isolation.md): its request
isolation and bounded-shutdown rules still govern, while residency is bounded.

## Problem

A managed MLX worker holds several gigabytes of unified memory after inference
finishes. Keeping that process alive indefinitely makes an occasional summary
look like a permanent memory cost. Starting an automatic summary after only a
brief input pause also loads those weights while the user is still working.

## Decision

An automatic T2 summary requires 120 continuous seconds without user input, in
addition to the existing battery, load, compute-mode and queue gates. Explicit
"run now" work and interactive requests keep their existing bypass behavior.

The daemon checks each managed MLX adapter every five seconds. An adapter records
when its last request finishes and ends its worker after 120 seconds without
another request. Generation and the idle check use the same mutex: an active
request cannot be reaped, and a request racing the boundary either reuses the
old worker or cold-loads a new one after cleanup.

The whole worker process exits. The next local request starts a fresh process
and reloads the selected pack. This policy applies only to AfterRay's managed
MLX workers; it does not change an external Ollama server's lifetime.

## Alternatives considered

**Keep the worker resident until provider switch or daemon shutdown.** This
preserves the fastest next request but turns sporadic local inference into a
permanent multi-gigabyte memory cost.

**Set the Swift `ModelContainer` to `nil` inside the worker.** Framework and
Metal allocators may retain pages after the object graph is released. Process
exit gives the daemon an observable boundary and lets macOS reclaim all model,
allocator and request-cache memory together.

**Exit immediately after every request.** This minimizes residency but pays
the full model load cost for adjacent summary slots and interactive follow-ups.
The two-minute window preserves short bursts while bounding the idle cost.

## Consequences

**Bought:** automatic summaries do not begin during short pauses, and a local
model's weights, Metal allocations and request cache leave memory within roughly
120–125 seconds after the last request finishes.

**Cost:** the first request after an idle unload pays the full process startup,
snapshot verification and model-load latency. The five-second reaper cadence
means release is bounded to one check interval after the two-minute threshold.
