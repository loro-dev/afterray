# Postmortems

What broke, why the guards missed it, and what changed. This is the one place in `docs/` where narrative belongs: an incident is a sequence, and flattening it into a rule loses the evidence that made the rule necessary.

## When one is required

Write a postmortem when a bug did any of the following, whether or not it reached a user:

- **Lost or corrupted vault data**, or made it unreadable.
- **Leaked plaintext**, exposed a key, or widened who can read the vault — including anything reachable over the socket.
- **Shipped**, and needed a release to be pulled, rolled back, or hot-fixed.
- **Silently degraded capture** — the recorder appeared healthy while recording nothing, or nothing useful.
- **Took more than a day to locate.** Not because the impact was large, but because that is the signal that the code was not explainable; that is the finding.

Below that line, a decision record under [../decisions/](../decisions/README.md) with class `bug-fix` is enough.

## Filename and shape

`YYYY-MM-DD-slug.md`, where the date is when the incident was **detected**.

```markdown
# Postmortem: <what broke, in one line>

Detected: YYYY-MM-DD
Area: <capture | store | models | recall-ui | agent | release | privacy>
Decisions implicated:
- ../decisions/active/architecture/YYYY-MM-DD-slug.md

## What happened
## Root cause
## Why the guards did not catch it
## What changed
## What is still exposed
```

`## What happened` is chronological and states evidence — logs, versions, what was observed and when — not a teaching sequence. `## Root cause` is the mechanism, not the commit; the commit is where it entered, which is a different fact and belongs in the chronology.

`## Why the guards did not catch it` is the section this document exists for. A test that did not exist, an invariant nobody had written down, a decision whose consequence was never followed through. If the honest answer is "nothing could have", write that — it is a finding about coverage.

`## What is still exposed` names what the fixes did **not** address. An incident that closes with nothing outstanding is unusual; claiming it without checking is how the second occurrence happens.

## Linking back

Every decision listed under `Decisions implicated:` gets a link to this postmortem from its `## Consequences` section, in the same change. Both directions, always: a postmortem nobody can reach from the decision that permitted the failure only gets read by whoever already remembers it.

When the incident shows a decision was wrong rather than merely under-guarded, the fix is a new decision record superseding it — the postmortem records the failure, not the replacement choice.
