# Decision: The playhead holds a sliding window of lean local-day indexes

Status: active
Area: recall-ui
Anchors:
- crates/afterray-store/src/lib.rs @dec:sliding-timeline-day-window
- crates/afterray-protocol/src/lib.rs @dec:sliding-timeline-day-window
- swift/AfterRayRecall/Sources/RecallStore.swift @dec:sliding-timeline-day-window
- swift/AfterRayRecall/Sources/DaemonClient.swift @dec:sliding-timeline-day-window
- swift/AfterRayRecall/Sources/RecallView.swift @dec:sliding-timeline-day-window
- apps/AfterRay/Sources/AfterRayApp.swift @dec:sliding-timeline-day-window
Supersedes: ../../superseded/architecture/2026-08-21-lean-timeline-read-model.md
Superseded-by: —

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
present. Empty local days are still probed and remembered so
a gap is one travel, not a dead end. The window stays at most seven local days;
the day on the opposite side of travel drops off. A jump beyond the loaded span
recentres rather than filling the gap. `moment_get` and `evidence_ocr` remain
the only paths that carry original screen text.

While a scrub is live, its frozen layout is replaced only when the published
window grows past one of that snapshot's boundaries. This admits a neighbour
that arrived from either the scrub request or launch prefetch without making
ordinary detail hydration move the pointer. A routine refresh rebases an
in-flight neighbour merge onto the current window; only a clear or recenter
cancels that merge. Concurrent callers for the same outer day join one fetch
instead of treating the second caller as a failed prefetch. Wheel and pointer
drags enter the same scrub initializer, which snapshots that layout before
marking the interaction live.

Day summaries stay an independent read model. A failed index read is a
visible error, not an empty first day. Returning to NOW explicitly requests
today's local-day range.

## Alternatives considered

**Keep the one-day clamp and only jump from the summary list.** That is the
superseded decision working as designed. The playhead is the product's
continuous time control; crossing midnight has to work there.

**Reload the full lean archive.** The JSON-line cap and the warped playhead
spine both grow with vault age. The overlay still has no reason to hold every
day.

**A centre-plus-limit `recall_window`.** That API still materialises a whole
session. The playhead's unit is the local day the history panel already
speaks.

## Consequences

**Bought:** overlay launch remains a bounded range read; the playhead always
starts with two prepared local days on either side plus a one-day refill
reserve; directional travel shifts that reserve before the guarantee is
consumed. Empty days do not trap the playhead.

**Cost:** initial publication reads up to seven days rather than one, trading a
larger fixed launch read for zero adjacent-day dependency during interaction.
A later outer-day merge can remap the in-flight scrub once, but the refreshed
mapping lets that same gesture continue. Protocol 16 is unchanged.
