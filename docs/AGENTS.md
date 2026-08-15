# AGENTS.md — docs/

Specs, plans, and design docs for AfterRay. **Plan docs are historical: when a doc and the code disagree, the code wins.** Verify against the source before relying on any plan. Several docs are in Chinese. Cross-cutting code maps live in `../context/`.

## Operational (kept current)

- `development.md` — build/run/dev-loop reference; states the authoritative "the UI never opens the database" rule and the dev-vs-packaged path table.
- `releasing.md` — the human release process; matches `scripts/build-release.sh` / `publish-release.sh`.
- `visual-lab-workflow.md` — mock-data UI loop (Active).

## Design & plans (historical — code wins)

- `afterray-v0-implementation-plan.md` — V0 implementation plan (labeled Active, but the code has moved on).
- `afterray-v1-spec.md` — deferred product vision; explicitly not a V0 task or acceptance source.
- `vault-encryption-design.md` — vault encryption design (Accepted); implemented in `crates/afterray-store`.
- `hot-stills-cold-gop.md` + `hot-stills-cold-gop-codex-review.md` — hot-stills / cold AV1 GOP design and a critical review of it.
- `slot-summaries-and-ax-pipeline.md` — 30-minute slot summaries + Accessibility pipeline (draft).
- `t1-t2-card-quality-plan.md` — T1/T2 card quality work; pairs with `scripts/t2-eval.py`.
- `agent-chat-plan.md`, `harness-plan.md` — agent chat / harness plans.
- `auto-update-plan.md` — Sparkle + Cloudflare update plan (marked implemented).
- `qwen3.5-4b-mlx-integration-plan.md` — MLX VLM integration plan.
- `search-presentation.md` — search UX design notes.
- `evals/` — eval notes and card samples (`qwen35-4b-mlx-phase0.md`, `t1-t2-2026-08-14/`, `t2-cards/`).

## Convention

When you change behavior a doc describes, update the doc in the same change — or add a stale-note at its top pointing at the code.
