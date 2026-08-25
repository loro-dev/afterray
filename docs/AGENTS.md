# AGENTS.md — docs/

Specs, plans, and design docs for AfterRay. **Plan docs are historical: when a plan and the code disagree, the code wins.** Verify against the source before relying on any plan. Several docs are in Chinese. Cross-cutting code maps live in `../context/`.

That fallback applies to the plan and spec documents listed below, not to the whole directory. `decisions/` and `postmortem/` have a known status by construction — read them as authority.

## Decisions and incidents (authoritative)

- [decisions/](decisions/README.md) — why the code is the way it is: one record per decision, its status encoded in the directory it sits in (`proposed` / `active` / `superseded` / `rejected`). Code carries `@dec:` markers pointing back at them. **Before changing behavior, grep the files you are touching for `@dec:`** and read every `active/` record sharing that record's `Area:` — those are the decisions a change can contradict. Standard and workflow: [decisions/AGENTS.md](decisions/AGENTS.md).
- [postmortem/](postmortem/README.md) — what broke, why the guards missed it, what changed. Required for data loss, plaintext or key exposure, a pulled or hot-fixed release, silently degraded capture, or a bug that took more than a day to locate.

## Operational (kept current)

- `development.md` — build/run/dev-loop reference; states the authoritative "the UI never opens the database" rule and the dev-vs-packaged path table.
- `releasing.md` — the human release process; matches `scripts/build-release.sh` / `publish-release.sh`.
- `visual-lab-workflow.md` — mock-data UI loop (Active).

## Design & plans (historical — code wins)

**Each of these opens with a status block naming what the code has since overturned.** Read that block before the body; do not restate per-document progress here, where it goes stale unread.

- `afterray-v0-implementation-plan.md` — V0 scope and phases.
- `afterray-v1-spec.md` — deferred product vision. Its EARS requirement IDs (`CAP-…`, `PRV-…`) are cited from source, so it is the definition site for them even though the vision is deferred.
- `vault-encryption-design.md` — vault encryption (Accepted); implemented in `crates/afterray-store`.
- `harness-threat-model.md` — what the agent tool surface stops and what it accepts; linked from both READMEs.
- `hot-stills-cold-gop.md` + `hot-stills-cold-gop-codex-review.md` — cold AV1 GOP design and a critical review of it. The review is the repo's richest record of rejected alternatives.
- `slot-summaries-and-ax-pipeline.md` — slot summaries + Accessibility pipeline.
- `t1-t2-card-quality-plan.md` — T1/T2 card quality; pairs with `scripts/t2-eval.py`.
- `input-events-and-t1-acts-plan.md` → `event-capture-v2-plan.md` — input capture and the T1 acts join, then its successor. The second supersedes parts of the first, including the first's ban on event-driven screenshots.
- `agent-chat-plan.md` → `harness-plan.md` → `harness-implementation-notes.md` — a chain: build the chat surface, restructure it, then what the restructuring became. Each partly supersedes the one before.
- `auto-update-plan.md` — Sparkle + Cloudflare updates.
- `qwen3.5-4b-mlx-integration-plan.md` — MLX VLM integration.
- `search-presentation.md` — search UX; the most accurate plan in this directory.
- `audio-timeline-plan.md` — locally completed playhead audio chrome (waveform + from-this-moment ASR caption). Not historical until merged.
- `evals/` — privacy-safe evaluation methods and aggregate results only; never raw vault inputs or outputs.

## Convention

When you change behavior a doc describes, update the doc in the same change. For a historical plan, that means updating its status block, not rewriting its body — the body's record of how the trade-off was weighed is what [decisions/](decisions/README.md) draws `## Alternatives considered` from.
