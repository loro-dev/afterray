# Decision: The playhead holds a pointer-centred window of lean local-day indexes

Status: active
Area: recall-ui
Anchors:
- —
Supersedes: —
Superseded-by: —

## Problem

This filename is the original lean-index record. The governing text lives in
[2026-08-22-pointer-centered-timeline-day-window.md](2026-08-22-pointer-centered-timeline-day-window.md).
The one-day clamp that used to live here is in
[superseded/architecture/2026-08-21-lean-timeline-read-model.md](../../superseded/architecture/2026-08-21-lean-timeline-read-model.md).

## Decision

See [2026-08-22-pointer-centered-timeline-day-window.md](2026-08-22-pointer-centered-timeline-day-window.md).
List RPCs stay a lean index. The overlay holds a sliding window of local days.

## Alternatives considered

**Leave this file as the one-day clamp.** That clamp is what blocked scrubbing
into yesterday. The replacement record is the authority.

## Consequences

**Bought:** the filename that already shipped in this change still exists so
the tree does not carry two contradictory active records.

**Cost:** this file is a pointer. Do not add new anchors here.
