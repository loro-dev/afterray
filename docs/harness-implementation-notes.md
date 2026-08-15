# Agent harness: what was built, and where it left the plan

Companion to [harness-plan.md](harness-plan.md), which is the design. This
records what phases 0–3 actually landed as, and every place the code and the
plan disagree — so the disagreements are decisions on record rather than
things nobody noticed.

## Built

| plan | landed as |
|---|---|
| 0.1 whole-record truncation | `harness::truncate::truncate_head` → `Budgeted { text, truncated, dropped_lines, dropped_tokens, partial_line }`, marker at every seam |
| 0.2 reconciled budgets | `harness::budget::ContextBudget`, with `is_coherent()` asserted at compile time |
| 0.3 token estimate | `harness::tokens::estimate_tokens`, CJK ≈1 token/char, Latin ≈4 chars/token |
| 0.4 catalogue test | `tools::catalog_drift`, four rules read out of the dispatch source |
| 1 two crates | `afterray-harness` (no AfterRay deps), `afterray-agent` |
| 2 `PruneToolResults`, visible + non-destructive | `harness::compaction`, plus a `compaction` message row |
| 3 real abort | `harness::cancel::CancelToken` at three points, plus socket hang-up detection |

## Where the code left the plan

### 1. Tools are still match arms, not values

The plan wants a `Tool` trait and a `ToolRegistry` whose `catalogue()` derives
the prompt text, so drift becomes impossible. That is not built. What landed is
the plan's own interim measure — "until then, add a test" — and dispatch is
still a `match` in `tools.rs`.

The registry remains the right target. It also removes the slightly unusual
thing these tests do, which is read their own source file.

### 2. There is no `AgentSession`

The plan's headline is that AfterRay lacks the orchestration layer, and sketches
`AgentSession` with `prompt` / `steer` / `follow_up` / `abort` / `context_usage`.
The crate exists and holds the model-queue binding; the type does not. Handlers
still assemble the loop themselves, and cancellation is threaded as a token
rather than owned by a session.

This is the largest remaining gap, and phase 4 depends on it.

### 3. Budgets are uniform, not per-tool

Plan 0.2 argues that `MAX_TOOL_CHARS × MAX_ROUNDS ≤ MAX_HISTORY_CHARS` at five
rounds gives 2 800 characters per tool result, too tight for `get_slot_card`,
and that the honest fix is per-tool budgets.

The constraint is enforced, but the tightness was solved by raising the ceiling
rather than by splitting it: a 16 384-token window with 6 rounds gives 2 048
tokens per result — roughly 8 000 Latin characters, more than the old 6 000-char
cap gave any tool. Per-tool budgets are still the better answer for a narrow
window, and `ToolHost` already carries a `ContextBudget` to hang them off.

### 4. Compaction ranges are rounds, not message times

The plan's event carries `covered_from_ms` / `covered_to_ms`, which implies
compacting stored conversation history. What is implemented compacts the
**in-turn transcript** — the tool results of the turn being run — so its range is
`from_round` / `to_round`.

Both are worth having and they are not the same feature. Compacting history is
what makes a long conversation survive; compacting a turn is what makes one
question with many lookups survive. Only the second is built.

### 5. Event field names

The plan sketches `{"type":"usage","tokens":…,"context_window":…,"percent":…}`.
Shipped: `{"kind":"usage","prompt_tokens":…,"window_tokens":…,"round":…}`.

`kind` rather than `type` because that is what the wire and
`ChatStreamEventDecoder` already use. `percent` is left to the client, which has
to clamp it for a meter anyway. `round` was added because usage is emitted per
round and a client otherwise cannot tell a stale line from a current one.

### 6. `contextUsage` is not restored from history

The plan says it should be "restored from the last assistant message's stored
usage when history loads". It is not, because the daemon does not store usage
anywhere — so restoring it would mean inventing a number, and a meter is exactly
the kind of UI that gets believed. It resets to `nil` on conversation switch and
stays empty until the next turn reports.

Persisting usage on the assistant row would make the plan's version work, and is
the better end state. Compaction notices *are* restored, from the `compaction`
rows themselves.

### 7. The usage indicator is always shown once known

The plan says to show it only above ~50% "so it is not permanent chrome". It is
shown whenever a round has reported, turning coral past 75%. A meter that
appears only when things are going badly is also a meter whose absence carries
no information — but this is a taste call and easily changed.

### 8. Cancellation took neither route the plan lists

The plan offers "cheap: poll whether the write half is open between rounds" and
"correct: a `ChatAbort` request on a second connection".

What landed watches the **read** half for EOF concurrently with the turn, which
needs no protocol change and catches a stop during a long tool call — the case
the cheap option misses — while also cancelling the in-flight queue job, which
neither option mentions and which matters most on a single-lane local runtime,
where an abandoned job holds the lane against the next question.

`ChatAbort` is still worth having for explicitness, and phase 4 needs a second
channel anyway.

### 9. pi's compaction thresholds do not transfer

The plan suggests copying `reserveTokens: 16_384`. Our window is 16 384, so that
reserve is the entire window. Used 2 048 reserve plus 1 024 for the system
prompt, which is coherent for this window size; pi's numbers assume a much
larger one.

### 10. One correction to the plan

Plan 0.4 says the catalogue test "would have caught defect 4". It would not.
Defect 4 was chat's prompt naming `get_slot_card` and never learning about
`get_day_summary` — every tool it named existed, so a dispatch-vs-catalogue
check passes. No test can require a prompt to *mention* a tool.

The rule implemented instead runs the other way: **a system prompt may not name
tools at all.** Ordering advice lives in the catalogue, beside the tools it
orders, where adding one puts the advice in front of whoever adds it. Restoring
the exact line that shipped now fails the build.

## Not started

Phase 4 (steering) and phase 5 (`SummarizeOldest`), plus the plan's note about
scoped models for T2 versus chat.

Phase 5 also needs the seam widened first: `CompactionStrategy::compact` is
synchronous, which no model-backed strategy can satisfy. Making it async while
`LoopConfig::compaction` stays a `&dyn` means boxed futures on every round for a
strategy that does not exist yet, so it was left for whoever writes the real
caller.
