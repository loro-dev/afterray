# Decision: Official Hugging Face downloads retry once from hf-mirror.com

Status: active
Area: models
Anchors:
- crates/afterray-models/src/download.rs @dec:hf-mirror-failover
- crates/afterrayd/src/main.rs @dec:hf-mirror-failover
Supersedes: —
Superseded-by: —

## Problem

Onboarding's model-download step, and Settings after it, fetch pinned packs
from huggingface.co. On networks that reset, time out, or otherwise cannot
reach that origin — common for first-run users — the transfer dies and the
user is left to discover Settings → download source and pick hf-mirror.com
by hand. The bytes are SHA-256 pinned, so a mirror is already a safe origin;
the missing piece is doing that switch without a failed first run.

## Decision

When the live origin is the official Hugging Face endpoint, a retryable
failure of a listing or file request is tried once against
`https://hf-mirror.com`. Retryable means a connect/timeout/body HTTP error,
HTTP 408/429/5xx, a SHA-256 mismatch, or a truncated body. HTTP 404, disk
errors, and cancellation are not: another origin cannot fix those.

A 15-second connect timeout bounds how long the official origin may hang
before the fallback runs. The existing 30-minute request timeout still
covers a large successful body.

On the first successful fallback response the live origin is adopted for
the rest of the process, so later files in the same pack do not each wait
out the official origin. The daemon then persists that origin into
settings when the stored value was empty or official, so Settings and the
next launch match what actually worked. A user-chosen custom endpoint, or
an already-chosen mirror, never fails over.

## Alternatives considered

**Fail over only in the onboarding Swift view, after the pack reports
`.failed`.** That is where the user feels the stall, but the transfer
already lives in the daemon. Waiting for the whole pack to die — under a
30-minute request timeout, with no connect timeout — is the slow path this
decision exists to avoid, and Settings downloads would still fail the same
way.

**Always start at hf-mirror.com.** Faster for networks that cannot reach
huggingface.co, slower and more surprising for everyone else, and it would
silently ignore a user who picked the official origin on purpose.

**Fail over without persisting.** Remaining files in the same process would
still hit the official origin first unless the live endpoint is adopted;
adopting in memory and leaving settings on "official" would make the
picker lie after a successful rescue.

## Consequences

**Bought:** onboarding and Settings downloads get through a blocked or
flaky huggingface.co without a manual mirror pick. Integrity is unchanged;
the catalog pins still reject a mirror that serves the wrong bytes.

**Cost:** a 15-second stall on the first file when the official origin is
unreachable, before progress moves. A transient official failure can leave
the user on the mirror until they switch back in Settings. `HF_TOKEN`, if
set, is sent to whichever origin is live — the same rule as a manual
mirror pick.
