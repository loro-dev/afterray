# The agent tool surface

What the language model can see and ask for, and why it has that shape. Code:
`crates/afterrayd/src/tools.rs` (surface + catalog), `agent.rs`
(`RECALL_SYSTEM_PROMPT`), `chat.rs` / `stream.rs` (openings).

The whole surface is read-only by construction: tools hold an
`afterray_store::SharedReadOnlyVault`, which has no writing methods, and the
`jail` test in `tools.rs` fails the build if a tool reaches for the filesystem,
a process or a socket. See `docs/harness-threat-model.md`.

It is *owned* rather than borrowed because `ToolHost::invoke` runs the whole
dispatch inside `spawn_blocking`. Every tool below is a synchronous vault read
— a day of summary rows, an FTS query, a slot card, an artifact decrypt — and
awaiting one on a Tokio worker parks it for the duration. The daemon runs one
worker per two cores, so eight concurrent tool calls is every worker blocked,
and socket accepts and capture import stop being scheduled behind them. This is
`afterrayd`'s standing "never call `Vault` from async" rule; the tool host
obeys it by moving across once per call rather than per query.

## Eight tools, in two groups

```
find a stretch of time          read one
  get_day_summary                 get_slot_card
  search_summaries                get_moment_context
  search_evidence                 get_transcript
                                  list_activity
                    get_now
```

That grouping *is* the interface. The surface was fourteen flat entries and a
model choosing among them chose badly. What went, and why:

| Removed | Because |
|---|---|
| `get_moment`, `get_ocr`, `get_ax_digest` | all three reads live inside `get_moment_context`, billed once instead of three rounds |
| `get_ax_tree` | the full accessibility JSON cannot fit a 16k window |
| `list_moments` | ids now arrive attached to day summaries, search hits and mentions |
| `list_memories` | per-span AX records — the same question `list_activity` answers |

`search_summaries` and `search_evidence` take **identical arguments**
(`query`, `from_ms`, `to_ms`, `app`, `limit`) and differ only in the layer they
read. An agent that has to remember which search can be narrowed by what will
narrow neither.

| | reads | covers |
|---|---|---|
| `search_summaries` | stored v2 cards: titles, thread names/prose, entities | only stretches a model has summarised |
| `search_evidence` | OCR + transcripts (FTS5) | everything captured, noisier |

## Time: copied, never computed

Every tool takes epoch milliseconds. `get_now` returns a table — seven
individual days, this/last week, this/last month — with **dates beside the
numbers** and each value written `from_ms=…` so it is copied whole rather than
split out of a range. The date column feeds the one string argument that
exists anywhere, `get_day_summary {"day":"2026-08-13"}`; the millisecond
columns feed everything else.

An earlier design parsed `{"window":"yesterday"}`, `{"days_ago":2}`,
`{"from_local":…}` and `{"at_local":…}` on the premise that copying thirteen
digits was itself error-prone. It is not — verbatim copying is the most
reliable thing a small model does. The observed failure was a model *computing*
`1_723_703_599_000` and landing two years out. A table removes the occasion for
arithmetic; a parser only adds spellings.

## System is rendered once per conversation

The catalog's clock table is not a hardcoded date. Chat calls
`render_recall_system(conversation.created_at_ms, language)` so every later
turn of that thread sends the **same system bytes** and the prefix cache
hits. A new conversation gets a new table. Ask has no thread and renders
from the request's wall clock.

The table is Now + seven days + this/last week + this/last month. It does
**not** include `Right now`, `Today's apps`, or `Recording covers` — those
change while a thread is open, so the catalog only shows them behind
`EXAMPLE SHAPE ONLY` / `example:`. The live values come from the `get_now`
tool.

There is still no clock in the opening. `build_opening` sets
`seed: String::new()` — a drift test asserts it stays that way. What the
question carries is one stamped line, `[asked at …]`. That is free: the
question is the turn's new content regardless. It is how a model tells a
catalog table from conversation start apart from a `get_now` result folded
into history hours ago.

Chat and ask inject `Reply language: …` from `summary_language` — the same
preference T2 uses — so a user who set summaries to Chinese does not get
English chat. `auto` follows `AppleLanguages`. `ui_language` is chrome only.

The cost of a later instant is one round: `get_now`.

## The catalog documents everything

The catalog also carries the reply format — `TOOL`/`ARGS` or `FINAL`, never
both, never Qwen `<tool_call>` markup. Chat's system prompt may not name a
tool, so this block is the only place the model is told how to call one.
The harness still accepts a leaked `<tool_call>` as a call (pi's rule: a
parseable call always continues) so a 4B model that ignores the format does
not end the turn.

Every tool lists all of its arguments and the exact shape of what it returns.
This is deliberately longer than one line per tool: a parameter a model has to
discover by trial costs a round, and a round costs more than the prose saves.
`every_argument_the_tools_read_is_documented` scans the source for
`args.get("…")` and fails on any argument the catalog omits.

What the catalog does *not* carry is caveats. Those belong in the output, at
the moment they apply:

- `search_summaries` with no hits says it reads written summaries only, and
  points at `search_evidence` — otherwise an empty result reads as "it never
  happened", which the model would report as fact.
- A stretch nothing has summarised is marked `[not summarised: …]` inline, so
  its app list is never mistaken for a finding.
- A window outside the recording comes back with the coverage span and the
  numbers to retry with.
- Anything cut for size says where it stopped and how to resume.

A caveat repeated in two places is a caveat that will disagree with itself.

## Budgets

`ContextBudget::system_tokens` is a **measurement** of the system prompt plus
the catalog, currently ~1 883 against a budgeted 2 048.
`the_catalog_and_system_prompt_fit_the_budget_they_are_charged_to` re-measures
it. When that fails, move the constant deliberately rather than shaving the
catalog to fit — and note the knock-on: `MINIMUM_WINDOW_TOKENS` rose to 4 096
because a 2 048 window has nothing left after a catalog this size, and a 4 096
window now buys two rounds rather than four.

`get_day_summary` renders at two densities and chooses by measuring against
`tool_result_tokens` (~1 790; CJK costs a token per character, not a quarter).
A worked day is ~48 stretches at the default ten-minute length (fewer if the
user has widened it in Settings); the rich form — threads, cited
frames, entities, decisions — overflows about fourfold, and `truncate_head`
cuts the *tail*, which deletes the afternoon from an answer about the day. The
compact form keeps every stretch's time, `at_ms` and title, and says
`titles only`. Losing a stretch's detail costs one more call; losing the
stretch costs a wrong answer.

## Embeddings are off

Read and write, until the retrieval redesign lands. `Vault::semantic_search`
has no vector index: it reads every stored vector out of SQLite as JSON
(9.2 KB a row) and scores cosine in Rust. Measured on release, ~0.034 ms per
row — 683 ms over a week of capture, ~3 s over a month, ~34 s over a year, and
it runs on the async runtime.

`nothing_in_the_daemon_computes_or_stores_an_embedding` scans `main.rs` and
fails if `semantic_search`, `insert_embedding` or `ModelInput::Embedding`
return. `text_evidence` keeps the text, so vectors are re-derivable whenever
the redesign arrives; nothing irreversible was given up by stopping.

## Narrowing happens in SQL

`SearchFilter` (time range + application) is applied inside the query, before
ranking, and `search_summaries` matches JSON *values* through `json_each`
rather than the serialised card — `LIKE` on the raw text also matched serde's
key names, so searching for `text` or `name` filled the candidate window with
rows the exact matcher then discarded. Ranked-then-filtered answers a different question than the caller
asked, and answers it with silence: ask for last month's work on a term you
also used this week, and the global ranking fills with recent hits, the
post-filter drops all of them, and the tool reports nothing while the evidence
sits in the vault.

## The T2 slot surface

The summariser has its own, much smaller tool host (`afterrayd::SlotT2Tools`),
scoped to one slot: **`get_ocr`**, and **`get_transcript` only when that slot
recorded audio**. It is not the chat catalog above and shares no code with it.

Two tools were removed with card v3, for the same reason: measured across
Haiku / qwen3.5:4b / qwen3.5:9b / qwen3.6:35b on a dense real hour, `get_run_text`
was called zero times by the three smaller tiers and `get_prev_cards` by none of
the four, while the 35b spent rounds discovering a transcript tool on a silent
slot. What they served is now handed over instead of offered: neighbouring cards
are injected with their descriptions, and what the budget left out is disclosed
as `more_chars` and left there. A prompt that invites a fetch it will not get is
a prompt that teaches procedure instead of writing.

The prompt itself is `afterray_store::render_t2_system_prompt(has_audio)`, and
the evidence view is `render_t2_prompt(…, budget_chars)` — the budget comes from
the real context window, never a constant.
