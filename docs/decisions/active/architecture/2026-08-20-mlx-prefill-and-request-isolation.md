# Decision: MLX requests are isolated and Qwen3.5 prefill is windowed

Status: active
Area: models
Anchors:
- crates/afterray-models/src/persistent_mlx.rs @dec:mlx-prefill-and-request-isolation
- swift/AfterRayMlxVlmWorker/Sources/WorkerCore.swift @dec:mlx-prefill-and-request-isolation
Supersedes: —
Superseded-by: —

## Problem

The persistent MLX worker receives a complete prompt for every daemon job. Two
independent summaries often have the same system instructions, but that does
not make them turns in one conversation. Reusing a `ChatSession` on that basis
retains the first job's KV state and appends the next complete prompt to it.

Qwen3.5 also needs bounded prefill. A full-length attention mask grows with the
product of query and key length, so a long prompt can request a single Metal
buffer much larger than physical memory even though model weights and the KV
cache themselves fit.

## Decision

The worker keeps the loaded `ModelContainer` resident, but creates a fresh
`ChatSession` for every `generate` request. The worker protocol is stateless:
it has no cross-request cache flag, cache result, or implicit conversation
identity.

Shutting down an MLX adapter first requests cooperative cancellation. The
child-process handle is independent of the mutex that serializes worker I/O;
if cancellation does not release that mutex within a short grace period,
AfterRay kills the child directly. A provider or managed-pack switch is
therefore bounded by the shutdown grace period, not the generation timeout.

AfterRay pins `mlx-swift-lm` to upstream revision
`65be34c64237c0b5da348169d3a9b59f37453fe2`, which implements windowed prefill
for Qwen3.5. The revision pin remains until a released version containing that
change passes the same real-model regression.

## Alternatives considered

**Reuse sessions when system instructions match.** This is the behavior that
failed. A system prompt is shared configuration, not a conversation identity,
so this mixes unrelated summaries and continually grows the retained context.

**Retry without cache after a cache-prefill error.** A Metal allocation failure
can terminate the worker before it returns a protocol error. Retrying therefore
cannot make the first attempt safe, and it also duplicates work when the error
is recoverable.

**Only cap or truncate AfterRay prompts.** A cap can be defense in depth, but it
would trade summary quality for headroom and would not correct the runtime's
quadratic temporary allocation. Windowed prefill fixes the allocation shape.

**Wait for the active request before shutting down the old provider.** This
keeps an obsolete summary running after the user has selected another provider
and can block the settings request for the full generation timeout.

**Keep the child handle behind the generation I/O mutex.** This makes orderly
protocol teardown simple, but prevents shutdown from killing a process stuck
inside a Metal operation while generation owns that mutex.

## Consequences

**Bought:** independent jobs cannot inherit each other's conversation or KV
state, and long Qwen3.5 prompts prefill in bounded windows instead of requesting
a full quadratic Metal attention buffer. The heavyweight model remains loaded,
so switching jobs does not reload weights. Switching provider or MLX pack
cancels the old active generation before tearing down its worker.

**Cost:** every request prefills its complete prompt. The dependency temporarily
uses a commit revision rather than a release tag, so upgrades must explicitly
check whether a tagged release contains the fix and rerun the real-model test.
