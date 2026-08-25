# Decision: Search evidence settles once and audio prepares off the UI actor

Status: active
Area: recall-ui
Anchors:
- swift/AfterRayRecall/Sources/RecallView.swift @dec:settled-search-evidence-and-off-main-audio-prepare
- swift/AfterRayRecall/Sources/RecallAudioRepository.swift @dec:settled-search-evidence-and-off-main-audio-prepare
- apps/AfterRay/Sources/AfterRayApp.swift @dec:settled-search-evidence-and-off-main-audio-prepare
Supersedes: —
Superseded-by: —

## Problem

Search results can span many local-day timeline windows. Opening every result
crossed by a trackpad gesture turns discrete selection into overlapping
`moment_get`, timeline recenter, summary, and evidence work. Cancellation after
those requests have started does not make the spent I/O or preparation free.

Explicit audio playback reads its artifact asynchronously, but copying the
decrypted buffer and constructing and preparing `AVAudioPlayer` on the UI actor
can still delay the next interaction.

## Decision

Search motion updates the selected result and immediately presents a lean row
only when that row is already in the loaded timeline. An unloaded result does
not open a timeline window during movement. After 500 milliseconds of quiet,
one SwiftUI-owned, cancellation-aware task opens and hydrates the final result.
Its identity includes the selected search result even when the displayed
timeline row or its ordinal has not changed. Superseded `openMoment` work checks cancellation
before publishing a fetched detail or prepared timeline.

Subtitle text and cue rows continue to arrive through indexed `moment_get`;
search movement never reads audio artifact bytes. Explicit playback sends the
artifact bytes to `RecallAudioRepository`, whose actor copies the sensitive
buffer and constructs and prepares `AVAudioPlayer`. The MainActor receives a
prepared player, publishes playback state, and performs lightweight transport
operations. Cancelled prepared players and released sensitive buffers are
erased by the audio actor rather than by the scrolling actor.

## Alternatives considered

**Open every crossed result and rely on task cancellation.** This starts work
before the next gesture event can cancel it, and daemon requests or synchronous
media preparation may already be underway.

**Never present loaded results during movement.** This gives every search hit
the same deferred behavior, but needlessly makes an in-memory dictionary lookup
and already-warm frame feel less direct.

**Move all player operations away from MainActor.** Playback state feeds
SwiftUI and delegate callbacks. Keeping play, pause, and published ownership on
MainActor is simpler; only artifact I/O, copying, parsing, preparation, and
buffer erasure are potentially heavy.

## Consequences

One search gesture performs at most one non-cached timeline open and one
subtitle hydration after it settles. Warm results can still update immediately.
Audio decoding cannot block search travel, and user travel still invalidates
the previous generation before the final result loads.

The canvas may keep the last warm frame while the filmstrip moves across cold
results; the final frame appears after the quiet boundary and its I/O. A failed
resume rebuilds through the audio actor instead of retrying synchronously on
the UI actor.
