# AGENTS.md — docs/decisions/

Why the code is the way it is. Full standard: [README.md](README.md). Template: [_template.md](_template.md).

## Before you change code

Grep the files you are about to touch for `@dec:`. Every hit is a decision governing that code — read it first. When a bug turns out to be a decision working as designed, the fix is a new decision record, not a patch.

Then read every `active/` record sharing that record's `Area:`. Those are the decisions that can contradict a change to the same requirement; the `Area:` field exists for exactly this lookup.

## When to write one

Write or update a record when a change alters behavior, an on-disk or wire format, a trust or ownership boundary, a product requirement, or anything else a maintainer could reasonably revisit. Mechanical and local edits are exempt.

Updating the record that already owns the decision satisfies this — do not write a second record for the same choice.

## The rules that are easy to get wrong

- **Directory = status.** `proposed/`, `active/`, `superseded/`, `rejected/`, then a class directory (`architecture`, `product`, `process`, `bug-fix` — closed set). The `Status:` line must agree with the directory.
- **`## Alternatives considered` is mandatory**, in every record, including retroactive ones. Alternatives are recorded, never invented: with no source for them, say so.
- **Anchors are bidirectional.** `path @dec:slug` in the record's `Anchors:` list; in the code, `// @dec:slug — <path to the record>` directly above the item, above any doc comment. Never one without the other. Anchor the narrowest item that carries the decision, and only where an accidental undo is plausible.
- **Supersede, never rewrite.** Changing a requirement means a new record with `Supersedes:`, the old file moved to `superseded/`, and a `Superseded-by:` back-link written in the same change. The two files are the visible record of the change.
- **Present tense in `active/`.** No "previously", "now", "no longer", no migration plans, no acceptance checklists — those belong in `proposed/`. State what is true; the supersede chain holds the history.
- **Links are relative Markdown paths**, never bare filenames or dates.

## What does not go here

Current behavior and invariant lists go to `../../context/`. Build and workflow reference goes to `../development.md`. Incidents go to `../postmortem/`. A record that mostly restates what the code does is in the wrong tier — cut it down to the choice and its cost.

## The gate

`make docs-sync` checks links, record shape, and the anchor relation both ways. It also hashes the code under every `@dec:` marker against `<slug>.anchors.json`.

**A red anchor hash does not mean your edit is wrong.** It means the decision governing that code has not been re-read since the code changed. Re-read it; if it still holds, `node scripts/docs-gate/main.ts --write` and commit the sidecar diff — that diff is the confirmation. If it no longer holds, supersede the record instead.

Never hand-edit a sidecar. A hash nobody verified claims a confirmation that never happened. [README.md](README.md#what-the-gate-checks) covers what the gate can and cannot see.
