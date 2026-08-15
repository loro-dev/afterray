# Qwen3.5-4B MLX Phase 0 record

Status: implementation complete; real-device run pending.

## Fixed artifact

- Repository: `mlx-community/Qwen3.5-4B-MLX-4bit`
- Revision: `32f3e8ecf65426fc3306969496342d504bfa13f3`
- Managed snapshot size: `3,061,129,077` bytes
- Weight file: `model.safetensors`, `3,034,300,695` bytes
- Runtime: `mlx-swift-lm` `3.31.4`, loaded through `MLXVLM`.

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
directory is absent. A skip is not an acceptance result. The Rust adapter
enables `use_kv_cache` by default. If cache prefill fails before any user token
is sent, it retries that request with a fresh session in the same loaded model
container. `AFTERRAY_MLX_ENABLE_KV_CACHE=0` is a narrow recovery switch, not a
user-facing setting.

## Measurements and T2 quality record

Do not fill any result before an actual device run. Record each run with:

- macOS version, M2 variant, unified memory, and available disk space;
- downloader bytes and checksum outcome;
- cold load time, peak resident memory, steady output tokens/s, and cancellation latency;
- T2 evaluation command/output from `crates/afterrayd/examples/t2_eval.rs`;
- manual review of Chinese retrieval, time ranges, `TOOL`/`ARGS` calls, and final answers.

Current blockers: this worktree has neither the verified 3.06 GB snapshot nor
the M2 8/16/24 GB matrix. No throughput, memory, compatibility, or quality
claim has been recorded.
