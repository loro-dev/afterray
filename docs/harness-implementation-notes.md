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

### 6. `contextUsage` — resolved as the plan wanted

Initially not restored, because nothing stored usage and a restored meter would
have been an invented number. Now the assistant row carries `usage_json`, so
`loadHistory` reads it back exactly as the plan described. Switching still
clears first, and the restore only overwrites when a row actually carries one —
so a thread whose rows predate the column shows nothing rather than the previous
thread's pressure.

### 7. The usage indicator is always shown once known

The plan says to show it only above ~50% "so it is not permanent chrome". It is
shown whenever a round has reported, turning coral past 75%. A meter that
appears only when things are going badly is also a meter whose absence carries
no information — but this is a taste call and easily changed.

### 8. Cancellation ended up at the plan's "correct" option

First landed as read-half EOF detection, which needed no protocol change. That
turned out to be the wrong seam rather than merely a cheap one: it gave the
daemon a single signal for two opposite intents. `ChatAbort` on a second
connection is now the stop, and EOF means "I will read it later" — see
[Interruption](#interruption-what-is-guaranteed-and-what-is-not).

The one thing neither option mentioned is still there: the abort kills the
in-flight queue job, which matters most on a single-lane local runtime where an
abandoned job holds the lane against the next question.

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

## Interruption: what is guaranteed, and what is not

A turn's assistant row is created before the model is asked anything and
rewritten as output arrives (throttled to ~500 ms). Two intents are now
distinguished, because they are opposite:

| | how | turn | row |
|---|---|---|---|
| **Stop** | `ChatAbort { conversation_id }` on a second connection | cancelled: the queue job is killed and the LLM lane freed | keeps what it produced, `status = aborted` |
| **Walk away** (close the panel, quit, crash) | socket EOF | **runs to completion** | full answer, `status = complete` |

The socket used to carry both, and the daemon could not tell them apart. It now
reads a hang-up as "I will read it later" and only an explicit abort ends a
turn. A daemon that dies mid-turn leaves rows marked `streaming`; the next
start settles them to `aborted`, so nothing shows a live spinner forever.

**What this does not do: resume.** Coming back does not reattach to a running
turn's token stream. If the turn finished while the panel was closed, reopening
the thread shows the finished answer, which covers the ordinary case. If it is
still running, the thread shows the row as it stood at the last flush and does
not update until the next reload. Real resume — a server-side event buffer and
a client reconnecting with a cursor — is a different order of work and is not
started.

## Reasoning, and why it is stored

Kept in a `reasoning` column as a JSON array of `{round, text}`, capped at
~2 048 tokens per turn with the cut marked. Rounds are kept apart rather than
concatenated, and there is a `signature` slot, because of what the providers
turn out to require:

- **Ollama** accepts `thinking` on an inbound assistant message but drops it
  from the model's context. Verified: a passphrase placed in `thinking` is
  invisible to the next turn, while the same passphrase in `content` comes back
  verbatim. No signature, nothing to round-trip.
- **OpenAI-compatible** is the opposite. `DeepSeek` V4 requires
  `reasoning_content` echoed back verbatim in the assistant message and returns
  400 on the second turn without it — which broke a long list of tools in
  April–May 2026.

Neither bites us **today**, because AfterRay never sends an assistant message
at all: `chat_messages` builds `[system, user]` and history is folded into the
user prompt as flat text. So storage is currently for the reader, not for
correctness. It stops being optional the moment anyone moves the chat path to a
structured `messages` array, and the shape above is what makes that possible
rather than a rewrite.

Full content blocks — pi's `AssistantMessage.content` array of
`TextContent | ThinkingContent | ToolCall` — were considered and not taken. That
array exists to preserve *interleaving order* for verbatim round-tripping; our
tool calls already live in their own column and our answer is one final text, so
there is no interleaving to preserve. If we ever round-trip, that judgement
needs revisiting.

## Answered in review

A read of this branch against pi and DeepSeek Harness found four things worth
recording, three of them fixed here.

**Concurrent turns could cross-wire tokens.** The chat token outlet was one
global `Option<Sender>`, armed *before* the job was submitted and taken by
whichever job the single LLM lane admitted next. Turn A queued while turn B
armed the outlet would take B's sender, so B's window rendered A's answer — and
A's guard cleared the slot on the way out regardless of whose sender was in it.
The outlet is now a map keyed by job id, armed after submit, and a guard removes
only its own entry. Separately, a conversation now admits one turn at a time:
the second is refused rather than interleaved, and a finishing turn releases its
claim only if it still holds it. The app's `isSending` flag was never this
check — it is per-window, and a relaunch walks past it.

**The tool parser turned valid calls into blank successes.** `ARGS` spread over
several lines — what most models emit for more than one field — parsed as the
single character `{`, failed, and was then classified as prose; the answer gate
hid it for starting with `TOOL`, so the turn reported success and stored an
empty assistant row. Brace counting also did not understand JSON strings, so a
`}` inside a query ended the object early. Both are fixed, and a malformed call
is now its own outcome: the model is handed its own error and given a round to
correct it, and a turn that never produces a usable call fails loudly.

**The round cap printed raw tool output as the answer.** It handed back the last
tool result verbatim, which skips synthesis and citation and lifts text out of
the data fence it arrived in. The last round is now reserved: the model is told
no tool calls remain and asked to answer from what it has.

**`is_coherent` could not fail.** It compared `transcript/(rounds+1)*rounds`
against `transcript`, true for every positive input. It now checks properties
that can be violated, and the opening block — task, clock, folded history — has
a budget of its own and is trimmed before the first round rather than reaching
the model unchecked.

## Not started

Phase 4 (steering) and phase 5 (`SummarizeOldest`), plus the plan's note about
scoped models for T2 versus chat.

Four more, named in review and genuinely outstanding:

- **`AgentSession` still does not exist.** Turn admission is now enforced, but
  by a map in `AppState` rather than by a type that owns the session, its tool
  registry, its policy hooks and its event log. `afterray-agent` remains a
  queue binding plus error classification; the name is ahead of the contents.
- **The context window is a constant, not the model's.** `ContextBudget::DEFAULT`
  assumes 16 384 tokens whatever is configured. It should come from the provider
  settings, which means carrying a window through `LlmRuntimeConfig`.
- **Long-term history is still trimmed by character count.** `fold_history`
  keeps the first message and drops from the middle until it fits, with no
  summary, no tombstone and no recoverable log. Compaction covers the in-turn
  transcript only. Until that changes, the `compaction` event and the context
  meter describe a narrower guarantee than a reader might assume.
- **Tools hold `&ModelQueue`** where an embedding port would do.

Phase 5 also needs the seam widened first: `CompactionStrategy::compact` is
synchronous, which no model-backed strategy can satisfy. Making it async while
`LoopConfig::compaction` stays a `&dyn` means boxed futures on every round for a
strategy that does not exist yet, so it was left for whoever writes the real
caller.
