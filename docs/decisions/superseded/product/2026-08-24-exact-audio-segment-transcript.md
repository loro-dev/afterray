# Decision: Transcript and playback share one exact audio segment

Status: superseded
Area: recall-ui
Anchors:
- —
Supersedes: ../../superseded/product/2026-08-24-audio-chrome-without-asr.md
Superseded-by: ../../active/product/2026-08-24-forced-aligned-audio-transcript-cues.md

## Problem

A moment selected its audio artifact and its transcript through independent
queries. Artifact selection preferred one overlapping system-audio segment,
while transcript selection concatenated every system and microphone segment
covering the timestamp. The UI could therefore play one source while showing
text from several sources. It also lacked segment end metadata, so an idle
caption could only hand the whole transcript blob to SwiftUI or decode audio
just to learn its duration.

## Decision

Every moment read selects one audio segment that actually covers its timestamp.
Its segment id, artifact id, start, end, and transcript all derive from that
row. Transcript lookup is by
the selected segment id and returns at most that segment's evidence; it never
concatenates transcripts from overlapping tracks. Lean timeline ranges keep
the exact segment pointer and bounds but still omit transcript and OCR text.
The hydrated `moment_get` uses the same selection function and adds only the
matching transcript.

Protocol 17 adds optional `audio_segment_id` and `audio_ended_at_ms` fields to
the existing additive Moment shape. Swift constructs an audio presentation
segment only when id, artifact, start, and end are all present. Selected-detail
hydration overlays that segment atomically rather than mixing individual audio
fields from lean and detailed rows.

The segment bounds provide caption duration without reading or decoding audio.
The caption maps only the exact segment transcript, discards estimated cues
before the selected offset, and renders a three-sentence window around the
active cue. Incomplete legacy or fixture metadata is limited to the first
three sentences instead of becoming one unbounded SwiftUI text value.

Audio chrome remains available when the exact segment has no transcript or ASR
is unfinished. Explicit playback owns one segment and stops at its artifact
end; automatic capture-frame following changes the presented screenshot but
does not swap the source. User travel still stops and unloads that source as
defined by
[2026-08-24-audio-playback-follows-timeline.md](../../active/product/2026-08-24-audio-playback-follows-timeline.md).

## Alternatives considered

**Keep artifact and transcript as independent flat lookups.** This preserves
the previous wire shape but cannot guarantee that the words describe the
sound being played when system and microphone segments overlap.

**Concatenate both tracks and mix their audio for playback.** This could make
the combined transcript defensible, but changes playback semantics, requires
mixing and synchronisation, and makes speaker attribution less clear.

**Decode the selected artifact to discover caption duration.** This gives an
exact media duration, but turns selection into encrypted artifact I/O and
decoder setup. Persisted segment bounds already supply the required metadata.

**Cut captions at every screenshot boundary.** Screenshots are presentation
samples rather than speech boundaries. A sentence commonly spans several
captures, so clipping there would make text flicker and truncate speech.

## Consequences

The visible words, progress range, and played bytes share one auditable source.
Ordinary timeline movement remains metadata-only, and a selected transcript is
bounded to one capture segment rather than all overlapping tracks. Segment
timestamps and ASR text still provide only estimated sentence timing; word
highlight boundaries are not exact. Protocol 17 requires the app and daemon to
upgrade together, as the existing strict handshake intends.
