# The acts join — screen state × input events

How a T1 card learns **what the user did**, not only what was on screen.

Approved design and the experiments behind every number:
[docs/input-events-and-t1-acts-plan.md](../docs/input-events-and-t1-acts-plan.md).
Code: `crates/afterray-store/src/acts.rs` (pure), `memory.rs` (geometry parse),
`slot.rs` (card assembly + prompt), `lib.rs` (`slot_card`, materialisation),
`afterrayd/src/main.rs` (signal gaps, sweeper).

## The principle

Two independent fact streams, joined by time and tree position:

| stream | what it answers | where it lives |
|---|---|---|
| accessibility tree / OCR | what could be **seen** | `moments` + AX artifacts, long-lived |
| input events | what the user **did** | `input_events`, 48h |

**T1 only joins. It never infers.** Every attempt to derive agency from screen
content failed on some app: geometry heuristics (wrong on app switch),
placeholder parsing (overfit), text churn (group chat measured it pointing the
*wrong way* — the engaged pane gained 0 lines, the untouched sidebar 40),
handing the raw tree to a model (made the fact layer depend on model strength).
With inference gone, app-specific knowledge has nowhere to live.

Why it matters, measured on a real 2026-08-17 slot: 67% of one prompt's budget
went to a Feishu conversation list the user never touched, and the card came out
as "multi-group scan" with the actual 1:1 conversation unmentioned.

## Geometry

`memory::accessibility_scope_tree` parses the snapshot into a flattened arena
with parent links and `depth` — every question the join asks is an upward walk,
which the nested shape turns into a search. Node `frame`s have always been
written by the shim (measured: 1106 of 1115 nodes) and nothing read them until
this join.

**One traversal produces both the line vector and the arena.**
`accessibility_text_lines` delegates to it. This is load-bearing:
`AX_TEXT_MIN_CHARS` (400) decides AX-vs-OCR text source by counting the *whole*
vector, and the join partitions that same vector. If the two could disagree,
partitioning would silently demote a frame to whole-screen OCR — and that frame
is exactly the one the join works best on. Pinned by
`partitioning_never_flips_a_frames_text_source`.

Rects are `f64` in global top-left screen points: tree nodes carry doubles, the
shim's event targets carry rounded ints, and both deserialise into `AxRect`
without a second shape to maintain.

## Engaged scope

1. **Hit-test** — deepest node whose frame contains the centre of the event's
   target rect. Ties: smaller area, then lower index, so two frames of the same
   UI resolve identically. A zero-area frame is never hit.
2. **LCA** of all landing points in that frame.
3. **Expand** to the smallest ancestor covering
   `ENGAGED_MIN_WINDOW_AREA_RATIO = 0.10` of its window, stopping at the window.
   A single click's LCA is usually one label; the region a person would *name*
   is the pane around it.

`ENGAGED_MIN_WINDOW_AREA_RATIO` is **the only tuning knob in the join**, pinned
against real corpora. Anything else that wants to be a knob is a heuristic.

**Fail open everywhere.** No hit, no window node, or an unmeasurable window
frame → **no scope**, and no scope means no partition. An invented scope reads
downstream as "the user was here", which is worse than silence.

Scope identity across frames is a `role:label` path from the window down
(`scope_key`), not a node index: indices are per-snapshot, and a list that
gained a row must not read as a different region.

## Acts

Fixed shape, every field always serialised — a reader must be able to tell
"zero keys" from "keys unknown", and a missing field cannot:

```json
{"keys": 180, "submits": [{"at_ms": 0, "kind": "return"}],
 "clicks": [{"label": "0817.log", "count": 1}], "scrolls": 2, "signal": "ok"}
```

- `keys` — burst counts summed. Never content; a burst is a count, an end
  instant, and the key that closed it.
- `submits` — `command` rows only. **`ended_with` is deliberately not a
  submit**: the shim emits both a burst carrying the key that closed it *and* a
  separate `command` row for that key, so counting both doubles every Return in
  the slot. Pinned.
- `clicks` — tallied by target label (else role, else `unknown`), ordered by
  count then label so a card is reproducible.
- An unknown `kind` from a newer shim counts as presence for coverage and
  contributes to nothing it cannot be read into.

## Run splitting — hysteresis

`split_act_runs` segments the event stream by scope, but a new scope becomes a
boundary only once **sustained**: ≥2 events (`RUN_HYSTERESIS_MIN_EVENTS`) or
≥15s of span (`RUN_HYSTERESIS_MIN_MS`).

Without it, triage — glancing at four conversations and answering one —
shatters into four runs of one click each, which is how the "multi-group scan"
card happened. An un-promoted excursion folds back into the run it interrupted,
where its clicked labels survive as the honest record of the glancing. An
**unresolved** scope never forces a boundary: not knowing where an event landed
is not evidence that it landed somewhere new.

Acts are attributed to timeline runs at act-run granularity (largest temporal
overlap), never per event — splitting a stretch across two rows would undo the
hysteresis. Timeline rows themselves are still cut by `target_key`; re-cutting
the timeline by scope is later work.

## R3 edge frames

The 10s heartbeat misses whatever a person only looked at *between* two ticks —
stepping into a conversation for eight seconds and leaving. R3 fills that hole:
the shim walks the window a trigger landed in (frontmost-app change or a click,
after a 500ms settle any further input re-arms, bucketed to ≥5s apart and ≤6 a
minute) and emits it as an unpaired `accessibility_edge` artifact. **Never a
screenshot** — an event-driven frame outliving its events would keep exposing
interaction instants after the record of the interaction was erased, which is
also why `edge_snapshots` share `INPUT_EVENT_RETENTION_MS`.

In the join (`Vault::edge_frames_between` → `slot::EdgeFrame`) an edge tree is
**text and only text**: its lines go to the run whose span contains it,
partitioned engaged/peripheral by its own `join_frame`, and it contributes no
`moment_id`, no anchor, no OCR evidence, and no `facts` count — every one of
those answers "which frames does this card stand on", and an edge tree is not
one. Pinned by `an_edge_tree_changes_no_frame_facts_and_no_acts`.

Three deliberate limits: edge trees do **not** write resolved scopes back onto
the events (run splitting segments on those, and R3 widens what a run shows
rather than re-cutting the runs); a tree landing in a capture gap belongs to no
run and is dropped, never attached to the nearest one; and they are gated on the
event stream exactly like the partition, so invariant 1 below covers them too.

## Signal — `unavailable` is not idle

The daemon turns shim warnings `input_tap_stalled` / `input_tap_unavailable`
into a synthetic `signal_gap` row in the *same* table (`kind` is stored
uninterpreted, so no schema change). It must ride the event stream, because T1
reads an absence of events as "the user did nothing" — the single inference this
pipeline exists to prevent.

A gap runs from its marker **to the next observed input event** (that is when
the tap demonstrably worked again), or through the slot end when nothing ever
proved recovery. The span is half-open: the recovering event is itself an
observation, so the instant it lands is available, not lost. A batch the daemon
failed to store writes the same marker over the batch's own span — losing rows
and never seeing them look identical from here, and both must read as
unobservable rather than idle. Inside such a stretch,
**every engaged claim is suppressed**:

- run `signal` becomes `unavailable`,
- no region is listed in `not_engaged`,
- **the text partition itself does not happen** — splitting text into "operated"
  and "merely visible" is an assertion about agency.

## Card and prompt

- `RunRow.acts` — `None` only when the slot has no event stream at all. A run
  with an `ok` signal and zero acts is a *fact* ("22 minutes here, no keys") and
  only a live stream can state it.
- `RunRow.lines` — the engaged region, taking the full existing infoscore
  budget, so IDF de-chromes *within* the bucket that matters instead of ranking
  a sidebar against a conversation.
- `RunRow.peripheral` — stored whole (folding belongs to the render layer, so a
  card can be re-rendered at a different budget); the prompt folds it to
  `PERIPHERAL_CAP_CHARS = 200` plus a `not_shown` count. The count is the
  load-bearing half.
- `SlotCard.not_engaged` — regions on screen all slot that received no input,
  with line counts. The field that moved weak models in the experiment.
- `SlotFacts.no_input_ratio` — complement of observed input coverage, point
  events counted as 1s. `None` when the slot holds no input event: unmeasured is
  not zero. `idle_ratio` keeps its name and meaning (it is really "recording was
  paused") for UI compatibility.
- `T2_SYSTEM_PROMPT_V2`: *acts are what the user did; text is what was on
  screen; peripheral was visible but not operated.*

**Known v1 blind spot:** a user who genuinely sat still and a tap that was never
running both read as a high `no_input_ratio`. Only an explicit `signal_gap`
separates them, and only when the shim noticed. Pure keyboard navigation (⌘K,
j/k) is undetectable by design — the heartbeat covers it; no heuristic is added.

## Materialisation

Events are deleted after 48h and T1 is computed lazily, so **unfrozen acts
vanish from history**: two days on, a card keeps the half about the screen and
silently loses the half about the user.

`materialize_slot_acts` freezes per-run acts (keyed by the run's `moment_id`, not
its position — a deleted frame would renumber positions) plus `no_input_ratio`
into `slot_summaries.acts_json`; `slot_card` reads it when
`input_events_between` comes back empty. Idempotent (`WHERE acts_json IS NULL`),
so the five-minute sweeper can revisit forever.

The freeze runs **before and independently of the T2 gate**: it is a short read
and one small write with no model in it, and the deadline it races is physical.
Gating it behind T2's AC-power and battery conditions would lose acts on exactly
the laptops that stay unplugged.

A row created by the freeze carries `degraded` with no title, which is what the
day panel already renders for an unsummarised slot — it cannot conjure a phantom
slot, and it cannot stop T2 from running later.

The frozen copy restores **acts only, never the partition**: that was computed
by hit-testing rects that no longer exist.

## Invariants — do not weaken

1. **Fail-open, byte-for-byte.** A slot with zero input events produces exactly
   the pre-acts card and prompt. Pinned by
   `slot::tests::zero_input_events_reproduce_the_pre_acts_card_and_prompt`
   against a fixture captured before acts existed. The gate is the *event
   stream*, not a caller remembering to clear `ax_join`.
2. **The text-source gate counts every line** (see Geometry).
3. **`unavailable` suppresses every engaged claim** (see Signal).
4. **T1 stays pure**: no model, no network, no clock inside card building. The
   caller owns "sealed"; `Vault` is reached from async only via `run_store`.
5. **Every slot a span touches owes acts.** A burst crossing a boundary is
   typing that happened in both slots; enqueueing only the one it started in
   leaves the other unfrozen, and once the events expire it fails open forever
   — silently dropping work the user did.
6. **Never holds typed characters.** Bursts are counts; targets carry labels,
   never values.
