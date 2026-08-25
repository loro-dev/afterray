# Decision: A transcribed covering audio track is preferred

Status: active
Area: recall-ui
Anchors:
- crates/afterray-store/src/lib.rs @dec:transcribed-audio-track-preferred
Supersedes: —
Superseded-by: —

## Problem

A capture session may contain overlapping system and microphone audio. Keeping
the played artifact and displayed transcript on one exact segment prevents
source mismatch, but an unconditional system-track preference hides useful
speech when system ASR returns no text and the covering microphone segment has
a transcript.

## Decision

Moment reads prefer covering audio segments with durable, non-empty transcript
evidence. When multiple candidates have the same transcript availability,
system audio remains preferred over microphone audio, followed by the latest
segment start.

The selected segment remains atomic: its artifact, bounds, transcript, and
timestamp cues travel together. A microphone transcript is never displayed
over system-audio playback. Lean timeline reads still omit transcript content
and cues; their selection uses only an indexed transcript-existence lookup and
audio metadata, without artifact decryption or decoding.

Explicit playback keeps its immutable source until it stops. A transcript that
arrives while playback is active therefore affects a later selection or detail
refresh, not the bytes already being played.

## Alternatives considered

**Display any covering transcript while keeping system playback.** This shows
more text, but the words may describe a different recording than the sound the
user hears.

**Always prefer microphone audio.** This fixes the observed empty system-track
case while hiding a better system recording whenever both tracks contain
speech.

**Keep system priority even when it has no transcript.** This preserves the
old default but makes a successfully transcribed covering track invisible.

## Consequences

Useful subtitles remain visible whenever a covering track has transcript
evidence, while playback and caption timing retain one auditable source. If
both tracks have text, system audio still wins; if neither has text, the audio
chrome keeps its system-first fallback.

Each moment selection performs an indexed existence check for the few covering
audio candidates. Pointer movement still reads no transcript bodies, cues, or
audio bytes.
