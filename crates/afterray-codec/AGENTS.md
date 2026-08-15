# crates/afterray-codec — encode-only AV1

Still-frame GOP encoding for cold storage: JPEG stills → tightly packed 8-bit I420 → closed AV1 GOP (rav1e) → IVF container. **Encode-only: nothing in this repo's Rust can decode AV1** — clients decode GOP frames themselves (see `scripts/prove-av1-decode.swift`). Used by `afterrayd`'s GOP packer; never linked into the capture shim.

## Key anchors

- `encoder.rs:11 Rav1eEncoder` — rav1e wrapper; product defaults speed=8, quantizer=100, tiles=4 (encoder.rs:23-25), closed GOP with keyint = frame count.
- `ivf.rs` — IVF mux/parse/slice (`parse_ivf`, `slice_ivf`); a GOP must fit a `u16` keyint (`CodecError::GopTooLong`).
- `jpeg.rs:10 jpeg_to_i420` — zune-jpeg decode to I420.
- `thumbnail.rs:25 still_thumbnail` — downscaled JPEG thumbnail (built by the daemon before the source still is dropped).

## Build / test

- `cargo test -p afterray-codec` — includes a golden IVF fixture (`fixtures/closed-gop-64x64.ivf`).

## Watch out

- The encoder defaults are **measured product defaults** — change them only with a benchmark.
- Input frames must be 8-bit I420 with even dimensions (≥ 16); no colorspace/scaling helpers live here.
- Don't add a "decode GOP" helper expecting AV1 decode to exist in Rust — it doesn't, by design.
