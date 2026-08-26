# Decision: Offline inspection opens the vault read-only

Status: active
Area: privacy
Anchors:
- crates/afterray-store/src/lib.rs @dec:read-only-vault-inspection
- crates/afterrayd/src/main.rs @dec:read-only-vault-inspection
Supersedes: —
Superseded-by: —

## Problem

Investigating a user's production history or ASR quality must not trigger the
ordinary daemon startup path. That path can migrate settings, remove capture
staging, repair sessions, reclaim downloads, perform artifact maintenance, and
run background workers. A process advertised as inspection must not alter the
captured record merely by opening it.

## Decision

`AFTERRAY_READ_ONLY_INSPECTION=1` starts an isolated daemon that opens only an
existing keyed vault through SQLite read-only connections with `query_only`
enabled. It never creates a vault key or data directory, runs migrations,
retention, reconciliation, session repair, capture staging cleanup, download
reclamation, artifact maintenance, or background workers. It may answer the
existing query-only socket requests on an independently supplied socket path.

The mode is for an explicit offline inspection while the ordinary daemon is
stopped. It is not an app runtime mode and does not weaken the normal daemon's
single-writer ownership.

## Alternatives considered

**Use the ordinary daemon and promise not to call mutating RPCs.** Rejected
because startup itself performs maintenance before any client request arrives.

**Copy the production vault before inspection.** Rejected because a copied
SQLCipher database can be inconsistent with its WAL and artifact directory,
and copying captured history creates another sensitive data set.

**Open the database directly from the UI or a script.** Rejected because it
would duplicate vault-key and decryption ownership outside `afterrayd`.

## Consequences

Inspection is restricted by the same keychain access and socket peer boundary
as the daemon. It can fail when the current executable is not permitted to read
the vault key; that failure is preferable to bypassing the keychain or falling
back to a writable open. The mode adds a separately testable read-only open
path and leaves the normal startup behavior unchanged.
