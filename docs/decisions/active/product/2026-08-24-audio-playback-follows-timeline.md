# Decision: Audio playback follows capture frames without becoming user travel

Status: active
Area: recall-ui
Anchors:
- swift/AfterRayRecall/Sources/AudioTimelineFollow.swift @dec:audio-playback-follows-timeline
- apps/AfterRay/Sources/AfterRayApp.swift @dec:audio-playback-follows-timeline
Supersedes: —
Superseded-by: —

## Problem

Audio time, selected timeline time, and the recalled screenshot are separate
clocks. Leaving the playhead fixed while audio advances presents speech against
an unrelated old frame. Driving the root with every media-clock sample would
restore the high-frequency invalidation that makes timeline travel slow.

User travel has different ownership from playback travel. A user gesture means
the selected audio source is stale and must be discarded; an automatic frame
advance must keep that source alive.

## Decision

Explicit playback owns one immutable source moment, artifact, and offset. Its
media time maps to wall time as `source captured time + currentTime - offset`.
The client resolves the last capture at or before that time with binary search
over the loaded lean timeline and advances the committed playhead only when the
resolved moment changes. It does not cross a capture session or hold a frame
through an idle gap.

Timeline travel carries an explicit origin. User travel stops playback,
cancels its generation, releases the decoder, and overwrites the retained
decrypted buffer before selection moves.
Audio-playback travel keeps the immutable source and changes only its followed
presentation moment. Pause and resume therefore continue the source even after
the background has advanced to a later capture.

The media clock remains an unpublished leaf read. The follower sleeps toward
the next capture boundary, capped at 250ms for cancellation and decoder drift,
and publishes only when a capture-frame identity changes. Selected evidence,
OCR highlights, and selectable text do not hydrate while playback is advancing.

The caption uses the source segment's exact transcript rather than whichever
followed capture is on screen. Playback launches its own generation- and
segment-guarded detail read because automatic following suppresses ordinary
selection hydration. The visible window follows the media-clock position even
while paused or between cues; highlighting is a separate state and appears
only while an aligned/coarse cue is actually playing.

## Alternatives considered

**Publish media time into the root at 12Hz.** This keeps the playhead visually
continuous, but rebuilds the recall hierarchy independently of capture-frame
boundaries and competes with image presentation.

**Keep the recalled frame fixed during playback.** This avoids timeline writes,
but presents later audio against the initial screenshot and timestamp.

**Treat automatic movement as an ordinary selection.** This reuses fewer APIs,
but stops the audio on its own first frame and starts selected-evidence work for
every capture the playback passes.

**Switch to the next search result while search is open.** Search results are
ranked discrete matches, not consecutive capture frames. Playback follows wall
time in the loaded timeline while the filmstrip keeps its selected search hit.

## Consequences

Audio, timestamp, playhead, and recalled screenshot advance together at capture
cadence without a high-frequency root clock. User input always wins and removes
the old media source immediately. The timestamp advances in capture increments,
not continuously between screenshots. Aligned sentence highlighting follows
the media clock; transcripts still awaiting alignment remain visible without a
spoken-now highlight.
