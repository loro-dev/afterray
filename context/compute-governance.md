# Compute governance: who decides that local work may run

Verified against code 2026-08-24.

AfterRay computes constantly on the user's own machine: screen text, transcripts,
search vectors, slot summaries, AV1 compression. This article is the map of what
decides whether that work runs, what the user can change, and how the app shows
it. Owners: `crates/afterrayd/src/compute.rs` (policy),
`crates/afterray-platform-macos/src/process.rs` (cost probes),
`crates/afterray-models/src/queue.rs` (what is running),
`swift/AfterRayRecall/Sources/ComputeActivity*.swift` (the dashboard).

## What changed, and why it needed changing

Before this existed, the answer was scattered and the app's story was not true:

| Workload | Where it runs | Gate before | Gate now |
|---|---|---|---|
| Screen text (OCR, Apple Vision) | `ProcessAdapter` child, per capture (~10s) | none | mode `off` only |
| Transcription (Qwen3-ASR) | `ProcessAdapter` child, 60s sweeper | none | governor: waits for an idle, quiet, GPU-free machine like summaries; throttled to 300s on battery |
| Search index (embeddings) | `ProcessAdapter` child, per evidence row | none | governor |
| Summaries (T2, local LLM) | persistent MLX worker, 5-min sweeper | AC + ≥30% battery + ≥30s idle + load/core ≤0.7 | governor: AC + ≥30% battery + ≥120s idle + load/core ≤0.7; worker unloads after 120s unused |
| Archive compression (rav1e) | thread **inside** the daemon | `AFTERRAY_GOP_REQUIRE_AC`, default **off** | governor only (`require_ac` removed) |

So "AfterRay stops computing on battery" described one of five workloads, and the
user had no way to see or change any of it. A laptop on battery was running an
all-core AV1 encode with nothing in the UI to say so.

## The governor

`crates/afterrayd/src/compute.rs` — `ComputeGovernor::decide(workload,
conditions, now_ms)` is the single gate. It returns `Ok(())` or a `GateRefusal`
carrying a `ComputeGateCode` and a `reason` string that **names the measurement**
("battery at 18% is below 30%", "in use 4s ago, needs 120s"), never a policy
label. That string is the most valuable thing in the dashboard: it answers "why
has nothing been summarised?", which no percentage can.

Inputs, in precedence order:

1. **Launch limits** (`ComputeLimits`) — `AFTERRAY_T2_SWEEP_SECONDS=0`,
   `AFTERRAY_GOP_ARCHIVE=0`. Reported as `disabled_by_env` so the panel never
   blames the battery for something an env var switched off.
2. **`ComputeMode`** — `full` / `essential` / `off`, persisted in `settings.json`.
3. **A user suspension** — a deadline (`compute_paused_until_ms`), also persisted.
4. **Machine conditions** — `MachineConditions::probe()`: AC, battery fraction,
   idle seconds, load per core, thermal level. Every probe fails closed: an
   unreadable value means wait.

### Three decisions worth keeping

**Interactive work is never governed.** A chat turn the user is watching stream
is not background computation. `JobPriority::Interactive` work never consults the
governor, and the panel says so in as many words. A power switch that silenced
chat would be read as a broken app.

**Suspending drains, it does not kill.** Gates are checked *before* work starts,
so anything in flight finishes. Killing a running OCR pass throws away the
compute already spent and, worse, the only chance to index that frame. The panel
says "anything mid-flight finishes" rather than leaving the user to wonder why
the fan is still up.

**Screen text is not pausable.** Nothing in the vault records that a frame went
un-OCR'd — there is no OCR backlog the way audio rows are a durable ASR backlog —
so a skipped frame is never indexed by anything, ever. An hour-long suspension
that silently cost an hour of searchable history would be a bad trade for a
fraction of one core, so the pause deliberately exempts OCR. Only `off`, whose
copy states the cost, stops it. **Adding an OCR backlog is what would make a
pause complete**; until then, do not extend the pause to cover it.

## The GPU lane: one background GPU job at a time

The governor decides whether background work may start; it does nothing about
what runs *together*. That is the model queue's job
(`crates/afterray-models/src/queue.rs` `GpuGate`): every background job whose
adapter touches the local GPU — OCR, ASR, embeddings, background LLM passes —
takes a single shared permit before its capability slot, so a transcription and
a 200-second summary never run at the same time. OCR rides its own class ahead
of the durable-backlog work; only interactive chat and remote LLM endpoints
bypass the lane. Leased background rounds (the T2 summariser's real shape)
ride it too — the gate mirrors the LLM gate's lease holds, so a plain
background job excluded by a hold parks at the lane holding nothing and cannot
deadlock the loop at the LLM gate. The GPU slot is taken *before*
the capability slot so a queued background summary never holds the LLM lane
hostage against an incoming chat. Decision and alternatives:
[docs/decisions/active/architecture/2026-08-24-gpu-lane-serialization.md](../docs/decisions/active/architecture/2026-08-24-gpu-lane-serialization.md).

What the dashboard sees: a job waiting at the lane is `Pending` in its
capability, so the per-capability pending counts in `QueueActivity` now include
lane waiters — "asr, 3 pending" can mean "3 jobs, one running, the rest queued
behind an OCR pass".

## Summary timing: "how much longer will I be slow?"

Summaries are the only workload whose *single run* is long enough that a user
feels it start and then wants to know when it ends, so they get a duration
history that nothing else does.

- **The log.** `run_slot_t2_recording` (main.rs) wraps every caller — the
  sweeper, `slot backfill`, and the manual `slot summarize` RPC — times the whole
  pass, and files it with the governor. The sweeper line reads
  `summarised slot=… in 2m 41s`; a failure reads `failed after 12.4s`. Timing
  wraps the *outer* call deliberately: queue wait is time the user sat through,
  and the model's own latency would under-report a pass that queued behind a
  chat turn. `human_duration` formats it the way the panel does, so a number in
  the log matches a number in the UI.
- **The window.** `ComputeGovernor` keeps the last `SUMMARY_HISTORY` (12) runs,
  newest first, and reports the **median of the successful ones** as
  `summary_typical_ms`. A median because one 20-minute outlier must not move the
  estimate shown for every later run; successful-only because a pass that died
  in nine seconds says nothing about how long a real one takes — though it stays
  in the list, since it still cost that time.
- **Across restarts.** `Vault::recent_summary_runs(limit)` reads the
  `latency_ms` already persisted in `slot_summaries`, and the daemon seeds the
  window once at startup — the moment a user who just updated the app might be
  wondering why their fans are up. There is no index on `produced_at_ms`, so
  this must never move onto the dashboard's polling path. A seed never displaces
  a live measurement: `seed_summaries` no-ops once the window has anything in it.
- **The estimate.** The panel shows `about 1m 20s left` on the running summary
  row (typical − elapsed) and a "Summary timing" section with the median and the
  last few runs. Once a pass outruns the typical duration the estimate goes
  quiet rather than sitting at "about 0s left": it is a median of past runs, not
  a progress bar, and pretending otherwise invites trust it cannot earn.

## Showing the pile, and starting it by hand

A gate that says "held: on battery" answers *why*. It does not answer "how much
is waiting" or "can I just run it now", which is what someone staring at a slow
machine actually wants.

- **The counts are from the vault, not the queue.** `ComputeGate.pending` is what
  reached the in-memory job queue — seconds of work. `ComputeGate.backlog` comes
  from `Vault::compute_backlog` plus `slots_awaiting_t2`, and is the pile:
  unsummarised slots, packable stills, audio awaiting transcription, and moments
  that still have a JPEG but no screen text. The UI shows
  `max(pending, backlog)`, because the queue count is a subset — adding them
  would claim 24 items when 23 exist.
- **Only drainable work is counted.** `unindexed_moments` excludes moments
  already packed into a GOP (their JPEG is gone and Rust cannot decode AV1 back)
  and looks back only a day. The archive and transcript counts reuse the
  *same SQL predicate* as `list_pack_candidates` and `claim_audio_transcription`
  (`gop::PACK_CANDIDATE_PREDICATE`, `AUDIO_CLAIMABLE_PREDICATE`) rather than
  hand-copies: both copies had already drifted — the archive count was missing the
  loginwindow exclusions and the transcript count ignored retry backoff, so
  "start now" pointed at piles that could not reach zero.
- **The count is cached for `BACKLOG_TTL` (30s), and taken in one `run_store`
  hop.** The panel polls every two seconds; these queries walk slot cards and
  `moments` against `text_evidence`, so uncached they would be the dashboard's own
  dominant cost — and a synchronous vault read from a tokio worker is what once
  froze socket accepts. Pressing "run now" drops the cache so the effect of the
  one action meant to move these numbers is visible on the next poll.
- **`compute_run_now { workload }`** starts a `FORCE_WINDOW` (30 min) override:
  `decide` skips the machine conditions for that workload, the summary sweeper is
  woken through `t2_changed` so the button acts within a second rather than on
  the next five-minute tick, and while forced the sweeper works through the whole
  backlog instead of two slots per tick. The override is scoped to the workload
  asked for — forcing summaries must not start an all-core encode nobody asked
  about — and ends early the moment the backlog is empty, so the machine goes
  back under its usual gates rather than staying overridden for half an hour.
- **Whether the button is offered is the daemon's call** (`ComputeGate.can_run_now`).
  It depends on which workloads have a machine gate or a throttle of their own —
  something only `decide` knows — so a client that re-derived it would drift the
  moment that changed. Transcription qualifies because its override reaches both
  the machine gates it shares with summaries and `asr_sweep_interval`: bypassing
  the gates alone would leave the battery throttle stretching the sweep to five
  minutes, and the button would redraw a row and nothing else.
- **What "run now" will and will not override.** It skips the *machine
  conditions*, and it lifts an active suspension, because pressing start is newer
  information from the same person and keeping the pause would leave a button
  that visibly did nothing. It refuses while `ComputeMode::Off` — a standing
  choice to respect, not to override behind the user's back — and it cannot
  revive a workload disabled by an environment variable at launch, since no
  amount of forcing will make a sweeper that never started do work.
- **The explanation is generated, not written.** `ComputeThresholds` travels on
  the wire, so the Info popover is built from the numbers the gate actually
  compares against, each paired with the live reading and marked met or unmet.
  Summaries list power, battery, idle, load and the recent machine-wide GPU
  average. Transcription lists the shared idle, load and GPU conditions; battery
  only changes its cadence. A disabled GPU probe omits that condition, while a
  stale enabled probe is shown as unreadable and unmet. Hardcoding those numbers
  in the UI would let the explanation drift from the behaviour, which is worse
  than no explanation.

## Why there is no per-task GPU percentage

macOS publishes no per-process GPU accounting, so no task row can carry an
honest GPU figure. `powermetrics` needs root; the only in-process route to a
per-process number would be the private `IOReport` framework, which the
project rejects outright — private-framework FFI in a workspace that denies
`unsafe_code` outside one crate, plus a notarization and OS-upgrade risk.

There is, however, a public IOKit path to a **machine-wide** reading — the
`AGXAccelerator` service's `PerformanceStatistics["Device Utilization %"]`,
the same key stats and mxmon use. The daemon samples it at 1 Hz
(`afterray_platform_macos::gpu_utilization`) and the governor averages
the last 15 seconds: above 50% machine-wide GPU, summaries and transcription
wait, because a
game or a local LLM elsewhere is exactly the load the CPU load average
misses. Fail-closed like the other probes, disable-able with
`AFTERRAY_GPU_PROBE=0`. The full trade-off:
[gpu-utilization-gate](../docs/decisions/active/architecture/2026-08-24-gpu-utilization-gate.md).

So the dashboard reports each task's **lane** (`ComputeLane::Gpu` / `Cpu`) and
uses the machine-wide 15-second average only to explain the automatic gate. It
reports these costs that genuinely are attributable to a pid:

- `afterray-platform-macos/src/process.rs` — `process_usage(pid)` via
  `proc_pid_rusage(RUSAGE_INFO_V0)`: CPU time and physical footprint.
  **`ri_user_time` is mach absolute time, not nanoseconds**, whatever the field
  name says — without the `mach_timebase_info` conversion every figure reads ~42×
  low on Apple Silicon (measured: a busy-spinning thread reported 2.4%). The test
  `measured_cpu_time_is_in_nanoseconds` pins it.
- CPU percentages are a **rate between two samples**, kept per pid in the
  governor. The first sample of a process reports memory only; inventing a rate
  from a process's lifetime average would show a long-resident model worker as
  permanently busy.
- Percentages are shares of one core and are **not clamped**: a four-thread
  encoder honestly reads 400%, which is the case the panel exists to explain.
- Resident models get their own section. A loaded MLX pack holds several GB of
  unified memory whether or not it is generating, and that explains more "my Mac
  got slow" than any percentage. The daemon checks the adapters every five
  seconds and ends a managed MLX worker after 120 seconds without a completed
  request. Ending the process releases model weights, Metal allocator state and
  any request cache; the next request cold-loads the selected pack.

## How the report is assembled

`compute_status` in `crates/afterrayd/src/main.rs` builds the whole
`ComputeStatusReport` against one instant, so no two rows can disagree about the
machine. It reads:

- `ModelQueue::activity()` — running jobs + per-capability pending counts.
  **Not `list()`**: that returns every job the daemon has ever run, model outputs
  included. `list()` also never pruned anything, so a day of ten-second captures
  left ~8600 finished jobs in memory; `prune_terminal` now caps finished jobs at
  200, outside a 60s grace window that `ModelQueue::wait` depends on.
- `ModelAdapter::worker_pid(job_id)` — the only route from a running job to a pid.
  `ProcessAdapter` registers its child and drops the registration on every exit
  path, cancellation and timeout included. Adapters with no child answer `None`,
  and the panel shows nothing rather than the daemon's own figure relabelled.
- `GopPacker::encode_busy()` — the in-daemon rav1e thread has no worker pid, so it
  is injected as a synthetic task. Without it the single most likely answer to
  "why is my Mac slow" would be invisible next to the model jobs.
- `capture_paused` — needed to break a circular reading: an open overlay resets
  the idle timer that summaries wait on, so the panel must be able to say "the
  overlay is why the machine counts as in use" instead of showing a refusal it
  caused itself.

## The wire and the UI

- Requests (protocol 13): `compute_status`, `compute_set_mode { mode }`,
  `compute_pause { seconds }` — a duration, not a deadline, because client and
  daemon do not share a clock and "an hour from when I pressed it" is what the
  user means. `0` resumes. Every mutating call answers with the fresh report, so
  the UI never shows a switch in a position the daemon does not hold.
- **Off by default, opt-in from Advanced settings.** The panel answers "why are my
  fans loud" for the people who ask; for everyone else it is worker pids and gate
  thresholds nobody requested. The governor does the right thing unsupervised, so
  the default costs a normal user nothing.
- **A window, not an overlay.** The dashboard opens as a standalone window, like
  History and Chat. Inside the recall overlay it could not be read beside the app
  that was making the machine slow, Esc was ambiguous between the two panels, and
  answering "what is my Mac doing" forced the whole recall surface open. The
  window controller owns the poll lifecycle, because an `orderOut`-ed window never
  fires the view's `onDisappear`.
- Two entry points, deliberately: the menu bar (`Local Computation…`) is where
  someone goes to free the machine, and the overlay's top-right cluster carries a
  copy — menu-bar space is scarce and that icon is often hidden behind the notch.
  Both share one `ComputeActivityModel`; three pollers would triple the sampling
  the panel exists to report on.
- The button carries state (`ComputeIndicator`) so the overlay answers "is
  AfterRay busy" without being opened. It accents only for *working*: a hold the
  user chose is not a problem to report back to them.
- Polling is 2s and only while watched (reference-counted). A dashboard that
  refreshed forever would itself be background work.

## Where to look

| Question | Answer |
|---|---|
| Why is nothing summarising? | `gates[].reason` in `afterray compute --json`, or the panel's Work types rows |
| What is running right now? | `ComputeStatusReport.running`; `ModelQueue::activity()` |
| Can I stop it? | mode preset (`full`/`essential`/`off`) or the one-hour suspension; both persist |
| Why no GPU % ? | see above — macOS does not publish it per process |
| Why does OCR keep running when I pause? | there is no OCR backlog; a skipped frame is never indexed |
| CLI | `afterray compute --json`, read-only by design |
