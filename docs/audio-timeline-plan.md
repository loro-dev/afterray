# Plan: Timeline audio waveform + ASR caption

> **状态（2026-08-25）：本地实现和验证完成，尚未合入。** 行为以代码和对应 active decision 为准。
>
> 本文保留诊断、视觉验收和架构演进过程，方便回归。

Status as of 2026-08-24 (local, uncommitted):

| Phase | Status |
|---|---|
| 0 Diagnose why audio is invisible | Done (see below) |
| 1 Public component + fixtures + unit tests | Done |
| 2a Isolated `audio-chrome-*` snapshot scenes | Done |
| 2b ≥3 screenshot → look → skill review → fix rounds | Done — final verdict `Approve` |
| 2c Visual Lab `--audio` | Optional; skipped (static PNGs were sufficient) |
| 3 Gate fix + mount in `RecallView` | Done |
| 4 Decision record + docs | Done |
| 5 Durable forced-alignment timestamps | Done — schema 27 / protocol 18 |
| 6 Search-settled evidence + off-main audio preparation | Done |

---

## Why audio history was invisible before phase 3

AfterRay **does capture and store** audio (`audio_segments` + encrypted artifacts). Protocol 18's lean timeline attaches one exact covering `audio_segment_id` plus its artifact/start/end metadata. There is **no browsable audio-history list**. Audio only appears as a **selected-moment** caption / details play control.

The original symptom came from **UI gates**, not missing vault data:

1. **Caption requires non-empty ASR text** — `TranscriptCaption` mounts only when `selectedMoment?.hasVisibleTranscript == true` (`swift/AfterRayRecall/Sources/RecallView.swift` ~486–489). Audio-only moments (ASR pending / failed / empty) show **zero** play affordance.
2. **Play / spacebar / prefetch also require transcript** — same dual gate in the details menu, space key, and app prefetch (`apps/AfterRay/Sources/AfterRayApp.swift` ~1585, ~1643).
3. **Lean timeline nulls `transcript_text`** — text arrives only after ~500ms settle + `moment_get` hydrate. Until then the caption cannot appear even when the audio pointer is already on the index row (`crates/afterray-store/src/lib.rs` `query_moment_index`).
4. **Live / scrubbing** hide the caption.
5. Secondary: record-audio off, audio exclusions, near-silent discard, ASR backlog.

So “看不到音频记录历史” is: **we only surface audio when ASR text exists**, and never as a timeline-level marker.

---

## Product intent

When the selected moment has audio:

1. Show a **waveform-feel play control above the playhead timestamp** (`ScrubPlayheadTimestamp` / `PlayheadTimestamp` in `timelineChromeRow`).
2. Click plays audio **from that moment’s offset** (`ArtifactAudioPlayer.offset(for:)` already does this).
3. If ASR exists, show caption **from this moment forward** (not the whole prior segment), and **highlight the currently speaking sentence** while playing.

---

## Hard rules (do not skip)

1. **Do not mount this chrome in `RecallView` until the snapshot loop reaches `Approve`.** Code-only review is not acceptance.
2. Iteration snapshots render the **pure public component** on a dim stage (fake timestamp + fake timeline strip). They must **not** go through `RecallView`, the daemon, or Visual Lab chrome. Existing full-app `captionScenes` are a later regression, not the design loop.
3. Visual Lab is for a human with a mouse. Agent self-QA is **offscreen PNGs** via `afterray-visual-snapshots`, then `read_file` on those PNGs (multimodal), then skills, then another render.
4. Minimum **three** render → look → fix cycles even if round 1 looks fine.
5. Read every `AGENTS.md` from repo root to the file you edit. Grep touched files for `@dec:` before changing behavior. Decision records go under `docs/decisions/` in the same change as the gate change (phase 3).

---

## What is already in the tree (phase 1 + 2a)

These files exist in the working tree. Treat them as a first draft, not finished UI.

| File | Role |
|---|---|
| `swift/AfterRayRecall/Sources/AudioMomentTranscript.swift` | Sentence split, cue mapping onto segment duration, active index, decorative waveform samples |
| `swift/AfterRayRecall/Sources/AudioMomentChrome.swift` | `AudioMomentChromeModel`, waveform button, caption highlight, `AudioMomentChromeStage` (fake clock + track) |
| `swift/AfterRayRecall/Tests/AudioMomentTranscriptTests.swift` | Split / cue / active-index / progress tests — **not run yet** |
| `swift/AfterRayMockData/Sources/AudioCaptionFixtures.swift` | idle-audio-only, idle-with-caption, playing-highlight, buffering, long-bilingual, mid-progress, hidden-no-audio |
| `apps/AfterRayVisualSnapshots/Sources/main.swift` | `audioChromeScenes` + `SnapshotCLI --only <prefix>` |
| `Makefile` | `make audio-chrome-snapshots` → `swift run afterray-visual-snapshots -- $(OUT) --only audio-chrome` |

Reproduction commands:

```bash
swift test --filter AudioMomentTranscriptTests
make audio-chrome-snapshots OUT=/tmp/afterray-audio-chrome
# then read_file every /tmp/afterray-audio-chrome/audio-chrome-*.png
```

These commands remain the visual-regression entry points.

---

## Exact-segment sentence highlighting (protocol 18)

Transcription and timing are separate durable stages:

1. Qwen3-ASR first commits the full text and detected language. Search, history,
   and summaries can use it immediately.
2. Qwen3-ForcedAligner-0.6B aligns that text to the same audio artifact. Schema
   27 stores bounded sentence cues as offsets from the exact segment start.
3. Existing transcript rows migrate into an independent alignment backlog.
   Silence is `not_needed`; alignment failure never removes readable text.
4. Lean timeline reads still return only the audio pointer and bounds.
   `moment_get` alone adds transcript text plus cues, so scrolling never decodes
   audio or scans cue rows.
5. Swift binary-searches the ordered cues using `AVAudioPlayer.currentTime`.
   It highlights only inside a real aligned interval and shows at most three
   nearby cues. Pauses between cues have no highlight.
6. While a legacy segment waits for backfill, the character-weight split is a
   display fallback only. It never claims that an estimated sentence is being
   spoken.
7. Keep `currentTime` leaf-scoped rather than publishing it through the recall
   root.

---

## Phase 2b — completed screenshot loop

Required PNGs every round (`audio-chrome-*` prefix):

| Scene | What it proves |
|---|---|
| `idle-audio-only` | Waveform visible with **no** ASR text |
| `idle-with-caption` | Caption from-this-moment-forward, no highlight |
| `playing-highlight` | Active sentence highlighted |
| `buffering` | Buffering state, not a frozen play icon |
| `long-bilingual` | Wrap / truncation / CJK + EN |
| `mid-progress` | Highlight is not stuck on sentence 0 |
| `hidden-no-audio` | Chrome gone; timestamp / track remain |

Each round:

1. `make audio-chrome-snapshots OUT=/tmp/afterray-audio-chrome`
2. **Look at every PNG** with `read_file`. Do not infer from Swift source.
3. Review with:
   - `better-interface` (full)
   - `better-ui` (play-triangle optical alignment, concentric radii, press scale 0.96, motion restraint)
   - `swiftui-pro`
4. Write findings from **pixels**. Fix them.
5. Re-render the same matrix. Confirm old findings are gone; find the next ones.

Stop only when a round’s `better-interface` verdict is `Approve` **and** you can say “I looked at these N screenshots and found nothing blocking.”

Lody `lody_report_preview_candidate` is web-only. Do not use it. Optional `make audio-lab` does **not** replace PNGs (2c not implemented yet).

---

## Phase 3 — integrated after Approve

1. Relax mount gate: show chrome when `audioArtifactId != nil` **or** `hasVisibleTranscript`.
2. Place in `timelineChromeRow` centered `VStack` **above** `ScrubPlayheadTimestamp` (product: 时间戳上方). Tall caption must stay overlay / not in-flow or it lifts `DaySummaryPanel` (`swift/AfterRayRecall/AGENTS.md`).
3. Spacebar: allow when `audioSegment != nil` even without transcript. Selection
   must not prefetch audio; only explicit play may read/decrypt the artifact.
4. Wire `onToggleAudio` + playing / buffering + playback progress.
5. Keep existing `captionScenes` snapshots green.

Implementation correction: playback identity is `(moment id, artifact id, offset)`.
User-driven timeline/search movement unloads it immediately. Audio uses a separate
no-cache repository, and the leaf chrome reads playback time without publishing a
timer through the recall root.

Playback follow-up: media time maps back to the lean timeline with binary search.
The background, timestamp, and playhead advance only when the capture moment changes.
Automatic playback travel preserves the immutable audio source; user travel stops and
unloads it before moving. The caption keeps the active cue inside a three-cue window.

Performance follow-up: a search gesture selects already-loaded lean rows immediately,
but never calls `openMoment` for every cold result it crosses. One cancellation-aware
task opens and hydrates the final result after 500ms quiet. `moment_get` remains the
only subtitle/cue read and never decrypts audio. Explicit playback sends artifact
copying, `AVAudioPlayer` construction, `prepareToPlay`, and sensitive-buffer clearing
through `RecallAudioRepository`'s actor rather than running them on MainActor.

## Phase 4

If “audio visible without ASR” is intentional, add `docs/decisions/active/...` in the same change. Update `swift/AfterRayRecall/AGENTS.md`. Grep `@dec:` first. Present tense in `active/` records; mandatory `## Alternatives considered`.

---

## Non-goals

- Browsable global audio history / day-panel audio markers
- Persisting every aligned character/word when sentence-sized cues suffice
- Real PCM waveform in v1 (decorative seeded bars are OK)
- Changing capture / exclusion / silent-discard policy

---

## Acceptance

1. Isolated `audio-chrome-*` matrix renders without `RecallView`.
2. ≥3 render → `read_file` PNG → skill review → fix cycles. Final verdict `Approve`, findings tied to pixels.
3. `idle-audio-only` shows a waveform with no caption. `playing-highlight` / `mid-progress` show the active sentence, not the whole prior segment.
4. Visual Lab is optional and **not** the acceptance path.
5. After phase 3: a lean-timeline moment with `audioArtifactId` shows the control without waiting for ASR; `captionScenes` still pass.
6. Unit tests green; gate tests updated.

**Risk: middle.** Playback path is reused. The main operational risk is the new
required aligner download and historical backfill; text remains available if
either fails.
