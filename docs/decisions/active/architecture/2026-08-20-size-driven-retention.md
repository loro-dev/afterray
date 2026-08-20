# Decision: The vault expires by size, never by age

Status: active
Area: store
Anchors:
- crates/afterray-store/src/lib.rs @dec:size-driven-retention
Supersedes: —
Superseded-by: —

The choice predates this file. It is recorded here on 2026-08-20 from
[crates/afterray-store/AGENTS.md](../../../../crates/afterray-store/AGENTS.md),
[context/event-capture-v2.md](../../../../context/event-capture-v2.md) §3b, and the code itself;
`context/CONTEXT-GAPS.md` records the 2026-08-18 session where the absence of a
time-based rule had to be rediscovered by reading `enforce_retention` end to end,
which is the cost this record exists to stop repeating.

## Problem

The vault holds several kinds of captured content — moments, the input events describing what the user did during them, and the R3 edge trees walked when the user changed scope — plus `signal_gap` markers, which are bookkeeping about the recorder rather than a record of the user. Each of those could plausibly carry its own expiry rule, and for a while the input events did: a 48-hour channel that took the whole table.

Per-stream expiry makes one user-facing question unanswerable. "Is what I did last Tuesday still there?" has no single answer when the screenshot, the acts derived from it, and the surrounding tree each die on a different schedule, and the answer changes depending on which one you ask about.

## Decision

There is exactly one expiry scale: **bytes**. `enforce_retention` evicts oldest-first until the vault is under `storage_limit_bytes`, and returns immediately when it already is — which is the normal state, so under the limit **nothing expires, ever**. There is no time-based retention.

Input events and `edge_snapshots` are swept against the **retention horizon**: the oldest frame the vault still holds. Content whose surrounding frames are gone has nothing left to attach to, so it goes with them. What the user did during a stretch survives exactly as long as what was on screen during it. This is not a second clock — under the size limit it never fires, exactly like the frames.

A vault with no frames has no horizon, and is **not** swept.

Two streams are exceptions, and both are narrow:

- `SIGNAL_MARKER_RETENTION_MS` (48h, `prune_signal_gaps`): a marker's entire meaning is a deadline, and it is worth nothing once every card covering its stretch is built. It runs before the size sweep and outside its early return, and its failure must not stop the size sweep.
- Raw `input_events` (48h) — [raw input events expire](../product/2026-08-20-raw-input-events-expire.md). Those rows carry typed text and field values, which is a different kind of content from a screenshot and does not belong under a size-only rule. The shape of the activity is frozen into `slot_summaries.acts_json` before the rows go, so the vault keeps how much was typed and loses what.

Everything else — frames, GOP segments, artifacts, R3 edge trees — expires by size alone. A third clock added to this crate contradicts this decision; supersede both records rather than adding another deadline quietly.

## Alternatives considered

**Keep the input events' own 48-hour channel.** It was the shipped behavior and was retired in the same work that unified retention. The rule made sense while the events were the shortest-lived thing in the vault; once they were not, the R3 trees that had been made to follow them would have become the *longest*-lived content in the vault. The reason the channel existed had inverted.

**Treat a frameless vault as "everything is expired".** Rejected: "everything is older than nothing" would take live events off a vault that had merely never captured a frame — a new install, or one whose frames were all deleted by hand. The unknown edge is skipped rather than guessed. The price is accepted below.

**A general age-based rule ("keep 30 days").** Not recorded as having been considered. The sources above establish only that no such rule exists, not that one was weighed and declined; this paragraph exists so the next reader does not mistake silence for a verdict.

## Consequences

**Bought:** one answer to "is it still there", derivable from a single number the user controls. A retention question is a disk question, and the recall UI can state the horizon as a fact rather than a policy.

**Cost:** there is no way to say "keep only the last 30 days" — a real request for a screen recorder, and it cannot be granted without superseding this. Under the limit the vault only grows. Edge-tree artifacts on a frameless vault are not reclaimable by retention at all; `delete_history` still reaches them.

**Narrowed once, deliberately.** Keeping typed text under a size-only rule meant a verbatim keystroke log living for months; [raw input events expire](../product/2026-08-20-raw-input-events-expire.md) took that one stream out. The general argument above is unchanged and still governs everything else — which is why that record narrows this one rather than superseding it.

**Load-bearing for privacy:** deletion is the user's tool here, not expiry. `delete_history` must reach every layer — cards, acts, and R3 trees, not just frames — because nothing else will ever remove them. See [crates/afterray-store/AGENTS.md](../../../../crates/afterray-store/AGENTS.md).

## Related

[context/event-capture-v2.md](../../../../context/event-capture-v2.md) §3b describes what the sweep does today; this record covers why it is shaped that way.
