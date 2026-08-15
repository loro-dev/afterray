# crates/afterray-core — trait definitions only

Two async traits and their error/DTO types (`lib.rs`, 40 lines): `CaptureBackend` (`start`/`stop`) and `Store` (session/moment/audio-segment reads), plus `CoreError`. Nothing else belongs here — the real store is `afterray-store::Vault`, the real capture backend is `afterray_platform_macos::MacOsCaptureBackend`. If you're adding logic, you're in the wrong crate.

## Build / test

- `cargo check -p afterray-core` (no tests; it's type definitions).

## Watch out

- `afterray-core` looks like the heart of the system but is only an interface seam; changing a trait signature ripples into `afterrayd` and `afterray-store` — prefer extending the concrete types instead.
