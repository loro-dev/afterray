# Decision: Forced-aligned cues refine the exact audio transcript

Status: active
Area: recall-ui
Anchors:
- crates/afterray-store/src/lib.rs @dec:forced-aligned-audio-transcript-cues
- crates/afterray-infer/src/align.rs @dec:forced-aligned-audio-transcript-cues
- crates/afterrayd/src/main.rs @dec:forced-aligned-audio-transcript-cues
- crates/afterray-protocol/src/lib.rs @dec:forced-aligned-audio-transcript-cues
- swift/AfterRayRecall/Sources/RecallModels.swift @dec:forced-aligned-audio-transcript-cues
- swift/AfterRayRecall/Sources/ArtifactAudioPlayer.swift @dec:forced-aligned-audio-transcript-cues
- swift/AfterRayRecall/Sources/RecallView.swift @dec:forced-aligned-audio-transcript-cues
- apps/AfterRay/Sources/AfterRayApp.swift @dec:forced-aligned-audio-transcript-cues
Supersedes: ../../superseded/product/2026-08-24-exact-audio-segment-transcript.md
Superseded-by: —

## Problem

The exact-segment design made played bytes and displayed text come from the
same audio row, but ASR still persisted one text blob with only segment-wide
bounds. Dividing that blob by character count produced a useful nearby caption
window, but it could not truthfully say which sentence was being spoken.
Highlighting those estimates also covered pauses and drifted on long segments.

Replacing the timeline lookup with audio decoding would fix neither problem
and would reintroduce expensive artifact I/O into pointer movement. Historical
vaults also need to gain timestamps without making their already-readable
transcripts disappear while a model pack downloads or a worker retries.

## Decision

Every moment continues to select one exact covering audio segment. Lean
timeline reads carry only that segment's id, artifact id, and bounds; they do
not load transcript text or timestamp cues. `moment_get` adds the matching
transcript and its bounded cue rows by segment id.

Audio processing has two durable stages on the same ASR compute lane:

1. Qwen3-ASR writes the full transcript and detected language first.
2. Qwen3-ForcedAligner-0.6B aligns that known text against the same audio and
   writes sentence-sized relative start/end offsets.

The stages have independent state, attempts, errors, and retry clocks. A
missing or failed aligner never rolls back text. Schema 27 marks existing
transcripts as alignment backlog, completed silent segments as `not_needed`,
and stores cues in `transcript_cues` keyed by `(audio_segment_id, ordinal)`.
The aligner pack is a SHA-256-pinned required model snapshot. Download repair
requeues failed alignment work as well as failed transcription work. Pending
alignment stays unclaimed and encrypted while that pack is absent; download
completion wakes the sweeper after the model is present.

Protocol 18 adds `transcript_cues` to the additive `Moment` shape. Cue offsets
are milliseconds from the audio segment start and carry an explicit timing
kind. Swift uses binary search over ordered cues, highlights only when playback
falls inside an aligned/coarse interval, and leaves inter-sentence silence
unhighlighted. Older or not-yet-backfilled text may still be split into at
most a three-sentence estimated window, but estimated cues are never presented
as currently spoken. Container padding may clip only the end of a final cue;
overlapping or wholly out-of-range model cues fail refinement instead of being
moved or merged into a fabricated interval.

Explicit playback owns one immutable audio source. Automatic playback travel
may advance the screenshot and playhead without replacing that source; a
generation- and segment-guarded detail read is launched by playback itself and
may refine its caption evidence in place. It does not depend on selected-row
hydration, which automatic following deliberately suppresses. User-driven
timeline or search travel still stops and unloads the source before selection
moves.

## Alternatives considered

**Ask ASR itself for sentence timestamps.** The shipped Qwen3-ASR interface
returns text and language, not stable sentence/word timings. Treating decoder
token positions as media time would preserve the same false precision.

**Run forced alignment before committing the transcript.** This makes a
secondary model failure hide useful text and forces history, search, and T2 to
wait for presentation metadata they do not need.

**Decode audio during timeline lookup.** User travel needs only the subtitle
pointer and whether audio exists. Artifact decryption, media decoding, and
model work stay in background workers, never on the timeline range path.

**Store one cue per ASR character or word.** It gives more rows and UI churn
than the three-line caption needs. The worker keeps the model's detailed
alignment in memory and persists bounded sentence-sized cues instead.

## Consequences

Subtitle highlighting now makes an exact, testable claim against media time,
including no claim during silence. Historical transcripts remain immediately
readable and are refined asynchronously. Detail lookup is indexed by segment
and cue start; timeline scrubbing remains metadata-only.

Stopping, changing source, hiding recall, or suspending the system releases the
decoder and explicitly overwrites the app-owned decrypted audio buffer. Pause
keeps that buffer only so resume does not decrypt or seek the artifact again.

The required local model footprint grows by roughly 1.84 GB. Alignment uses a
CPU/Accelerate worker after the Metal ASR worker exits, so it does not keep two
large inference models resident in one process. Unsupported or misdetected
languages remain visible as unhighlighted transcript text and retry with the
durable alignment failure policy until the model or metadata is repaired.

When overlapping tracks differ in transcript availability,
[2026-08-24-transcribed-audio-track-preferred.md](2026-08-24-transcribed-audio-track-preferred.md)
narrows the exact-segment selection rule without weakening source coupling.
