# Qwen3.5-4B MLX Phase 0 record

Status: implementation complete; required M2 device matrix pending. The
windowed-prefill regression passed on one M5 Pro development machine.

## Fixed artifact

- Repository: `mlx-community/Qwen3.5-4B-MLX-4bit`
- Revision: `32f3e8ecf65426fc3306969496342d504bfa13f3`
- Managed snapshot size: `3,061,129,077` bytes
- Weight file: `model.safetensors`, `3,034,300,695` bytes
- Runtime: `mlx-swift-lm` revision `65be34c64237c0b5da348169d3a9b59f37453fe2`, loaded through `MLXVLM`. This revision contains the Qwen3.5 windowed-prefill fix.

## Optional higher-quality artifact

- Repository: `mlx-community/Qwen3.5-9B-MLX-4bit`
- Revision: `938d8919941c6e7efd3c7150eff7fe9d12afa631`
- Managed snapshot size: `5,977,071,067` bytes; weights are two safetensors shards.
- This is an optional comparison target, not the default download. Record the
  same cache, memory, throughput, and T2 measurements before recommending it
  for a hardware tier.

## Required hardware matrix

| Device | Product position | Required run |
| --- | --- | --- |
| Apple Silicon M2, 8 GB unified memory | Experimental only; no support promise | Load, one text response, one image response, cancel recovery |
| Apple Silicon M2, 16 GB unified memory | Product candidate | All regression tests; measure cold load, peak memory, steady tokens/s, long context |
| Apple Silicon M2, 24 GB unified memory | Product candidate | Same as 16 GB, including T2 samples |

## Real-model regression command

The directory must be created by AfterRay's verified downloader, so it
contains `.afterray-ready.json` with the fixed revision.

```sh
AFTERRAY_QWEN35_MODEL_DIR=/absolute/path/to/Qwen3.5-4B-MLX-4bit \
  swift test --filter Qwen35KvCacheRegressionTests
```

This test loads the actual 4B or 9B VLM container and reuses one `ChatSession` across:

1. a red image;
2. a different blue image;
3. a text-only request;
4. cancellation during streaming followed by a new request.

It fails on a runtime/cache crash and is explicitly skipped when the model
directory is absent. A skip is not an acceptance result. This direct-session
test exercises upstream warm continuation. The AfterRay worker itself keeps the
model container loaded but starts a fresh `ChatSession` for every independent
daemon request.

## Measurements and T2 quality record

Do not fill any result before an actual device run. Record each run with:

- macOS version, M2 variant, unified memory, and available disk space;
- downloader bytes and checksum outcome;
- cold load time, peak resident memory, steady output tokens/s, and cancellation latency;
- T2 evaluation command/output from `crates/afterrayd/examples/t2_eval.rs`;
- manual review of Chinese retrieval, time ranges, `TOOL`/`ARGS` calls, and final answers.

Current blocker: the required M2 8/16/24 GB matrix is unavailable. No M2
throughput, peak-memory, compatibility, or quality claim has been recorded.

## 2026-08-20 windowed-prefill regression

- Device: Apple M5 Pro, 64 GB unified memory, macOS 26.5.1.
- Snapshot: AfterRay's verified Qwen3.5-4B MLX 4-bit installation.
- Runtime: `mlx-swift-lm` revision `65be34c` with `mlx-swift` 0.31.6.
- Scenario: image turns, text turn, cancellation and recovery, then two
  consecutive 20,000-word `memory` prompts on one warm `ChatSession`.
- Result: passed in 39.673 seconds. The second long prompt is the old
  >47 GiB scratch-buffer shape; this run did not reproduce the Metal allocation
  crash. Peak resident memory and the required M2 matrix were not measured.
