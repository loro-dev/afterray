# Agent harness: what to fix, what to extract, and how it reaches the UI

> **Status (updated 2026-08-20): historical plan. The code is the authority.**
> Current behavior: the shipped tool surface, its grouping and the reply
> protocol are in [context/agent-tools.md](../context/agent-tools.md); the loop
> itself lives in `crates/afterray-harness` ([crates/AGENTS.md](../crates/AGENTS.md)).
>
> **This document sits in the middle of a chain, and each link partly supersedes
> the one before it.** [agent-chat-plan.md](agent-chat-plan.md) (2026-08-14)
> built the chat surface — three tools, a folded history, a CLI entry point.
> This document is the fix-and-restructure pass over what that produced, and it
> overturns the folding scheme and the tool list it inherited.
> [harness-implementation-notes.md](harness-implementation-notes.md) then records
> what the restructuring actually became, and is the later word wherever it and
> this document disagree — including on this document's own reasoning (see its
> §10, which corrects fix 0.4 below). Nothing below has authority over the code.
>
> The opening comparison of pi and deepseek-harness is kept verbatim: it is the
> only recorded measurement of the external systems this design borrowed from,
> and the "Deliberately not copying" list at the foot is the only record of what
> it declined.
>
> Superseded by the code — the body below still states the original intent:
>
> - **Phase 1's named seams never shipped under those names.** `LlmBackend` →
>   `ModelSurface`, `crates/afterray-harness/src/run.rs:121`. `ContextPolicy` →
>   `CompactionStrategy`, with a synchronous `compact` and a second
>   `compact_history`, `crates/afterray-harness/src/compaction.rs:42`.
> - **`Tool` + `ToolRegistry` were not built.** Dispatch is still a `match`, held
>   to the catalogue by tests that read their own source,
>   `crates/afterrayd/src/tools.rs:122`.
> - **`AgentSession` does not exist.** `afterray-agent` is a queue binding plus
>   error classification; handlers still assemble the loop,
>   `crates/afterray-agent/src/lib.rs:28`.
> - **`tools::vault` never moved into `afterray-agent`.** Tools stayed in the
>   daemon, where the vault is; `ToolHost` carries `store` / `now_ms` / `budget`
>   and nothing else, `crates/afterrayd/src/tools.rs:66`.
> - **"The eleven tools" → eight.** The surface grew to fourteen and was then cut
>   back; `list_moments` and five others were removed or folded into
>   `get_moment_context`, `crates/afterrayd/src/tools.rs:122` and
>   [context/agent-tools.md](../context/agent-tools.md).
> - **Fix 0.4's claim is wrong and the rule shipped inverted.** A catalogue test
>   would *not* have caught defect 4; what ships forbids a system prompt from
>   naming any tool at all, `crates/afterrayd/src/tools.rs:1694`.
> - **`emit_gate_tokens` / `stream.rs:329` no longer exists anywhere.** Stop is
>   the plan's "correct" option: an explicit `ChatAbort` on a second connection,
>   `crates/afterray-protocol/src/lib.rs:233`.
> - **The event vocabulary is larger and differently spelled.** `kind` not
>   `type`, and `started` / `reasoning` / `progress` were added alongside `usage`
>   and `compaction`, `crates/afterray-protocol/src/lib.rs:1331`.
> - **Compaction covers rounds, not message times — and history too.** The
>   cross-turn pass the plan only sketched runs before the first round,
>   `crates/afterray-harness/src/run.rs:419`.
> - **The usage indicator is not gated at ~50%.** It is shown whenever a round
>   has reported, `swift/AfterRayRecall/Sources/AfterRayChatView.swift:525`.
> - **Phases 4 (steering) and 5 (`SummarizeOldest`) never started.** Phase 5 is
>   blocked on the seam: `CompactionStrategy::compact` is synchronous, which no
>   model-backed strategy can satisfy,
>   `crates/afterray-harness/src/compaction.rs:49`.

Written after reading pi (`packages/agent` 1,851-line kernel, `coding-agent`
76,891-line full body) and deepseek-harness (`core/agent-loop` 1,650 lines,
`compaction` split into a 172-line contract plus two implementations).

The through-line of both: **the kernel drives one loop and knows nothing else.**
pi's kernel contains no reference to files, bash, or git — those live in
`coding-agent/core/tools/` behind an `AgentTool` interface. deepseek's declares
`static inject = ['agents','sessions','llm','tools','systemPrompt']` and lets a
container supply them.

What AfterRay lacks is not only that kernel. It is the layer pi calls
`AgentSession` (3,344 lines) — queueing, interruption, usage accounting,
runtime reconfiguration — which sits between the loop and the request handler.
We have a `handle_send` function where that layer should be.

## Where we actually stand

| | ours | pi | deepseek |
|---|---|---|---|
| loop | `agent.rs` 384 lines | 1,851 | 1,650 |
| plugin seams | 0 | 9 optional closures on `AgentLoopConfig` | 5 injected services |
| orchestration layer | none | `AgentSession` 3,344 | `session` package |
| context governance | 3 hard truncations | truncate + accumulator + compaction | contract + 2 strategies |
| token accounting | none (characters) | yes | yes |
| interruption | socket close between tokens | 5 distinct abort entry points | yes |

### The defects these produce, concretely

1. **`clip_transcript` cuts mid-character-run.** `agent.rs:175` keeps a head
   third and a tail two-thirds of the *character* stream. A tool result that
   straddles the cut is delivered as half a JSON object, and the seams carry no
   marker — only the middle does. pi's `truncate.ts` documents the opposite
   invariant in its header comment: "Never returns partial lines."

2. **Budgets contradict each other.** `MAX_ROUNDS = 5`, `MAX_HISTORY_CHARS =
   14_000`, `MAX_TOOL_CHARS = 6_000`. Two tool calls exhaust the transcript
   budget, so rounds three through five are guaranteed to run against a clipped
   transcript. We permit five rounds and can hold two.

3. **Characters are not tokens.** Every budget is in characters. For Chinese
   the ratio is off by 2–3×, so the numbers are guesses in the language this
   product is mostly used in.

4. **`CHAT_SYSTEM_PROMPT` still names the old path.** It says "Start wide with
   `get_slot_card`" and does not mention `get_day_summary`. The tool catalogue
   and the system prompt are two hand-written strings with nothing keeping them
   in step — the same structural gap that let this drift in.

5. **Stop does not stop.** `AfterRayChatModel.stop()` cancels the read task,
   which closes the socket. The daemon only notices at its next
   `write_event`, inside `emit_gate_tokens`. During a long tool call, or before
   the first token, nothing is cancelled and the model keeps running.
   **[Overtaken — `emit_gate_tokens` no longer exists; stop is an explicit
   `ChatAbort` and a hang-up now means "I will read it later" →
   `crates/afterray-protocol/src/lib.rs:233`]**

6. **Context usage is invisible.** Nothing on either side computes or reports
   how full the window is, so a user cannot tell why answers degrade.

---

## Phase 0 — fix the defects (no architecture change)

Small, independent, each one currently costing output quality.

**0.1 Truncation keeps records whole.** Replace `clip_transcript` with a
line-boundary version, and give it the shape pi's returns:

```rust
struct Clipped { text: String, dropped_lines: usize, dropped_by: ClipReason }
```

The transcript is already written as `TOOL …` / `RESULT …` blocks by
`writeln_tool`; clip at block boundaries, and replace what was removed with an
explicit `…(N earlier tool results omitted)…` at the seam rather than only in
the middle.

**0.2 Reconcile the budgets.** Pick one rule and derive the rest:
`MAX_TOOL_CHARS × MAX_ROUNDS ≤ MAX_HISTORY_CHARS`. With five rounds that is
2,800 per tool result, which is too tight for `get_slot_card`. The honest fix
is per-tool budgets — a slot card gets more than a moment list — with the
transcript budget as the ceiling.

**0.3 Count tokens.** Add `afterray-harness::tokens::estimate(text) -> usize`.
An exact tokenizer per model is not worth it; pi falls back to an estimate when
the provider has not reported usage yet. Estimate CJK at ~1 token/char and
Latin at ~4 chars/token, and prefer the provider's reported usage when a
response carries one.

**0.4 Regenerate the catalogue from the registry.** Once tools are values
rather than match arms (Phase 1), `tool_catalog_text()` derives from them and
cannot drift. Until then, add a test that fails when a name in the `invoke`
match is missing from the catalogue string. That test would have caught defect 4.
**[Overtaken — it would not have. The rule shipped the other way round: a system
prompt may not name a tool at all → `crates/afterrayd/src/tools.rs:1694`]**

## Phase 1 — extract two crates

### `afterray-harness` (~500 lines, zero AfterRay dependencies)

**[Overtaken — the crate exists and has no AfterRay dependencies, but none of
the four traits below shipped under these names. `LlmBackend` → `ModelSurface`
(`crates/afterray-harness/src/run.rs:121`); `ContextPolicy` →
`CompactionStrategy`, whose `compact` is synchronous
(`crates/afterray-harness/src/compaction.rs:42`); `Tool` / `ToolRegistry` were
never built, so dispatch is still a `match`
(`crates/afterrayd/src/tools.rs:122`).]**

```rust
pub trait LlmBackend {
    async fn generate(&self, req: Request) -> Result<Completion, HarnessError>;
}

pub trait Tool {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn schema(&self) -> &serde_json::Value;
    async fn call(&self, args: &Value) -> Result<String, String>;
}

pub struct ToolRegistry { /* name -> Box<dyn Tool> */ }
impl ToolRegistry { pub fn catalogue(&self) -> String; }

pub trait ContextPolicy {
    fn should_compact(&self, usage: &Usage) -> bool;
    async fn compact(&self, t: Transcript) -> Result<Transcript, HarnessError>;
}

pub struct LoopConfig {
    pub max_rounds: usize,
    pub before_tool: Option<Box<dyn Fn(&ToolCall) -> ToolDecision + Send + Sync>>,
    pub after_tool: Option<Box<dyn Fn(&ToolCall, &str) + Send + Sync>>,
    pub should_stop_after_turn: Option<Box<dyn Fn(&Turn) -> bool + Send + Sync>>,
    pub steering: Option<mpsc::Receiver<String>>,
}

pub async fn run_loop(...) -> Result<Turn, HarnessError>;
```

Modelled on pi's `AgentLoopConfig` (optional closures) rather than deepseek's
container. Rust's answer to declaration-merging DI is a trait-object registry,
which is heavier than the problem.

### `afterray-agent` (~800 lines, the orchestration layer we lack)

**[Overtaken — the crate exists but the type does not. `afterray-agent` is a
`ModelSurface` implementation over the model queue plus error classification —
one file, tests included (`crates/afterray-agent/src/lib.rs:28`); every method sketched
below is still spread across handlers, and `policy::SummarizeOldest` was never
started.]**

```rust
pub struct AgentSession {
    // queue, cancellation, usage, tool registry, policy
}
impl AgentSession {
    pub async fn prompt(&self, text: String) -> impl Stream<Item = SessionEvent>;
    pub fn steer(&self, text: String);        // interrupt the current turn
    pub fn follow_up(&self, text: String);    // queue for the next turn
    pub fn abort(&self);                      // real cancellation
    pub fn context_usage(&self) -> Usage;
}
```

`policy::Truncate` (today's behaviour, the floor), `policy::PruneToolResults`
(deepseek's 187-line strategy: drop old tool results, keep the reasoning),
`policy::SummarizeOldest` (ask the model to fold the oldest rounds into a
summary block).

`tools::vault` holds the eleven existing tools, each implementing `Tool`.
**[Overtaken — tools stayed in the daemon, where the vault is, and the surface
is eight, not eleven; `list_moments` among others is gone →
`crates/afterrayd/src/tools.rs:122`, [context/agent-tools.md](../context/agent-tools.md)]**

Then `chat.rs`, `ask.rs`, and `slot_summarize` become thin handlers over one
session type instead of three separate assemblies.

## Phase 2 — compaction as a strategy

Follow deepseek's split: the contract is tiny and the strategies are separate.
Their `compaction` package is 172 lines and declares three methods —
`compactIfNeeded`, `compactNow`, `compactRegion`. `compaction-basic` is 1,515
lines; `compaction-tool-result-pruner` is 187.

Ship `PruneToolResults` first: it is cheap, needs no extra model call, and
addresses the common case (a transcript is mostly stale tool output).

pi's thresholds are worth copying as defaults: `reserveTokens: 16_384`,
`keepRecentTokens: 20_000`, compact when `tokens > window - reserve`.

**Compaction must be visible and non-destructive.** pi and deepseek both write
the summary as a new entry rather than editing history — deepseek calls it a
`compactCheckpointSource`. Our conversation is a flat message list in the
vault; the cheap equivalent is a `ChatRole::compaction` message row carrying
the summary and the range it replaced. The transcript builder skips the
messages a compaction covers; the UI renders it as a divider the user can
expand.

---

## How this reaches the SwiftUI chat

The wire is NDJSON over the unix socket: `tool_call` / `tool_result` / `token`
/ `done` / `error` (`stream.rs` → `ChatStreamEventDecoder`,
`ChatModels.swift:293`). Everything below is additive — an older app ignores
unknown event types, which the decoder already does by returning nil.

### New events

```jsonc
{"type":"usage","tokens":18240,"context_window":32768,"percent":55.7}
{"type":"compaction","summary":"…","covered_from_ms":…,"covered_to_ms":…,"freed_tokens":9100}
{"type":"tool_result","name":"get_slot_card","chars":6000,"truncated":true,"dropped":420}
```

- `usage` after each round, so the indicator moves during a long turn.
- `compaction` when a policy fires mid-turn; the UI needs to explain the pause.
- `truncated`/`dropped` on `tool_result` — the collapsed tool row can say
  "6,000 of 6,420 characters" instead of implying it read everything.

### `AfterRayChatModel` additions

```swift
@Published public private(set) var contextUsage: ChatContextUsage?
@Published public private(set) var compactionNotices: [ChatCompactionNotice] = []
```

Decoded in the same `for await event in stream` switch in `performSend`
(`AfterRayChatModel.swift:149`). `contextUsage` resets on `startNew()` and on
`select(_:)`, and is restored from the last assistant message's stored usage
when history loads — otherwise switching conversations shows the previous
one's fullness.

### View changes

1. **Usage indicator in `header`** (`AfterRayChatView.swift:168`). A thin bar
   or a "55%" label next to the conversation title. This is the only way a
   user learns why a long conversation starts forgetting. Show it only above
   ~50% so it is not permanent chrome. **[Overtaken — it is shown whenever a
   round has reported, turning coral past 75% →
   `swift/AfterRayRecall/Sources/AfterRayChatView.swift:525`]**

2. **Compaction divider in `thread`** (`:157`). A full-width rule with
   "Summarised 12 earlier messages" and a disclosure that expands the summary
   text. It must read as a checkpoint, not an error.

3. **Truncation note in the tool row** inside `ChatBubbleView` (`:350`), where
   tool calls already render collapsed.

4. **Composer while sending** (`composer`, `:263`). Today `canSend` is false
   during a turn, so the field is dead. With steering it stays live: Return
   sends a steer, and the placeholder changes to "Add to this turn…".

### Real cancellation

Today: `stop()` cancels the read task → socket closes → the daemon notices at
its next `write_event` inside `emit_gate_tokens` (`stream.rs:329`). If the
turn is inside a long tool call, or has not emitted a first token, nothing is
cancelled.

Fix, in order of cost:

- **Cheap:** the daemon polls whether the write half is still open between
  rounds, not only when writing tokens. Catches "stopped during a tool call"
  without a protocol change.
- **Correct:** a `ChatAbort { conversation_id }` request on a second
  connection, so the intent is explicit rather than inferred from a broken
  pipe. Needed anyway for `abortCompaction`-style granularity later.

### Steering, end to end

pi separates two things we would otherwise conflate: `steer` interrupts the
current turn and is delivered before the next model call; `follow_up` queues
for after it finishes. Both are worth having — "only look at the afternoon"
is a steer, "now summarise it for my standup" is a follow-up.

Wire shape: `ChatSteer { conversation_id, message, deliver_as: "steer" |
"follow_up" }` on a second connection. `AgentSession` holds the receiver that
`LoopConfig.steering` drains between rounds. The UI shows a steer immediately
as a user bubble with a distinct marker, because it is not a new turn.

---

## Order, and what each step buys

| step | cost | buys |
|---|---|---|
| 0.1 whole-record truncation | S | model stops seeing half-JSON |
| 0.2 budget reconciliation | S | rounds 3–5 stop running blind |
| 0.3 token estimate | S | budgets mean something in Chinese |
| 0.4 catalogue test | XS | prompt/tool drift cannot recur |
| 1 extract two crates | L | one loop for chat/ask/T2; tools become values |
| 2 `PruneToolResults` + `usage` event | M | long conversations survive; user sees why |
| 3 real abort | M | stop actually stops |
| 4 steering | M | course-correct a long retrieval |
| 5 `SummarizeOldest` | M | whole-day questions stop hitting the wall |

Phase 0 is worth doing before Phase 1: the defects are live now, and none of
the fixes are wasted — each moves into the new crates unchanged.

## Deliberately not copying

- **Session trees and forking** (pi `session-manager` 1,714 lines). Branching
  from an arbitrary history point is a coding-agent need. Ours is "what did I
  do on Tuesday".
- **The extension system** (pi 3,932 lines, deepseek's cordis). No third-party
  ecosystem to serve. The `LoopConfig` hooks give us the same seams internally
  at a fraction of the cost.
- **TUI/RPC modes** (pi `modes/` 19,533 lines). Our surface is SwiftUI.
- **Model catalogues and OAuth composition** (pi `ai` 27,113 lines). We have
  `ModelQueue` and `LlmRouterAdapter`. The one piece worth taking is *scoped
  models*: T2 summarisation is offline, slow, and quality-sensitive; chat is
  interactive and latency-sensitive. They should not be forced onto one model.
