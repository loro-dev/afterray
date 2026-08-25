# Qwen3-ASR MLX Phase 0 record

Status: method only; no device run has been recorded. Do not treat a skip or an
empty table as acceptance.

This file may hold evaluation **method** and **aggregate non-identifying
numbers**. It must never contain vault audio, transcripts, app titles, paths
that identify a user, or model output text. See [AGENTS.md](AGENTS.md).

Parent plan: [qwen3-asr-mlx-integration-plan.md](../qwen3-asr-mlx-integration-plan.md).

## What this phase has to answer

1. Can the chosen Swift runtime load a directory produced by AfterRay's
   downloader **with the network off**?
2. On the same fixtures, is 1.7B MLX 4-bit close enough to Candle 1.7B BF16
   that we can change the default pack?
3. How much of today's CPU cost is cold load vs inference? (Candle one-shot vs
   MLX warm vs, optionally, a persistent Candle control.)
4. Does a ≥5 minute clip loop or balloon memory on the pinned mlx-audio-swift
   revision?

Until (1) and (2) are yes, the catalog stays on `Qwen/Qwen3-ASR-1.7B`.

## Fixed artifacts to compare

Record the exact revision actually used. Placeholders below are the plan's
candidates, not pins.

| Label | Repository | Role |
| --- | --- | --- |
| candle-bf16 | `Qwen/Qwen3-ASR-1.7B` at the current catalog revision | baseline |
| mlx-1.7b-4bit | `mlx-community/Qwen3-ASR-1.7B-4bit` | default candidate |
| mlx-1.7b-8bit | `mlx-community/Qwen3-ASR-1.7B-8bit` | quality ceiling |
| mlx-0.6b-4bit | `mlx-community/Qwen3-ASR-0.6B-4bit` | size contrast, not a default unless (2) still holds |

Each MLX directory must be created by AfterRay's downloader so it carries
`.afterray-ready.json`. A Hub cache folder is not an AfterRay pack.

## Fixtures

Use synthetic or explicitly licensed clips stored **outside** the repo (or a
private eval dir that is gitignored). Suggested set, none of which should be
committed:

- ~3 s English read speech
- ~3 s Mandarin read speech
- ~30 s code-switched Chinese/English
- ≥5 min mixed system-audio-like clip (the long-loop case)

Do not copy AfterRay vault segments into the tree. If a private-vault run is
needed, keep the transcript off-repo and write only aggregates here.

## Metrics (aggregates only)

For each label × clip, record:

- wall time (ms)
- whether the model was cold or warm
- CPU percent as a share of one core, unclamped, sampled the same way the
  compute panel does (`proc_pid_rusage` over ≥1 s)
- peak RSS
- character count of `sanitize_asr_text` output (not the text)
- detected language string
- whether the sanitizer dropped the output entirely (thank-you loop)
- for the long clip: peak RSS and whether generation hit max tokens without
  finishing

Do not fill the table before a real run.

## Required hardware notes

AfterRay's product floor is Apple Silicon, macOS 15+. Phase 0 on one development
Mac is enough to **unlock implementation**, not to claim a hardware matrix.
If the only available machine is a high-memory M-series, say so; do not
generalize to 16 GB.

## Offline-load probe

```
# Sketch — implement out of tree or gitignored.
# 1. Copy a verified pack to a temp dir.
# 2. Disable network (pf / airplane / unplugged Ethernet).
# 3. Ask the worker to `load` that dir.
# Pass = ready. Fail = Hub fallback or missing local loader.
```

A pass that required a previously populated Hugging Face cache is a fail.

## Runs

One preliminary synthetic-fixture run was completed on an Apple M5 Pro with
64 GB unified memory. The runner was the gitignored Python `mlx-audio` probe,
not the proposed Swift worker; it is evidence about the candidate snapshot and
MLX execution shape only.

| Engine | Clip duration | State | Wall time | Peak RSS | Sanitized characters | Result |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| Current Candle BF16 | 259.897 s | one-shot | 110.930 s | 9.88 GB | 3,493 | completed |
| MLX 1.7B 4-bit | 259.897 s | loaded, first process | 5.236 s | 2.14 GB | 4,198 | completed |

The MLX candidate loaded a local directory without a repository identifier on
the first attempt while `HF_HUB_OFFLINE=1`; its loader reported ready after
3.382 s and 1.79 GB peak RSS. This is a useful local-directory signal, but not
the required physical-network-off proof and not evidence for the future Swift
worker.

The long synthetic clip completed without a sanitizer drop or an apparent
token-limit failure. Its MLX/Candle character-count difference is about 20%,
so this run does **not** establish transcription-quality equivalence. Do not
change the default pack yet.

The same run measured short synthetic clips, but startup and Metal cache state
made their wall time non-comparable. A follow-up must keep cold process start,
model load, and warm generation as separate measurements.

### Remaining acceptance work

1. Download the candidate through AfterRay's Rust downloader, verify its
   SHA-256 ready marker, then load the resulting directory with networking
   physically disabled.
2. Repeat with the pinned standalone Swift worker, not Python.
3. Score normalized error against explicitly licensed or synthetic reference
   text without recording the transcript, including Chinese/English switching
   and at least one long mixed-audio fixture.
4. Run the resulting signed helper through the real daemon queue and confirm
   GPU-lane admission, cancellation, and the 120-second idle-process exit.
