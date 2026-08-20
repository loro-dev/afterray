# Decision: Shutdown is ACK-first, drain-scoped, and time-bounded

Status: active
Area: capture
Anchors:
- apps/AfterRay/Sources/AfterRayApp.swift @dec:bounded-shutdown
- apps/AfterRay/Sources/DaemonSupervisor.swift @dec:bounded-shutdown
- swift/AfterRayRecall/Sources/DaemonClient.swift @dec:bounded-shutdown
- crates/afterrayd/src/main.rs @dec:bounded-shutdown
- crates/afterray-platform-macos/src/lib.rs @dec:bounded-shutdown
- crates/afterray-models/src/queue.rs @dec:bounded-shutdown
Supersedes: —
Superseded-by: —

## Problem

Application termination crosses AppKit, a Unix-socket RPC, a Tokio runtime, native capture,
model workers, downloads, and an AV1 thread. Treating all of that work as equally valuable
makes Quit depend on long network, model, helper, and sleep timeouts. Killing everything at
once bounds the delay but can lose the final capture artifact, an audio segment, or the close
of the active vault session.

## Decision

Quit claims one synchronous, process-wide terminating state before any asynchronous cleanup.
That state removes the menu extra and forbids daemon start, keep-alive, recording recovery, and
new user work. Its one cleanup task awaits both temporary summary-export cleanup and daemon
teardown before replying to AppKit.

The daemon writes the shutdown ACK before it enters draining. Draining stops admission and
cancels socket work, downloads, chat turns, model jobs, persistent workers, periodic tasks, and
the GOP packer. Disposable work receives no durability budget.

Capture is the exception. The shim receives a short graceful stop window in which it flushes
input events, finalizes open audio, emits artifacts, and closes stdout. If it misses that window,
the daemon kills and reaps it. EOF wakes the consumer, but is graceful only after a protocol
`Stopped`; otherwise it is an explicit failure. The consumer imports events already emitted.
The helper process wait is short and bounded. After a successful child exit, its finite stdout
reader may be backpressured by the bounded event channel and therefore drains without a local
timeout. Draining that stream through `Stopped`, memory flush, and active vault-session close are
required durability work and are never cancelled by a daemon-local timeout. A helper already
forced down or known failed gives its reader and consumer only short recovery windows.

The app uses a shutdown-specific RPC deadline, waits for process death or socket removal, and
only then escalates through SIGTERM and SIGKILL. A status RPC is never used as an exit probe.

## Alternatives considered

**Send shutdown and immediately SIGTERM.** Rejected because it races the ACK and the daemon's
only durable work: capture finalization and session close.

**Wait for every background task to finish.** Rejected because remote model calls, downloads,
AV1 encoding, blocking maintenance, and long startup sleeps have no shutdown-time value and no
shared upper bound.

**Delete unfinished capture staging on exit without draining it.** Rejected because a normal
Quit would silently lose the final frame or audio segment even though the helper was healthy.

## Consequences

Normal Quit spends time only on export cleanup, the ACK, capture finalization/import, and session
close. A wedged helper is bounded by its own deadlines. A daemon wedged in required durable I/O
is bounded externally by the supervisor's process escalation, and logs identify which phase
consumed the budget.

Some disposable work is abandoned: in-flight OCR, ASR, summaries, chat/model output, downloads,
maintenance, and an AV1 encode may not finish. Their durable inputs remain retryable, partial
downloads remain resumable, and the process-level SIGKILL remains the final bound for code that
cannot cancel cooperatively.
