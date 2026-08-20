# Decision: Search results hide the timeline zoom strip

Status: active
Area: recall-ui
Anchors:
- swift/AfterRayRecall/Sources/RecallView.swift @dec:search-filmstrip-hides-timeline-zoom
Supersedes: —
Superseded-by: —

## Problem

Search replaces the continuous app-usage timeline with an equal-width filmstrip
of discrete matched frames. Timeline zoom changes the density of time-based runs,
but it cannot change the search filmstrip. Showing its drag strip in search mode
therefore presents an enabled control that has no visible effect.

## Decision

The timeline zoom strip is present only when `RecallView` shows the ordinary
app-usage timeline. A non-nil `searchSession` hides it for the whole lifetime of
the search filmstrip. The rest of the chrome row, including recording state,
the day-summary control, and the centred playhead timestamp, remains available.

## Alternatives considered

**Keep the zoom strip visible but disable it.** This still spends space on a
timeline-only concept while search results are on screen, and a disabled strip
does not help navigate the discrete result set.

**Hide the entire chrome row in search mode.** That would also remove controls
and timestamp context that remain meaningful while moving between results.

## Consequences

**Bought:** every visible control in the search-results chrome affects the
content being shown, and the filmstrip gets a quieter header.

**Cost:** the zoom level cannot be adjusted until search is dismissed. Its
stored value is untouched and applies again when the ordinary timeline returns.
