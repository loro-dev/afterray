# Decision records

A decision record answers **why the code is like this** — the part source, tests, and `context/` articles cannot carry. Each one names the problem, the choice, what the choice beat, and what it cost.

This directory exists because `docs/*-plan.md` could not do that job. A plan describes intent at one moment and then rots; nothing marks which of its claims still hold. The rule "when a doc and the code disagree, the code wins" is what you fall back on when a document's status is unknowable. A decision record has a known status, and the code carries a pointer back to it.

## What goes where

| Where | What it holds |
|---|---|
| `docs/decisions/` | Why a choice was made, what it beat, what it cost. One decision per file. |
| `context/` | What the code does today — navigation maps, invariant lists. No rationale. |
| `docs/postmortem/` | What broke, why the guards missed it, what changed. See [postmortem/README.md](../postmortem/README.md). |
| `docs/*-plan.md`, `*-spec.md` | Historical planning documents. Not authority for current behavior. |
| `AGENTS.md` files | Standing orders and per-directory indexes. One to three lines each, linking here. |

## Lifecycle

The directory a record sits in **is** its status, and the `Status:` line must agree:

- **`proposed/`** — decided to consider, not yet built. May speak in the future tense.
- **`active/`** — shipped and still governing. Written in the present tense, kept current with the code.
- **`superseded/`** — a later decision replaced it. Frozen except for the `Superseded-by:` link.
- **`rejected/`** — considered and declined. Keep it only while it prevents a tempting mistake.

Under each lifecycle directory, one **class** directory: `architecture`, `product`, `process`, or `bug-fix`. That set is closed; adding to it means editing this section.

Filename: `YYYY-MM-DD-slug.md`, where the date is **when the decision was first written down here**. When git or another document shows the choice was actually made earlier, say so in the body rather than back-dating the filename — a date that cannot be verified is worse than one that is merely late.

## The header

Every record opens with exactly this shape, then a blank line:

```markdown
# Decision: <one-line title>

Status: active
Area: store
Anchors:
- crates/afterray-store/src/lib.rs @dec:size-driven-retention
Supersedes: —
Superseded-by: —
```

- **`Status:`** — `proposed` / `active` / `superseded` / `rejected — <why, one line>`. The rejection reason is the fact readers come for, so it lives on the status line.
- **`Area:`** — one of `capture`, `store`, `models`, `recall-ui`, `agent`, `release`, `privacy`. **This is the conflict-detection index.** Before changing a requirement, read every `active/` record in the same area; those are the decisions that can contradict yours.
- **`Anchors:`** — the code this decision governs, one line each, `path @dec:<slug>`. `—` when the decision governs no single site (a process decision, for example).
- **`Supersedes:` / `Superseded-by:`** — relative Markdown links, or `—`. Both directions are always written; a one-way link is how a chain becomes unfollowable.

## The body

`active/` and `superseded/`:

```markdown
## Problem      — the motivation, written so it stands without the solution
## Decision     — what is true now, present tense
## Alternatives considered
## Consequences — what the trade-off cost and what it bought
```

`proposed/`:

```markdown
## Problem
## Proposal     — may speak in the future tense
## Alternatives considered
## Acceptance criteria
## Risks
```

`rejected/` keeps whatever sections it had when it was declined.

Free-form sections (schemas, wire formats, measurements) may sit between the required ones. `## Testing` and `## Related` are fine where they state present-tense fact.

**`## Alternatives considered` is mandatory.** One bold-led paragraph per genuine alternative and why it lost. A decision recorded without what it beat gets re-litigated by the next person — preventing that is most of why these files exist. Alternatives are *recorded*, never invented: when a record is written after the fact and the alternatives are not reconstructible, say `Not recorded; reconstructed from <source>` and list only what the source supports.

Moving between lifecycles means rewriting the body to the destination's skeleton in the same change. `proposed/` → `active/` turns `## Proposal` into a present-tense `## Decision` and folds `## Acceptance criteria` and `## Risks` into `## Consequences`. A record is never edited into a *different* decision — supersede it instead.

## Code anchors

The decision names the code, and the code names the decision:

```rust
// @dec:size-driven-retention — docs/decisions/active/architecture/2026-08-20-size-driven-retention.md
/// How long a runtime marker in the event stream lives.
pub const SIGNAL_MARKER_RETENTION_MS: i64 = 48 * 60 * 60 * 1000;
```

The marker sits directly above the item it governs, above any doc comment so it does not land in the generated docs. It carries the path to the record, so reading the code is one click from the reason; when a record moves, its markers move in the same change. The decision's `Anchors:` list carries the reverse pointer, one line per file — a file holding several markers for the same decision is still one line.

Both directions, always. A marker with no record is a dangling pointer, and a record whose anchors have all disappeared is describing code that no longer exists.

Anchor the **narrowest item that carries the decision** — the function, struct, or const, not the file. Anchor sparingly: a marker is for a choice someone could plausibly undo by accident, not for every function that happens to be mentioned.

Swift and Python use their own comment syntax; the token `@dec:<slug>` is what matters.

## Working with these records

**Fixing a bug.** Before reading the failing code, grep the files you are about to touch:

```sh
rg '@dec:' crates/afterray-store/src/lib.rs
```

Each hit is a decision that governs that code. Read it — the bug may be the decision working as intended, in which case the fix is to change the decision, not the code. Then read every `active/` record with the same `Area:` to see which other decisions rest on the same requirement.

**Changing a requirement.** Write a new record whose `Supersedes:` points at the old one, move the old file into `superseded/`, add its `Superseded-by:` back-link, and move the anchors. The pair of files *is* the visible record of the change; do not edit the old record into the new decision.

**Narrowing one, which is not the same thing.** When a new decision takes one case out from under an older one whose general argument still holds, the old record stays `active/` and keeps its anchors. Use `Supersedes: —` and say in the opening line which record is narrowed and how; the older record gains a line in its `## Consequences` pointing back. Moving a still-governing record into `superseded/` is worse than leaving the change unrecorded — it retires an argument the code is still following. The test is whether the old record would be wrong if you deleted the new one: wrong means supersede, merely over-broad means narrow.

**After a serious bug.** Write a postmortem and link it from the `## Consequences` of every decision it implicates, so the failure is visible from the decision that allowed it rather than only from the incident file.

## What the gate checks

```sh
make docs-sync                          # check
node scripts/docs-gate/main.ts --write  # re-record anchor hashes
```

Three checks, all mechanical: every relative Markdown link and `#fragment` resolves; every record has the header, the lifecycle-matching `Status:`, a closed-set `Area:`, its required sections, and a two-way supersede link; and every `@dec:` marker pairs with a record that lists its file, both ways.

The one worth understanding is the **anchor hash**. Beside each record sits a `<slug>.anchors.json` holding a hash of the code under every marker, as of the last time someone confirmed the record still describes it. Edit that code and the gate goes red — not because the edit is wrong, but because nobody has re-read the decision since. Re-read it, then `--write`; the sidecar diff *is* the confirmation, and it is reviewable.

The hash covers the marked item alone — the function, const, or type — so an unrelated edit elsewhere in the file does not fire it. The key is `path::<first line of the item>`, which means renaming the item also trips the gate. That is intended: a signature change is exactly when a decision deserves a second look.

Note the limit. The gate proves a decision was *looked at* when its code changed. It cannot prove the decision is still right, and it cannot see the failure that matters most — an argument whose premise has quietly inverted while its conclusion still reads fine. That half stays with review.
