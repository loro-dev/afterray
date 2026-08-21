# Decision: Timeline warmth follows the pointer's day, not travel direction

Status: active
Area: recall-ui
Anchors:
- crates/afterray-store/src/lib.rs @dec:pointer-centered-timeline-day-window
- crates/afterray-protocol/src/lib.rs @dec:pointer-centered-timeline-day-window
- swift/AfterRayRecall/Sources/RecallStore.swift @dec:pointer-centered-timeline-day-window
- swift/AfterRayRecall/Sources/DaemonClient.swift @dec:pointer-centered-timeline-day-window
- swift/AfterRayRecall/Sources/RecallView.swift @dec:pointer-centered-timeline-day-window
- swift/AfterRayRecall/Sources/TimelineLayout.swift @dec:pointer-centered-timeline-day-window
- apps/AfterRay/Sources/AfterRayApp.swift @dec:pointer-centered-timeline-day-window
Supersedes: ../../superseded/architecture/2026-08-21-sliding-timeline-day-window.md
Superseded-by: —

## Problem

The seven-day lean index removed the one-day dead end, but its first refill
policy reacted to direction rather than missing data. A left delta shifted the
outer reserve older even while the pointer stayed in the centre day; reversing
shifted it newer again. Each shift fetched a day and then merged, sorted,
evicted, and rebuilt the full timeline while inertia was active. A normal
left-right gesture therefore paid repeated O(n log n) work despite already
having both visible directions in memory.

Capture timestamps also cannot prove that an empty day was queried. Inferring
coverage from the first and last row made sparse windows look perpetually cold.

## Decision

The store keeps explicit inclusive-start/exclusive-end local-day query
coverage, including empty days. Launch, NOW, and recenter still publish one
atomic D-3 through D+3 lean-index window. For the pointer's current local day,
D-2 through D+2 is the interaction invariant and D-3/D+3 is refill reserve.

Direction alone never changes that window. A scrub requests an outer day only
after its transient pointer enters a local day whose D-3...D+3 warm window is
not covered. The request carries that transient timestamp to the store, so
opposite-side eviction centres on what the user can currently see rather than
the settled binding from the preceding frame. Same-direction callers join the
in-flight fetch; if the pointer crossed another day meanwhile, the joined
caller refills the remaining miss after the first result.

An adjacent result is sorted, merged with the newest store snapshot, trimmed
to the pointer-centred window, indexed, and converted to `TimelineSpine` on a
worker. The MainActor sets coverage and publishes that prepared snapshot once.
It never publishes an expanded array and then a second filtered array. The view
observes a scalar revision and adopts the prepared spine; it does not compare
or sort the whole moment array during a scrub. A routine refresh may make the
worker retry against a newer snapshot; clear and recenter still cancel it.

Empty local days remain probed so sparse history is not a dead end. When the
next occupied day lies beyond the normal reserve, that fetched edge is retained
along with the pointer's five-day guarantee. The calendar span may exceed seven
days, but empty days add no rows and the retained occupied-day data stays
bounded.

The lean read model is unchanged: timeline ranges omit OCR and transcript
text; selected evidence still comes from `moment_get` and `evidence_ocr`.

## Alternatives considered

**Increase the edge distance.** More pixels do not stop direction reversals
from moving the cache, and no fixed lead time can guarantee a daemon round trip
at maximum inertia speed.

**Keep merge off-main but evict afterward on MainActor.** This still publishes
twice and makes the second full-window filter and layout rebuild land inside
the gesture.

**Load the whole archive.** It removes refills by making launch, payload size,
and layout cost grow without bound. The two-day invariant does not require it.

## Consequences

**Bought:** ordinary left-right movement inside a day performs no range I/O;
the pointer always consumes an already-queried two-day cushion; a real cross-day
refill does its O(n) merge and O(n log n) derived preparation off-main and
publishes once. Empty queried days no longer cause false refills.

**Cost:** the store and view exchange coverage, revision, and a prepared spine
as one logical snapshot. Sparse gaps can retain more than seven calendar days,
though not more occupied rows solely because those days are empty. Protocol 16
and the timeline-range payload are unchanged.
