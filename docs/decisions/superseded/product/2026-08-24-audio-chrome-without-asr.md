# Decision: Audio chrome is available before ASR finishes

Status: superseded
Area: recall-ui
Anchors:
- —
Supersedes: —
Superseded-by: 2026-08-24-exact-audio-segment-transcript.md

## Problem

The lean timeline already carries an audio artifact for an overlapping moment,
but the recall overlay made both playback and prefetch conditional on non-empty
ASR text. Audio remains invisible while transcription is pending, fails, or
hydrates after the selected moment settles.

## Decision

A historical selected moment with an audio artifact presents playhead audio
chrome whether or not it has ASR text. The waveform control sits above the
centred timestamp and starts playback at the selected moment's offset. Live
and active-scrub states remain quiet.

When ASR is present, the client splits it into sentences and maps those
sentences across the artifact duration available after explicit playback.
It keeps speech that overlaps or follows the selected offset and highlights
the active sentence only while playing. This is a character-weight estimate
because stored ASR has segment bounds and one text blob, not word timings.
Before playback supplies a duration, the selected transcript stays visible as
one idle cue. Transcript-only moments retain the existing caption.

Selection is a metadata-only path: the lean row supplies whether audio exists,
and the settled `moment_get` supplies transcript text. Selection, search travel,
and timeline scrubbing never read, decrypt, cache, or decode audio artifacts.
Only an explicit play action uses the no-cache audio repository. Audio bytes
never enter the screenshot/GOP cache.

A playback source is `(moment id, artifact id, offset)`, not artifact id alone.
Pause/resume keeps that exact transport source. Automatic playback following
may present a later capture without replacing it. Any user-driven timeline or
search movement stops playback, cancels its generation, and unloads the player
before changing selection. Playback progress is read by the leaf audio chrome;
it is not published into the recall root on a timer. Automatic frame-following
is governed by
[2026-08-24-audio-playback-follows-timeline.md](../../active/product/2026-08-24-audio-playback-follows-timeline.md).

## Alternatives considered

**Wait for ASR before showing playback.** This is the former behavior and
keeps the chrome text-led, but it hides captured audio precisely when ASR is
delayed or unavailable.

**Prefetch and decode audio duration after selection settles.** This can trim
the idle caption before playback, but turns a metadata lookup into whole-file
I/O, decryption, socket copying, and decoder setup. Cancellation also cannot
undo daemon work already dispatched, and a shared cache lets audio evict scrub
frames.

**Add browsable audio markers to the global timeline.** This could make audio
discoverable away from the selected moment, but expands the interaction scope
beyond selected-moment playback.

**Add word timings to the wire protocol.** This would improve highlight
precision, but the current vault format does not contain them and a protocol
change is not needed to surface available audio.

**Render real PCM waveforms.** This would represent the sound more faithfully,
but requires another decode path; deterministic decorative bars keep the
control responsive and visually stable.

## Consequences

Audio becomes actionable before ASR completes without adding media work to
timeline travel. The idle caption may show the selected segment's whole text
until playback provides its duration; sentence filtering and highlighting then
become approximate and may not match a speaker's exact word boundary. Changing
the selected moment intentionally discards pause/resume state, even when the new
moment overlaps the same underlying audio artifact.
