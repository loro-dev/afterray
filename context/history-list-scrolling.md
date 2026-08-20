# History list scrolling

`DaySummaryPanel`'s list is windowed: only the rows intersecting the viewport
plus 600pt of overscan are mounted, and two spacers hold open the rest of the
document. This article is the record of three attempts that failed first, so
that the reasons stay attached to the code.

Code: `swift/AfterRayRecall/Sources/HistoryListScrollView.swift`,
`HistoryListVirtualization.swift`, `DaySummaryPanel.swift`.

## The shape of the data

A page is 7 days (`RecallStore.loadOlderSummaryHistory`, `limit: 7`), flattened
by `HistoryListItems.build` into one row per day heading plus one per visible
slot — roughly 90 rows a page. Pages only arrive when the user scrolls to the
bottom.

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

**`make profile-app`** — attach to the running app on the real vault, which is
what the fixtures are not. Start it with `make dev`, run the target, scrub
during the window. No entitlement work: the dev bundle is ad-hoc signed with no
hardened runtime, so Instruments attaches. A release build is hardened and
would have to be re-signed with `get-task-allow` first — do not add that to
`Automation.entitlements`, which release shares.

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
