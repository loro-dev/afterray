# AGENTS.md — AfterRay

AfterRay is a local-first macOS computer-history app: a Rust daemon (`afterrayd`) captures screen, audio, and Accessibility context into an encrypted vault; a SwiftUI app queries it over a versioned Unix socket. Product overview: [README.md](README.md). Build/run/architecture detail: [docs/development.md](docs/development.md).

## Build, test, lint

- `make dev` — watch-mode signed dev app; `make dev-ui` — mock-data UI loop, no permissions or real data
- `make test` — `cargo test --workspace` + `swift test`
- `make test-repeat N=10 [TEST=name]` — new concurrency/IO tests need ≥5 consecutive green runs before commit; judge a build by its exit code, never a filtered warning count ([why](docs/development.md#tests-and-lint))
- `cargo clippy --workspace --all-targets -- -D warnings` — lint gate; the workspace denies `unsafe_code`
- `make v0` / `make v0-daemon` — one-shot signed app / daemon only; dev data lives in gitignored `.afterray/` and `.afterray-dev/`

## Context index

Before editing, read every `AGENTS.md` along the path from root to leaf. Every `AGENTS.md` has a `CLAUDE.md` symlink beside it.

- [crates/](crates/AGENTS.md) — Rust workspace: daemon (`afterrayd`), encrypted vault (`afterray-store`), wire protocol (`afterray-protocol`), CLI (`afterray-cli`), model queue/workers (`afterray-models`, `afterray-infer`)
- [swift/](swift/AGENTS.md) — SwiftUI recall library (`AfterRayRecall`), mock data, MLX VLM worker core
- [apps/](apps/AGENTS.md) — shipped app (`AfterRay`), capture shim (standalone SwiftPM package), model worker executables, visual tooling
- [scripts/](scripts/AGENTS.md) — dev loop, signing/notarization/Sparkle release, publish; the root `Makefile` is the entry point
- [site/](site/AGENTS.md) — afterray.com: React+Vite, Cloudflare Pages, R2-backed appcast/download functions
- [docs/](docs/AGENTS.md) — specs and plans (some plans are historical; code wins)
- [context/](context/) — navigation articles: [capture-pipeline](context/capture-pipeline.md), [wire-protocol](context/wire-protocol.md); [CONTEXT-GAPS.md](context/CONTEXT-GAPS.md) — gaps backlog
- `skills/afterray/` — the shipped Agent Skill for the read-only CLI surface; keep in sync with `afterray-cli`

## Working agreements

### Commits

- Conventional Commits, `type(scope): subject` — e.g. `feat(store): ...`, `fix(daemon): ...`. Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `style`, `test`, `build`, `chore`; scope is the crate/area name.
- Every commit records the exact AI model and harness that produced it as trailers:
  `Model: <exact AI model name>` (e.g. `Model: kimi-k2.5`) and `Harness: <harness name>` (e.g. `Harness: lody`).

### Pull requests

- Always label correctness risk: `risk:low`, `risk:middle`, or `risk:high`.
- Security risk: low needs no label; high must be labeled `security` explicitly.
- The PR description states the agent's confidence in the change — what was verified and how, what was not.

### Agent-facing docs

- Important directories carry an `AGENTS.md`; add `CLAUDE.md` as a symlink next to it: `ln -s AGENTS.md CLAUDE.md`.
- Keep each `AGENTS.md` under ~4000 chars (`wc -m`); past ~2000 chars of detail, extract into a linked article under `context/` (each under ~32000 chars).

## Self-Maintained Agent Context

Standing rules for every agent working in this repo:

1. Treat "why was that so hard to find?" as a tripwire: fix the docs now or append a line to `context/CONTEXT-GAPS.md`.
2. Before searching or modifying a file, read every `AGENTS.md` along its path from root to leaf.
3. If a code change makes an `AGENTS.md` or context article stale, update it in the same change.
4. Add an `AGENTS.md` plus `CLAUDE.md` symlink to directories that gain local invariants.
5. When something took many tool calls to find, write the shortcut into the nearest `AGENTS.md`.
6. If a common answer takes more than ~4 hops to find, tell the human and propose an index line, pointer, or article.
7. Index every new article in this root index and the nearest per-directory `AGENTS.md`.
8. Respect the size budgets; extract and link rather than overflow.
9. When a commit body must explain a non-obvious constraint, land it in the relevant `AGENTS.md` or article too; keep the commit body a pointer.
