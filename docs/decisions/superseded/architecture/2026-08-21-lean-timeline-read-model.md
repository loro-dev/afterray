# Decision: Recall list reads are a local-day index; OCR stays on the selected moment

Status: superseded
Area: recall-ui
Anchors:
- —
Supersedes: —
Superseded-by: 2026-08-21-sliding-timeline-day-window.md

## Problem

The overlay's history list renders a page of slot cards, and the playhead
scrubs one local calendar day. The launch path nevertheless asked
`timeline_list` for every moment in the vault, and each row concatenated every
OCR and transcript line. At tens of thousands of artifacts that RPC misses
the 30s unary deadline and the 64 MiB JSON-line cap. Connection errors are
swallowed, so the UI paints the empty first-day state while capture is still
writing. Slot summaries never load, because they wait on that same call.

## Decision

List RPCs return a **lean index**: identity, time, app, still/GOP pointers,
audio pointers. They do not concatenate `ocr_text` or `transcript_text`.
`timeline_range` is the overlay's list read: one local calendar day, inclusive
bounds. Incremental refresh reuses that range on the already-loaded day's
tail. `moment_get` and `evidence_ocr` are the only paths that carry original
screen text, and they run for the selected moment after the playhead settles.

Day summaries start independently of the index read, so they can render while
a range is slow and still load when it fails. A failed index read is a visible
error, not an empty first day. Returning to NOW explicitly requests today's
local-day range; it never infers "today" from an older loaded playhead.

## Alternatives considered

**Keep `timeline_list` and only drop the OCR subqueries.** A lean full-archive
scan would likely fit the deadline today, but the overlay still has no reason
to hold every day in memory, and the next growth step would hit the JSON-line
cap again.

**A centre-plus-limit window (existing `recall_window`).** That API still
materialises a whole session and truncates in process. The playhead's unit is
the local day the history panel already speaks, not an arbitrary 500-row
slice.

**Null the OCR fields without a protocol bump.** The list payload would shrink,
but a client that needed a bounded day would still have no request to name
one, and the handshake would not tell a stale app that the read model
changed.

## Consequences

**Bought:** overlay launch and the 5s recording poll stay proportional to one
day. History cards appear even if the index read fails. Details OCR is one
row.

**Cost:** scrubbing a day that is not loaded requires a range fetch first.
`timeline_list` remains for the CLI and is lean, but it is no longer what the
app uses. Protocol 16.
