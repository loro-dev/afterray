# Decision: Background local-GPU work is serialized through one priority lane

Status: active
Area: models
Anchors:
- crates/afterray-models/src/queue.rs @dec:gpu-lane-serialization
Supersedes: —
Superseded-by: —

## Problem

Screen text (Vision), transcription (Qwen3-ASR), embeddings, and local LLM summaries all
run on the same Apple Silicon GPU/ANE through separate worker processes. The model queue
limited concurrency only per capability, so an OCR pass, a transcription, and a 200-second
background summary could all run at once — exactly when the user also feels the machine.
There was no way to say "one heavy GPU job at a time" without also saying "one job per
capability", which the per-capability semaphores already do.

## Decision

The model queue owns a GPU lane: one permit, taken by every background job whose adapter
reports `uses_local_gpu(input)`, before the job takes its capability slot. Taking the GPU
slot first is what keeps a background summary queued behind a transcription from holding
the LLM lane hostage — with the opposite order an interactive chat would wait behind both.
With one GPU permit, the capability slot of whoever holds the lane is always free, so the
ordering cannot deadlock.

Admission is by class, then arrival: OCR forms its own class ahead of everything else
(short, on the capture critical path, and a frame that goes un-OCR'd is never indexed
later); ASR, embeddings, and background LLM work share a background class (their backlogs
are durable, so waiting costs latency, never data). Waiters cancelled while queued are
skipped at hand-over. A completed admission wins a tie against cancellation, because the
cancel path (`set_running` fails on a Cancelled job) releases the permit, while dropping an
admission would strand it.

Interactive LLM work bypasses the lane entirely, as it bypasses the compute governor: a
chat reply the user is watching never queues behind background work. Leased agent-loop
rounds bypass it too — they are the same user-facing stream — and they must: a leased
round waiting on the lane deadlocks against a plain background job that already holds
the lane, because the loop's own lease hold keeps that job out of the LLM gate, so
neither can ever advance. Remote LLM endpoints
(Ollama, OpenAI-compatible) do not touch the local GPU; `LlmRouterAdapter` answers
`uses_local_gpu` from the live provider setting, per job, so switching providers takes
effect without a restart. `AFTERRAY_GPU_LANE=0` at daemon launch restores the old
free-for-all scheduling.

## Alternatives considered

**One FIFO semaphore for all GPU work.** Rejected because an interactive chat could queue
behind several background jobs, including a 200-second summary. The LLM lane's priority
gate exists precisely because "interactive must never sit behind a background pass" was
measured to matter; a FIFO lane would regress that at GPU scope.

**Include interactive work in the lane.** Rejected on the same principle the governor
uses: interactive work is never governed. Strictly serializing it either stalls a chat
reply behind a full summary pass, or requires killing the running pass — and killing
in-flight work is already rejected by the drain-don't-kill rule for suspension.

**Gate at the sweepers instead of the queue.** Rejected because the sweeper-level checks
already proved to drift (the T2 sweep checks `ocr_in_flight`; the ASR sweep checks
nothing), and new submitters would each have to remember to check. A queue-level lane
covers every current and future submitter.

## Consequences

Background GPU work takes longer to drain under load: jobs spend time pending in the lane
where they previously ran concurrently, and the compute dashboard shows them as pending in
their capability. While an interactive chat or agent loop holds the LLM lane, a background
LLM pass holding the GPU lane waits with it, so all background GPU work yields to the
active user — which is the intent, not a side effect.

Per-capability concurrency limits still apply but are dominated by the lane's single
permit (embeddings are configured at 2 and now effectively run one at a time). The
sweeper-level `ocr_in_flight()` yields remain: the GOP packer is CPU work with its own
reasons to yield, and the T2 sweep's check avoids submitting a job that would only queue.
