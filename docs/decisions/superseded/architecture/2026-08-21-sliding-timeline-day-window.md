# Decision: The playhead holds a sliding window of lean local-day indexes

Status: superseded
Area: recall-ui
Anchors:
- —
Supersedes: 2026-08-21-lean-timeline-read-model.md
Superseded-by: ../../active/architecture/2026-08-22-pointer-centered-timeline-day-window.md

## Problem

A playhead that downloads the whole vault, with OCR concatenated onto every
row, misses the 30s unary deadline and the 64 MiB JSON-line cap. Clamping the
index to the playhead's local calendar day keeps those reads small, but then
drag, wheel, and arrow keys cannot leave that day: `applyPlayhead` clamps to
the loaded captures, so yesterday is unreachable without a jump through the
summary panel.

## Decision

List RPCs return a **lean index**: identity, time, app, still/GOP pointers,
audio pointers. They do not concatenate `ocr_text` or `transcript_text`.
`timeline_range` is the overlay's list read. Launch, NOW, and a recenter do
one atomic range read for the playhead day plus three local days on either side.
The inner two days on each side are the interaction invariant; the outer day
is refill reserve. The seven-day window is published only after that read is
prepared, so entering an adjacent day never depends on an edge request.
Once travel has a direction, the outer reserve shifts toward the next calendar
day before the pointer crosses midnight, while the two-day guarantee remains
present. Empty local days are still probed and remembered so a gap is one
travel, not a dead end. The window stays at most seven local days; the day on
the opposite side of travel drops off. A jump beyond the loaded span recentres
rather than filling the gap. `moment_get` and `evidence_ocr` remain the only
paths that carry original screen text.

While a scrub is live, its frozen layout is replaced only when the published
window grows past one of that snapshot's boundaries. This admits a neighbour
that arrived from either the scrub request or launch prefetch without making
ordinary detail hydration move the pointer. A routine refresh rebases an
in-flight neighbour merge onto the current window; only a clear or recenter
cancels that merge. Concurrent callers for the same outer day join one fetch
instead of treating the second caller as a failed prefetch. Wheel and pointer
drags enter the same scrub initializer, which snapshots that layout before
marking the interaction live.

Day summaries stay an independent read model. A failed index read is a visible
error, not an empty first day. Returning to NOW explicitly requests today's
local-day range.

## Alternatives considered

**Keep the one-day clamp and only jump from the summary list.** The playhead is
the product's continuous time control; crossing midnight has to work there.

**Reload the full lean archive.** The JSON-line cap and the warped playhead
spine both grow with vault age. The overlay still has no reason to hold every
day.

**A centre-plus-limit `recall_window`.** That API still materialises a whole
session. The playhead's unit is the local day the history panel already speaks.

## Consequences

**Bought:** overlay launch remains a bounded range read; the playhead starts
with two prepared local days on either side plus one refill day.

**Cost:** changing direction moved the reserve even when the pointer remained
in the same day. Each reversal could fetch a day, rebuild the full window, and
publish during active inertia. That cost is why this decision was superseded.
