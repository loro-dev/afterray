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
`timeline_range` is the overlay's list read. Launch and NOW fetch the
playhead's local day; the store then prefetches one occupied neighbour on
each side. Scrubbing into the first or last loaded capture extends that
window, skipping empty local days so a gap is still one travel, not a dead
end. The window is at most seven local days; days farthest from the playhead
drop off. A jump of more than one calendar day recentres rather than filling
the gap. `moment_get` and `evidence_ocr` remain the only paths that carry
original screen text.

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

**Bought:** overlay launch stays proportional to one day; scrubbing can
cross midnight without a 64 MiB download. Empty days do not trap the
playhead.

**Cost:** a neighbouring-day merge can remap the in-flight scrub once, but
the fetch starts one visible viewport before the edge and the refreshed
mapping lets that same gesture continue into the new day. Protocol 16 is
unchanged.
