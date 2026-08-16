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

## Answered in a second review

Four more, all confirmed in code before being changed.

**The opening trim deleted the user's question.** The fix for "the first round
can exceed the window" was `truncate_head` over the whole opening — which is
built seed, history, task. Keeping the head kept the clock and a stale
conversation and dropped the question at the end of it; the model then answered
something nobody asked. The default allowance is 1 906 tokens and a folded
Chinese history alone can be eight thousand, so it took very little. The opening
is now `Opening { seed, history, task }` with a budget per part: the task is
never dropped, the seed keeps its anchors, history gives up its oldest turns
first, and a question too long for one turn is cut and *named* as such. A
`CURRENT_TASK_SENTINEL` test fails without it. Fencing also moved inside
`Opening::render`, after trimming — trimming a pre-fenced block can cut off its
marker and leave the question looking like data.

**Corrections were delivered as untrusted data.** The malformed-call notice and
the final-round warning were pushed as tool results, which `Transcript::render`
wraps in `<<<AFTERRAY_DATA kind=tool_result>>>` — and the system prompt tells
the model to ignore instructions inside that fence. `Transcript` now has a
`Control` entry rendered outside it.

**The reserved last round was advisory.** A model that ignored the warning still
had its tool executed, and the turn then failed anyway. The loop now refuses to
run a tool on the final round, verified by counting invocations.

**Streaming was still a race.** The outlet was armed after `submit_with`
returned, so an idle lane could start the adapter first and the round would
silently not stream. `ModelQueue::submit_prepared` runs a hook with the job id
while the job is still pending, and the outlet is armed there.

Plus a parser boundary bug: `FINAL` and `TOOL` were matched as prefixes, so
"Finally, …" was delivered as "ly, …".

## The context window, and where its number comes from

Three numbers claim to be "the context window" and they are routinely different:
what the architecture allows (Qwen3.5 says 262 144 at both sizes), what the
machine can afford, and what the loaded instance actually got. Ollama picks the
second from installed RAM, and a prompt longer than the result is cut *before
the model reads it* — no error, no event, just an answer to a question with its
front missing. Budgeting carefully against the wrong number buys nothing.

**The tiers are Ollama's, deliberately.** `context_tokens_for_memory` in
`afterray-platform-macos` copies the boundaries Ollama itself uses: under 24 GiB
4 096, under 48 GiB 32 768, above that 262 144. A curve of our own would mean
asking for a window the server then declines to give. The probe (`sysctl
hw.memsize`) is kept apart from the arithmetic so the arithmetic is testable,
and a machine that will not answer falls to the *smallest* tier — under-claiming
costs room, over-claiming costs the front of the question.

**Then the provider is asked.** `probe_context_tokens` reads `/api/show` for the
architectural ceiling (the key is architecture-prefixed, so it matches on the
`.context_length` suffix rather than guessing `qwen35.`) and `/api/ps` for what a
resident instance actually got. The smallest real constraint wins. It runs per
turn, not at startup: `/api/ps` only tells the truth once the model is loaded,
which is exactly when it matters.

**`OLLAMA_CONTEXT_LENGTH` / `OLLAMA_NUM_CTX` win over the tier.** Someone who set
one has already made this decision, and quietly exceeding it allocates memory
they declined to give. A pin is still bounded by what actually loaded — a pin
above the server's allocation is a wish, not a window. The caveat is that we only
see the variable when the daemon shares the server's environment; when we do not,
`/api/ps` reports the pinned value anyway, so it is honoured either way, just one
round later.

**The number is declared, not assumed.** `/api/chat` now carries
`options.num_ctx`, and it is the same figure the harness budgeted against —
budget for more than we declare and the prompt gets cut, declare more than we
budget for and a KV cache nobody uses sits in the same memory as everything
else. `LlmRuntimeConfig.context_tokens` exists so those two cannot drift apart.
For an OpenAI-compatible endpoint there is nothing to probe and this machine's
memory says nothing about someone else's server, so it assumes 32 768; those
endpoints reject an over-long prompt with an error rather than truncating it
silently, which is what makes a guess acceptable there and not here.

**The budget derives from the window rather than being tuned per tier.**
`ContextBudget::for_window` scales the three parts by what they are: the reserve
is an answer, so it is an eighth of the window clamped to [512, 4 096]; the
system share is a measurement of the prompt and catalog, so it does not scale at
all; and rounds fall from six to four on a narrow window, because six rounds of
a 4 096 window cuts each tool result to a few hundred tokens — fewer, larger
results beat more, emptier ones. `for_window(16_384)` reproduces the old
`DEFAULT` exactly, asserted at compile time.

Two things fell out of testing it. A tool result whose payload sits on one JSON
line — every `get_ocr` reply — used to lose the entire payload, because
`truncate_head` stops at the last line that fits whole and the envelope was all
that fit. It now cuts into that line when enough room remains, which took the
useful share of a 4 096-token window's tool budget from about a fifth to nearly
all of it. And `PROTOCOL_VERSION` went to 8: `ChatAbort` was added while the
version still read 7, so an app that knows stop and a daemon that does not both
claimed 7, the handshake passed, and the user's stop did nothing.

## The conversation is a list of messages

Every turn used to be one `system` message and one `user` message. The whole
conversation was folded into that user message as text — first round kept,
middle dropped, recent six kept — so the same past rendered differently every
turn. Four things followed from that, and all four are now gone.

**The prefix moved every turn.** Turn 8 dropped round 2; turn 9 dropped rounds
2 and 3. Every provider caches on the longest identical prefix and every local
runtime re-prefills from the first byte that changed, so a conversation that
re-slices itself matches nothing and pays full price for text it has already
read. History is now `Vec<Message>`, appended and never rewritten; the invariant
is asserted directly (`is_prefix_of`) in the harness, in the daemon's renderer,
and end to end through the real chat path.

**The clock was in front of it.** `build_seed` opens with `now_ms`, and the
opening was built seed-first, so byte one of every prompt differed. Volatile
content now rides at the end with the question. The guarantee is exact:
everything except the final user message is append-only — that last message is
supposed to change, which is why it is last. Once answered and stored, the
question re-enters the array as its own message and never moves again.

**Tool calls were invisible across turns.** `tool_log` was written to the vault
and never read back, so a follow-up could not see what the previous turn had
looked up and simply looked it up again. A past turn now replays as the
assistant's `TOOL`/`ARGS` message and the result itself, inside the same fence
the live round used.

What is stored is **the bytes that were sent** — `Budgeted.text`, already cut to
that turn's cap — and replay puts them back verbatim with no budget logic on the
path. Storing the raw result and re-cutting it per turn would look equivalent
and is not: `tool_result_tokens` differs with the machine's memory and with the
user's settings, so the same past would render differently on a different Mac,
the cut would land elsewhere, and every message after it would be a different
message. Nothing would report that. A test renders one stored turn under a 32k
and a 256k budget and asserts the arrays are byte-identical, and under a 4 096
budget — too small to hold the thread — asserts that what survives is still
byte-identical, because messages are dropped whole and never re-cut.

The results ride in the existing `tool_log` column rather than a new one. No
migration, and `conversation_bytes` already sums that column, so the chat pool
accounts for them the day they start being written; a new column would have
needed adding to that sum, and forgetting it is exactly how a budget stops being
one. Rows written before this replay as the call plus a note that its result was
not kept.

**Two kinds of "out of room" behaved differently.** In-turn pressure announced
itself, wrote a row and showed in the UI; cross-turn pressure silently deleted
the middle of the conversation. `CompactionStrategy` now has a second method for
the conversation, `PruneToolResults` implements both, and the cross-turn pass
emits the same `CompactionNotice` — so it writes the same row, renders the same
separator, and leaves an `[AfterRay]` marker where the dropped messages were.
The order of loss is the same too: tool results fold first, whole messages go
only if that was not enough. A result can be fetched again; a question cannot,
and an answer vanishing from the thread's context is how a follow-up stops
making sense. `Message::kind` exists so that rule is applied to a boundary
rather than to whatever text happens to look like a fence marker.
After a fold the prefix settles again and stays settled, which is the most a
non-model policy can offer; `SummarizeOldest` remains phase 5.

Tool calls stay in the text protocol rather than moving to provider-native
function calling. Native calling would make the *stored* conversation
provider-shaped: Ollama drops `thinking` from context, DeepSeek requires
`reasoning_content` echoed back, and the tool-call message differs between them.
Under the text protocol the array is one canonical thing, switching providers
mid-conversation changes nothing about what the model sees of its own past, and
the existing fence is already the right wrapper for a replayed result.

## What holds the prefix, and what merely tested it

Until this, "history is append-only" was a property the tests checked and the
types permitted violating. `Message` had a `pub content: String`, history
travelled as `&mut Vec<Message>`, and any code anywhere could rewrite a message
the model had already been shown — with no error and no event, just a prompt
that quietly stops matching anything cached.

Worse, one place already did. `Opening::render_messages` had its own
history-shrinking loop, and it used `continue` rather than `break`: a message
too large for the remaining budget was **skipped**, and smaller older ones after
it were kept. Rendered `[A, B(huge), C]` came back as `[A, C]` — a question with
its answer removed from the middle, no marker where it went, and the surviving
subset changing turn to turn as the seed and the question changed size. It was
never a prefix relationship at all. No test caught it because the fixtures used
uniform small messages that all fit.

So the vector is now private, inside [`History`], and the vocabulary is exactly
the legal moves: `push` at the end, `fold_result` to replace one result body
with the standard marker, `drop_oldest`, and `mark` to leave a line where
messages went. `Message::content` is private with no setter. There is no
`messages_mut`, no `IndexMut`. A compaction policy — including one written later
by someone else — can fold and drop, and cannot forge; two `compile_fail`
doctests keep it that way.

The renderer no longer removes anything at all. Fitting the conversation into
the window is compaction's job and only compaction's, which is what makes the
sentence true rather than aspirational. The consequence is stated rather than
hidden: with `LoopConfig::compaction = None` nothing bounds the conversation,
and a caller choosing that is asserting its history fits. An over-long prompt
the server then cuts is bad; a renderer silently keeping a different subset
every turn and never saying which is worse.

Two smaller holes closed with it. A tool log that fails to parse used to yield
an empty list, deleting a turn's tool messages from the middle of the array with
nothing to explain the shift; it now leaves a visible line saying the record
could not be read. And compaction identified an already-folded result by
comparing content to a constant — now `Message::kind` carries it, so the rule
applies to a boundary rather than to text a user could paste.

One obligation the types still cannot enforce, so it is written on
`History::from_stored`: the caller must render the same messages for the same
stored rows. `history_messages` is deterministic — `ORDER BY created_at_ms, id`,
a pure fence function, and stored bytes replayed verbatim — but nothing in the
signature says so.

## Not started

Phase 4 (steering) and phase 5 (`SummarizeOldest`), plus the plan's note about
scoped models for T2 versus chat.

Four more, named in review and genuinely outstanding:

- **`AgentSession` still does not exist.** Turn admission is now enforced, but
  by a map in `AppState` rather than by a type that owns the session, its tool
  registry, its policy hooks and its event log. `afterray-agent` remains a
  queue binding plus error classification; the name is ahead of the contents.
- **Tools hold `&ModelQueue`** where an embedding port would do.

Phase 5 also needs the seam widened first: `CompactionStrategy::compact` is
synchronous, which no model-backed strategy can satisfy. Making it async while
`LoopConfig::compaction` stays a `&dyn` means boxed futures on every round for a
strategy that does not exist yet, so it was left for whoever writes the real
caller.
