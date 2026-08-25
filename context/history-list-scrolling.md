# History list scrolling

`DaySummaryPanel`'s list is windowed: only the rows intersecting the viewport
plus 600pt of overscan are mounted, and two spacers hold open the rest of the
document. This article is the record of three attempts that failed first, so
that the reasons stay attached to the code.

Code: `swift/AfterRayRecall/Sources/HistoryListScrollView.swift`,
`HistoryListVirtualization.swift`, `DaySummaryPanel.swift`.

## The shape of the data

A page is 7 days (`SummaryHistoryStore`, `limit: 7`), flattened by
`HistoryListItems.build` into one row per day heading plus one per visible slot
— roughly 90 rows a page. The first request always uses the daemon's newest
boundary (`before: nil`); later requests use only the cursor returned by the
preceding page. Timeline selection never seeds this document.

The document tail is one enum, not independent loading/has-more booleans:
loadable, loading, failed, or end. Near-bottom layout requests only a loadable
cursor; loading draws progress, failure draws Retry, and only end removes the
tail row. The boundary itself deduplicates calls, so no wall-clock throttle is
part of correctness. A page containing no panel-visible rows follows its next
cursor inside the same loading operation.

Row heights are not predictable: a card is a wrapped title plus a wrapped
description plus an optional icon strip. Two cards with the same fields can
differ by 150pt. Everything below follows from that.

## What makes windowing work, and what it needs

Any windowed list has to answer "what height is a row I have never laid out?"
with a guess, which means the model and the real document disagree until the
row is measured. The fix, which Telegram's `ListView` does in layout, is
**compensation**: when a measurement lands for a row *above* the fold,
everything on screen has just been pushed by that delta, so the scroll offset
moves by the same delta and the pixels stay put.

Compensation needs a **writable scroll offset**. That is the whole story of why
this took four attempts.

It converges because of one asymmetry: a row's height is only ever wrong before
its first measurement, and you only meet a row for the first time by scrolling
*toward* it — which puts it below the fold, where a correction moves nothing on
screen and needs no compensation. Measured heights never expire, so scrolling
back up is exact. Compensation is the rare case (a `follow()` jump into
unmeasured rows), not the steady state, which is why writing the offset does
not fight scroll momentum.

## The four attempts

**1. `LazyVStack`.** Unmounted rows contribute no document height. The scroll
bar believes the content is one screen tall and yesterday is unreachable even
though it is loaded.

**2. `NSScrollView` + `NSHostingView` per row.** `fittingSize` measures a
hosting view before it has a width, so a wrapped title reports as one line.
Rows lay out at ~60pt, each card is drawn on top of the previous one, and the
text visibly overlaps. (Fixable — constrain the width, then `sizeThatFits` —
but it was not the only problem.)

**3. Windowed, with spacers, on macOS 14 — this one shipped, and blanked the
screen.** No compensation was possible, so the estimate error compounded over
every row above the viewport. A 20% underestimate across 91 rows is enough to
push the real offset past the modelled content height; at that point no row
intersected the window, `visibleRange` fell through to a `(count-1)..<count`
fallback, **one row mounted and the viewport went blank.** It could not settle
either: mounting fewer rows shrinks the real document, which clamps the offset,
which selects a different window.

`HistoryListLayout.offsetDeltaAfterHeightChange` was written for the
compensation, with tests, and was wired to nothing — because it could not be.
That is worth remembering on its own: **the tests were green and the code was
dead.**

**4. Eager `VStack`.** Correct, and the right call at the time: the document
height is exact, so the sticky chip, the prefetch and playhead follow all stop
being approximations. It was replaced not because it was wrong but because the
constraint behind it turned out not to exist.

## The constraint that was not real

Attempt 3's post-mortem concluded "compensation is impossible, this target is
macOS 14". The target was wrong. AfterRay already required macOS 15 in every
place that mattered — `AfterRayCaptureShim` is built for it and screen capture
is the whole app, `docs/development.md` said so, and the site advertised
"macOS 15+" in both languages. Only `Package.swift` and `LSMinimumSystemVersion`
still said 14, which meant a macOS 14 user could install a build whose capture
shim would not launch.

Raising the deployment target was therefore not a product decision with a user
cost; it was making the manifest agree with what already shipped. It unlocked:

- `ScrollPosition.scrollTo(y:)` (macOS 15) — the writable offset. Compensation.
- `onScrollGeometryChange` (macOS 15) — read the offset without routing every
  scroll frame through a `PreferenceKey` and back into a body pass, which was
  the other half of why attempt 3 oscillated.
- `onGeometryChange` — measure a mounted row the same way.

`.macOS(.v15)` needs swift-tools 6.0, which also flips the default language
mode to Swift 6; `platforms: [.macOS("15.0")]` raises the target without that
migration.

The same discovery retired `Sources/ChatScrollObserver.swift`, a 134-line
`NSViewRepresentable` that hand-rolled the scroll signals SwiftUI ships
natively on macOS 15; chat now reads `onScrollGeometryChange` and
`onScrollPhaseChange` directly. Still outstanding: MarkdownUI could be replaced
by Textual, which additionally wants Swift 6 language mode (see
`AfterRayRecall/AGENTS.md`).

## Invariants

**`visibleRange` is total.** For a non-empty list it always returns a non-empty
range spanning the viewport, because the offset is clamped into the model
before it is mapped. An offset that has drifted past the content resolves to
the nearest real screenful. There is no degenerate fallback to fall into —
`HistoryWindowConvergenceTests` sweeps every offset from -2000 to 1.5x the
content height and asserts it.

**Spacers plus mounted rows equal the content height** at every offset, or the
scroll bar lies about how much is left. Also swept.

**Nothing in the height estimator may parse Markdown.**
`DaySummaryLayout.expandedSections` runs the card body through
`AttributedString(markdown:)` once per line — ~1.2ms a card. The estimator runs
over *every* loaded row on every pass (windowing bounds how many rows are
mounted, never how often the model is rebuilt), so reaching it from there cost
113ms a pass for 91 rows: seven frames of a 60fps budget. `estimateSlot`
answers every question from the shape of the data — `hasExpandableDetail`, a
newline count for the section guess — and estimates are memoized per key.

The same parse has now been reached by accident twice, from the estimator and
from `DaySummaryRow.sections`, which `body` touched *even when the card was
collapsed* just to decide whether to draw a "Full details" link. Both are
guarded: `HistoryWindowConvergenceTests.testEstimatingNinetyRowsDoesNotParseMarkdown`
and `DaySummaryRowBudgetTests`.

**Measured heights are keyed by `heightKey`, not `id`.** `id` is view identity
and must survive an expand/collapse toggle; an expanded card is hundreds of
points taller. Same for the loader, 8pt idle / 36pt busy.

That also means row count and identity cannot invalidate the mounted window on
expand/collapse. `HistoryListScrollView` observes the ordered height-key list;
when it changes, it recomputes the window and clamps the writable offset into
the new document height. Otherwise collapsing a tall card near the bottom can
leave the viewport beyond the shorter document until the user scrolls again.

## Scrubbing the timeline

The other way to pay 90x60 is to let a per-frame value into the panel at all.

`RecallStore.playheadMs` is republished on every frame of a timeline drag, and
`DaySummaryPanel` used to store it — along with a `nowMs` built from `Date()`
at the call site. Two stored properties differing every frame means the view
can never compare equal to its previous value. `highlightedSlotStart` was
worse: a computed property read from `isCurrent:` **once per row**, each read
scanning every day and allocating a filtered slot array. 3.7ms a pass on its
own.

Both are collapsed in `init` to values that change only when the panel would
look different:

- `highlightedSlotStart` — resolved once; changes when the playhead crosses a
  slot boundary, i.e. per half hour of recorded time, not per frame.
- `todayStartMs` — `DaySummaryLayout.dayStartMs`, local midnight. Only ever
  used to ask "is this day today"; a live clock was precision the panel never
  wanted and could not afford.

That is still not sufficient, because the closures the panel is constructed
with (`onSelectSlot`, `onLoadMore`, the `row:` builder) are new instances every
pass and defeat structural equality regardless. So the equality is declared
explicitly, at two levels:

- `DaySummaryPanel` is a shell whose `body` is
  `DaySummaryPanelContent().equatable()`. Across a scrub inside one slot the
  content compares equal on every frame, so SwiftUI skips the entire subtree —
  no `listItems` rebuild, no window recompute, no row construction, and no
  re-rasterising the glass and its 18pt shadow. Residual cost per frame: 4.1us.
- `DaySummaryRow` is `Equatable` on its data alone, so a pass that does get
  through only re-runs the rows whose `isCurrent` flipped.

`.equatable()` is safe only because neither row closure outlives its data —
`onSelect` captures `slot`, which `==` compares, and `onToggleDetails` captures
a slot start and writes through `@State`. Adding a closure that captures
something not in `==` would reintroduce stale behaviour silently.
`DaySummaryPanelScrubTests` pins the frame-stability.

### The seven-day window changes the equality budget

The pointer-centred D-3...D+3 window raised the normal real-vault dataset from
about 3,800 moments to about 26,000. That exposed a different per-frame linear
cost: SwiftUI's synthesized `TimelineLayout.==` compared the complete
`moments`, `runs`, and `favorites` arrays whenever the playhead changed. The
layout itself was cached, but copying the same value through the graph still
paid `RecallMoment.==` for the whole window. A Time Profiler trace named
`TimelineLayout.__derived_struct_equals` directly.

`TimelineLayout` now carries an immutable reference-identity token. Copies of
one built layout compare that token in O(1); independently built layouts fall
back to exact field and array equality, so equality semantics are unchanged.
Tests pin both the independent-build case and a non-geometric moment-field
change.

The continuous playhead also cannot live in the root `RecallView` state. It is
published by a leaf `RecallScrubState` observed only by the timeline, recalled
picture, and timestamp. The root sees begin/end and the rare live/history edge
transition. Prefetch, highlight, and text task ids stay constant for the whole
gesture, so a new selected moment does not cancel and rebuild their task graph
at display-link frequency.

The picture has a separate two-tier rule without reducing visual fidelity.
During motion it follows the transient moment with one full-resolution poster
per GOP, or the original full-resolution image for a loose still. One serial,
latest-wins player bounds daemon reads, VideoToolbox work, and IOSurface
submission instead of starting one task per display tick. After motion, that
sharp preview remains visible for a 250ms quiet period and until the exact Nth
frame settles underneath it. A reversal cancels the quiet-period task before
the exact decode starts. This matters because cancelling the outer Swift task
cannot interrupt a synchronous decode already inside VideoToolbox; starting
that decode after the old 75ms interaction settle caused 37-56ms gaps at the
start of the next flick.

Do not pre-decode full-resolution neighbours after settle. A cancelled outer
task cannot stop a detached VideoToolbox decode already in progress, so an
apparently idle prefetch can survive into the next gesture. The moving player
loads only its current/latest GOP poster; the exact settled frame is the only
full-resolution Nth-frame promotion.

Selection-only work has a separate 500ms quiet boundary. `moment_get` evidence
is stored beside the selected moment instead of replacing a row in the lean
timeline; it therefore does not increment the timeline revision or invalidate
the prepared spine. Adjacent-day maintenance and audio evidence run in the same
cancellable task, and the first movement frame cancels it. History summary
pagination is independent of this task and of pointer movement.

## Which display

This machine has a 60Hz screen and a 120Hz screen, and the budget is 16.7ms on
one and 8.3ms on the other. The same build measured "locked 60fps, zero dropped
frames" on the first and 37-80fps on the second, minutes apart. **Always record
which screen the window was on**; the perf line now reports `display=` and
derives `budget=` from the display link rather than a constant, so a number is
never quoted against the wrong target again.

On ProMotion, `preferred=120` is not a 120Hz request when the allowed range is
60...120Hz: the system may legally deliver a 16.7ms half-rate cadence. During
an active scrub the display link therefore pins minimum, maximum, and preferred
to the screen's native maximum (capped at 120Hz). It is paused as soon as the
gesture and inertia settle, so the high-rate request has no idle cost.

## Measuring it

Two `make` targets, because the two questions are different.

**`make profile-scrub`** — a reproducible scrub on fixtures.
`AFTERRAY_UI_PERF_AUTORUN=1` synthesises four flicks through the production
display-link and inertia path (not synthetic HID, which macOS rejects for
unsigned runners), so two runs are comparable. Release build; a debug build's
numbers are noise. `AFTERRAY_UI_PERF_LOG=1` prints frame intervals alongside
the trace. Pick the instrument with `TEMPLATE=`: `Time Profiler` for CPU
hotspots, `SwiftUI` for which bodies re-evaluate, `Animation Hitches` for
dropped frames and their cause, `Metal System Trace` for GPU. `LAB_ARGS=`
selects the fixture — `--stress` is a 20,000-moment timeline, adding
`--summary-stress` opens a week of summaries over it.

Numbers from a clean machine after the windowing and `.equatable()` work, three
interleaved reps of ~400 frames each, on a 120Hz display:

| | mean Hz | p95 interval | frames over 16.7ms |
|---|---|---|---|
| `--stress` | 119.6 / 119.2 | 8.33ms | 1 / 2 |
| `+ --summary-scrub` | 118.2 / 118.9 | 8.33ms | 4 / 3 |

So on fixtures the panel now costs a couple of frames in four hundred, and p95
sits on the vsync boundary either way. **Run reps and discard the first** — a
cold run measured 87.9Hz with 45 dropped frames purely from launch and build
contention, which is enough to invent a regression that is not there.

`handler_p95_ms` in that log is our scroll callback alone (~0.06ms). When it is
flat but the frame interval is not, the cost is downstream of the handler — in
the view update — and only the trace will say where.

Callback cadence is necessary but not sufficient. `AFTERRAY_UI_PERF_LOG=1`
also mounts a 1x1, non-interactive `TimelineCommitProbe` beside the timeline.
Its AppKit `updateLayer` reports `[afterray-ui-render]`: requests entering the
display-link path, values accepted by SwiftUI, and values reaching a Core
Animation update pass. Ordinary launches mount no probe. A run only proves the
100Hz target when substantive moving segments have `requests = updates =
commits` and the render-side Hz, not merely callback Hz, clears the threshold.

On the production-shaped 26,600-row Visual Lab fixture, the leaf-state and
O(1)-equality path measured 118.0-120.9 render commits/s. A signed real-vault
candidate then exposed two costs the fixture could not: neighbour GOP decoding
surviving cancellation, and selected OCR detail invalidating the whole prepared
timeline. After removing neighbour prefetch, isolating detail, deferring all
selection-only work, pinning the active ProMotion range, and restoring the
moving picture to a serial full-resolution GOP-poster path, three fresh
processes with four alternating flicks each measured
104.3/113.4/114.9/118.8Hz, 111.5/109.5/113.1/119.3Hz, and
111.9/113.1/113.1/119.3Hz. All twelve substantive segments had equal
request/update/commit counts; the synchronous handler stayed at 0.065-0.104ms
p95. Earlier candidates produced 37-56ms gaps or a 99.4Hz half-rate segment
even though that handler was already below 0.1ms.

**`make visual-lab-window-stress-profile`** covers the part the original 20K
fixture did not: publication of a neighbouring day while inertia is active.
The old `--stress` view passed no `onApproachTimelineEdge` callback, so its
~119Hz result proved only that an unchanged layout was cheap. It could not
exercise the production hitch.

The window fixture holds 3,800 lean rows per local day. Its initial D-3...D+3
query therefore publishes 26,600 rows, matching the shape of a real seven-day
vault window. It starts 30 minutes before midnight, alternates four flicks so
the pointer crosses the boundary in both directions, waits 60ms for each mock
range request, and routes the result through the real `RecallStore` merge,
trim, prepared-spine, and `RecallView` adoption path. On the 120Hz display after
the pointer-centred refill change, three four-segment reps measured
120.0/108.6/120.0/117.4Hz, 120.0/111.1/120.0/118.9Hz, and — on the final code —
106.0/114.3/120.0/120.0Hz. Unified logs confirmed one 26,600-row initial range
and four 3,800-row neighbour ranges. Worst p95 interval was 20.83ms and handler
p95 stayed near 0.1ms. Every segment cleared the 100Hz regression threshold.
This is a repeatable code-path gate, not a substitute for `make profile-app` on
the real vault.

**`make profile-app`** — attach to the running app on the real vault, which is
what the fixtures are not. Start it with `make dev`, run the target, scrub
during the window. No entitlement work: the dev bundle is ad-hoc signed with no
hardened runtime, so Instruments attaches. A release build is hardened and
would have to be re-signed with `get-task-allow` first — do not add that to
`Automation.entitlements`, which release shares.

For a signed release candidate, launch the installed app through LaunchServices
with the opt-in driver instead of synthesising HID input:

```sh
open \
  --env AFTERRAY_UI_PERF_LOG=1 \
  --env AFTERRAY_UI_PERF_AUTORUN=1 \
  --env AFTERRAY_UI_PERF_AUTORUN_REVERSE=1 \
  --env AFTERRAY_UI_PERF_AUTORUN_DELAY_MS=3000 \
  /Applications/AfterRay.app
```

Quit the existing process first so LaunchServices creates a process with those
variables. After permission reconciliation and the initial warm timeline load,
the app orders the otherwise parked overlay front only for this explicit run;
the driver then uses the real display link, store, daemon, and vault. Waiting
until bootstrap finishes is required because bootstrap temporarily parks the
overlay around macOS permission checks. The opt-in run also keeps the overlay
visible if the launching harness retakes key focus before the delayed driver
starts; ordinary launches retain the normal resign-to-hide behaviour. Read the
result with `make perf-log`; ordinary launches remain parked.

One trap that cost an hour: `print` to a pipe is block-buffered, and a
profiling run ends by killing the process at its time limit, so the perf line
was written and discarded. `ScrubFrameMetrics.finish` now `fflush`es. Anything
else that reports from a killed process needs the same.

## What a scrub actually costs

Measured on the real vault, one recording with the panel toggled halfway
(`make profile-app RUN=ab PROFILE_SECONDS=24s`, then `make profile-frames`):

| | frames | CPU per frame p50 | p95 |
|---|---|---|---|
| panel open | 25 fps | 36 ms | 80 ms |
| panel closed | 29 fps | 24 ms | 64 ms |

After collapsing accessibility (same machine, same zoom):

| | frames | CPU per frame p50 | p95 |
|---|---|---|---|
| panel open | 37 fps | 17 ms | 56 ms |
| panel closed | 39 fps | 10 ms | 41 ms |

Accessibility no longer appears in the closed-phase hot list at all; what is
left there is layout (`LayoutEngineBox.sizeThatFits`) and graph traversal.

The budget is 8.3ms at 120Hz. Both are far outside it: **the panel is not the
problem, it is a 8.7ms surcharge on a frame that was already 24ms.**

Two things this corrected:

**CPU% is the wrong metric.** The main thread reads ~80% busy in both
configurations, because it is saturated either way. It cannot distinguish them.
Frames can.

**Symbol attribution understates a view's cost.** AfterRay's own symbols are
~2% of main-thread time in every trace, which looks like "our code is free".
But `.equatable()` means our bodies do not re-run — what the panel costs is
SwiftUI walking the nodes it contributed, and those stacks carry no AfterRay
frames at all. The cost is real and invisible to a symbol list. Compare
per-frame totals between configurations instead.

### Where the time goes

Of a 24ms baseline frame, ~9.9ms was accessibility:

```
9.86ms  AccessibilityViewModifierAccessor.updatedAttachment(modifier:for:nodes:)
9.64ms    AccessibilityGestureModifier.initialAttachment(for:)
9.35ms      AccessibilityNode.visibility.getter        <- 3671ms of the 3966ms
```

Attachments are rebuilt on every AttributeGraph update, and each rebuild walks
the node's ancestors to decide whether it is visible. Cost is
nodes x depth x frames. The largest node source was a `.help` tooltip applied
per visible run inside the timeline's `ForEach` — several hundred attachments,
every frame. It is gone; the track is one `accessibilityElement(children:
.ignore)` with a label and a value, which is the right way to expose a scrubber
anyway. Summary rows are `.ignore`d for the same reason, with the label stated and
the two actions restated.

**`.ignore`, never `.combine`.** Both present one element. `.combine` gets
there by visiting every descendant and merging their properties, which is the
walk it was supposed to remove plus merge work on top — measured at +2.9ms a
frame on the rows, the largest single item in what the panel added. `.ignore`
does not look at the children, which is why it has to be given a label.

If the tooltip comes back it must be a single overlay driven by the hovered
run, never a modifier inside the loop.

Why a few hundred items can cost this much: the track virtualizes to one
screen plus 192pt, but `minimumSegmentWidth` is 5pt, so a zoomed-out screen
holds ~300 runs — and a run was ~15 graph nodes, including two `@State`s and a
`.task` to resolve its app colour. ~4500 nodes, each checked with an O(depth)
ancestor walk, on a tree that is easily 100 levels deep, is ~9ms. It is
nodes x depth, not node count, and that is why "only 300 items" is misleading.

`AppUsageSegmentView` is now a pure value view — no `@State`, no `.task`,
`Equatable`, mounted `.equatable()` — and the colour cache is warmed once per
distinct app by the parent (`warmPalette`, keyed on the dataset, not the
layout). Pixels are unchanged. Drawing the track into a `Canvas` would remove
the nodes outright but costs the material, gradients and icons; it is not
worth that.

### Reading a trace

`make profile-frames` over `scripts/analyze-frames.py`. Three traps, each of
which silently produces confident nonsense:

- xctrace's XML interns repeated elements: a `<frame>`, `<binary>`, `<thread>`,
  `<backtrace>` or `<sample-time>` may be a `ref=` to an earlier definition.
  Resolve every one, including for rows you are filtering out — a later row's
  ref may point at an id first defined by a row you skipped.
- the stack is under `<tagged-backtrace><backtrace>`, not on `<row>`.
- when splitting frames on contiguous `CA::Transaction::commit` runs, tolerate
  **no** gap. The main thread is inside commit ~90% of the time, so a 2ms
  tolerance merges adjacent frames and reports a third of the real rate (10fps
  instead of 28).

A `.trace` bundle embeds the recorded process's full environment, including any
API tokens. Never share one.
