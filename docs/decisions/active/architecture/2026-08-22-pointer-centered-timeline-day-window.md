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
That detail is a separate selected-moment snapshot. It never replaces a row in
the timeline array, increments its revision, or invalidates `TimelineSpine`.
Otherwise one OCR response would turn into an O(n) row search followed by a
full derived-layout rebuild just before the next gesture.

Continuous scrub presentation is leaf-scoped. The root recall surface observes
only begin/end and the live/history edge; a dedicated scrub state publishes the
per-frame playhead and frozen layout directly to the timeline, timestamp, and
recalled-picture leaves. Copies of one prepared `TimelineLayout` compare by an
immutable identity token in O(1), while independently built layouts retain
exact equality. This is required because the seven-day window contains about
26,000 moments on a real vault; synthesized array equality at 120Hz would turn
the warm-data guarantee itself into a rendering regression.

Pixel fidelity is not reduced at the interaction boundary. While the pointer
moves, one serial latest-wins player shows a full-resolution poster shared by
the current GOP, or the original full-resolution loose still. It never fans
out one daemon read, VideoToolbox decode, or IOSurface submission per display
tick. The sharp preview remains until 250ms of quiet and until the exact Nth
frame settles underneath it. A new gesture cancels that exact promotion before
it starts; cancellation after synchronous VideoToolbox decode has begun is not
considered a sufficient performance control. Full-resolution neighbour
prefetch is not performed: it could leave a decode running after cancellation
and compete with a later scrub. Evidence, summary, adjacent-day maintenance,
and audio prefetch wait for 500ms of quiet; the next gesture cancels their
shared task before it can publish.

While movement is active, the display link requests one fixed rate equal to the
current screen's native maximum, capped at 120Hz. A 60...120Hz range allowed
ProMotion to choose 60Hz during otherwise cheap segments. The link still pauses
at idle, so this is not a permanent high-refresh request.

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

Continuous playhead publication is O(1) with respect to the loaded window and
does not invalidate the root overlay. The signed real-vault regression gate
measures actual Core Animation layer updates, not just display-link callbacks;
after removing competing selection work, pinning the active ProMotion range,
and restoring full-resolution moving posters, three fresh-process repetitions
on a 120Hz display held every substantive segment above 100Hz (104.3-119.3Hz),
with request, state-update, and layer-commit counts equal in every segment.

**Cost:** the store and view exchange coverage, revision, and a prepared spine
as one logical snapshot. Sparse gaps can retain more than seven calendar days,
though not more occupied rows solely because those days are empty. Protocol 16
and the timeline-range payload are unchanged. During motion the recalled image
is a full-resolution GOP poster rather than the exact Nth frame; the exact
frame is promoted after the user has been still for 250ms. Selection metadata
may appear after the longer 500ms quiet boundary rather than competing with
movement.
