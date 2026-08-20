# Decision: Raw input events expire after 48 hours, whatever the vault's size

Status: active
Area: privacy
Anchors:
- crates/afterray-store/src/lib.rs @dec:raw-input-events-expire
- crates/afterrayd/src/main.rs @dec:raw-input-events-expire
Supersedes: —
Superseded-by: —

Narrows [size-driven retention](../architecture/2026-08-20-size-driven-retention.md), which
holds for every other kind of captured content. That record still stands; this
one takes one stream out from under it.

## Problem

Event-capture v2 retired CAP-005's ban on keystroke content, on the grounds that
everything is processed locally and the vault is encrypted. Both halves of that
are true, and the ban's premise — content crossing a trust boundary — really
does not apply.

What the reasoning did not cover is *duration*. An `input_events` row now holds
the run of text the user typed and the value of the field they typed it into. It
is the single most specific thing in the vault: not a picture of a screen that
happened to contain a password field, but the characters themselves. Under
size-driven retention that row lives until the disk fills, which on a 100 GB
budget is months. "Encrypted at rest" answers the wrong question — the risk is
not someone reading the disk, it is the vault holding a verbatim keystroke log
of the user's last several months at all.

## Decision

A raw `input_events` row is deleted once it is older than
`RAW_EVENT_RETENTION_MS` (48 hours), regardless of how much space the vault is
using. This is the second clock in the store, alongside `SIGNAL_MARKER_RETENTION_MS`.

**The freeze runs first.** `materialize_slot_acts` writes the *shape* of the
activity — counts, labels, submit instants, `no_input_ratio` — into
`slot_summaries.acts_json`. `acts::ActContent`, which carries the typed text and
the field values, is deliberately never frozen. So a slot past the cutoff still
says how much was typed and stops saying what.

The daemon's sweeper enforces the order in one tick: `freeze_slot_acts`, then
`expire_raw_input_events`. The expiry lists every slot that still holds expiring
events and has no frozen acts; if that list is non-empty it freezes what its
per-tick budget allows and **defers the delete to a later tick**. A window is
never deleted before it is frozen.

`ACTS_FREEZE_LOOKBACK_MS` is derived from `RAW_EVENT_RETENTION_MS` rather than
set independently, so the freeze always reaches every slot whose events are
still alive.

**A slot whose events are gone is never summarised.** `due_slot_windows` drops
it, for the sweeper and for the explicit backfill alike. The freeze keeps enough
for the T1 card to still show where the user was working; it does not keep
enough to write a T2 card from, and a card written from screen text alone would
describe the screen while saying nothing about the person in front of it — with
nothing to distinguish that from a slot where the user genuinely sat still.
Cards are written once and never revised, so an absent card is the honest
outcome. Those slots stay `Degraded` and read as "Not summarised" in the UI.

## Alternatives considered

**Delete on schedule, accept losing unfrozen acts.** Simpler, and it makes 48
hours a hard guarantee instead of a near-one. Rejected because the loss is
silent and unrecoverable: a card built from no events makes no claim about the
user — which is the correct failure and is what `build_slot_card` already does —
but it also cannot say the user typed two thousand characters that afternoon,
and nothing can reconstruct that afterwards. Deferring the delete costs at most
a few sweeper ticks, and only after the daemon has been down long enough to
build a backlog.

**Gate the delete on T2 having summarised the slot.** Rejected: T2 waits for AC
power, so a laptop that stays unplugged would never expire anything. The freeze
deliberately runs outside that gate for the same reason.

**Summarise the expired slot anyway, from whatever survives.** Rejected, and
this is the alternative that looks most reasonable: a card from screen text is
better than no card. It is not, because the card cannot say which one it is. A
reader has no way to tell "the user sat still" from "the record of what the
user did was deleted before anyone read it", and the card is written once and
never revised. A missing card states the gap; a half-sourced one hides it.

**Freeze the content too, so cards keep their words after expiry.** Rejected —
it defeats the decision. Frozen content in `acts_json` would outlive the events
by design and sit in `slot_summaries` indefinitely, which is the state this
record exists to end.

**A shorter window (24h).** Not chosen, but nothing rules it out; 48 hours
matches the marker retention already in the crate and leaves a full day of slack
for a machine that was asleep. The constant is the only thing to change.

## Consequences

**Bought:** the vault stops accumulating a verbatim keystroke log. After two
days what remains of a user's typing is how much of it there was and where it
went, which is what the T1/T2 cards actually consume.

**Cost:** two clocks in a crate whose retention story used to be one sentence.
Anyone adding a third should expect to supersede both records rather than add
another deadline quietly.

**A gap in the record, not a wrong record.** A machine left on battery for more
than two days produces slots with no T2 card at all. That is the intended
outcome and the reason the rule exists, but it is a real product cost: the user
sees "Not summarised" for that stretch and cannot ask for it later, because the
backfill obeys the same rule. Asking for the summary does not put the evidence
back.

**48 hours is a ceiling on the raw rows, not on the summary.** The T2 card was
written by a model that read those rows, and its prose stays in
`slot_summaries.details` for as long as the slot does. The honest user-facing
claim is "the raw record of what you typed is deleted after two days", never
"after two days we no longer know what you were writing about".

**Deletion is not instant when the daemon has been away.** A vault that has been
offline for days freezes at `ACTS_FREEZE_PER_TICK` slots per tick before it
deletes anything, so the effective window is 48 hours plus the drain. Every
other path deletes on time.

## Testing

`expiring_events_keeps_the_acts_and_drops_the_words` pins both halves: the card
can quote typed text while the events live, and after the freeze-then-delete
sequence the rebuilt card carries acts, carries no `ActContent`, and contains
the typed string nowhere in its serialised form.
`oldest_input_event_ms_judges_a_span_by_its_end` pins the sweep's question
against the delete's, which must agree or the sweep spins.
`a_slot_whose_events_have_expired_is_never_summarised` and
`a_slot_ending_on_the_expiry_cutoff_is_still_summarised` pin the T2 rule and its
boundary, without a vault — `due_slot_windows` is pure for that reason.
