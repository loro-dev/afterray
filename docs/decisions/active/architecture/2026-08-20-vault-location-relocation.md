# Decision: Relocate the complete memory root only while the daemon is stopped

Status: active
Area: privacy
Anchors:
- apps/AfterRay/Sources/DaemonSupervisor.swift @dec:vault-location-relocation
- apps/AfterRay/Sources/AfterRayDataDirectory.swift @dec:vault-location-relocation
Supersedes: —
Superseded-by: —

## Problem

The default memory root shares the Mac's internal disk with the application.
Screenshots, recordings, encrypted artifacts, GOP archives, SQLite data, model
weights, and MLX runtime state can be much larger than the application itself.
Users need to place all of that state on a selected volume without splitting one
vault across two locations or allowing capture to write during a move.

## Decision

The App owns the **location preference**, while `afterrayd` remains the sole
owner of vault bytes and keys. The preference is held in UserDefaults rather
than the vault's `settings.json`, because the App has to choose the data root
before it can start the daemon that reads that file.

Selecting a folder creates an `AfterRay` data root beneath it. The destination
must be empty. The App asks whether to move existing data; accepting stops the
daemon, moves every entry of the data root except the control socket, and also
moves separately located development model/runtime directories. It then records
the new location and starts a fresh daemon with both `AFTERRAY_DATA_DIR` and
`AFTERRAY_MODEL_DIR` pointed into that root. The selected volume identity is
persisted too: a missing or replaced external drive is an error, never a reason
to recreate its path on the internal disk.

No migration starts the same stopped/reconfigure/restart sequence but leaves the
old root intact. A relocation fence rejects ordinary keep-alives from the moment
the App begins waiting for an in-flight start through the byte move; only the
relocation operation may restart the daemon. The synchronous file work runs off
the App's main actor. A failed move rolls moved entries back and retains the
previous preference. If any rollback step fails, the daemon stays stopped rather
than reopening a possibly incomplete old root; a repaired vault needs an app
relaunch before capture can resume. Explicit `AFTERRAY_DATA_DIR` or
`AFTERRAY_MODEL_DIR` overrides are developer-controlled and disable the UI
migration path.

Before the first item moves, the App synchronizes a recovery manifest in an
internal control directory outside both the old and selected roots. It records
both roots, their volume identities, the transaction phase, and a per-item
intent before `moveItem` plus completion after it. Startup checks this manifest
before it starts a daemon. An interrupted transition with the old preference is
returned deterministically to the source root only when every item is confirmed
at its source and absent at its destination. Any missing, duplicate, or
inaccessible item fails closed for manual recovery. A fully moved root selected
by preferences retains the manifest until a newly started daemon responds to
`status`; only then is the record removed.

## Alternatives considered

**Store the selected path in `settings.json`.** Rejected because that file is
inside the root being selected. On a later startup there is no trustworthy way
to find it before choosing which vault to open.

**Let the UI move the SQLite database and artifacts while the daemon is live.**
Rejected because the daemon has the only writer and artifact maintenance can be
active at the same time. Stopping it makes the move a single capture-free
transition without moving encryption or database access into Swift.

**Silently create a missing external-drive path.** Rejected because a detached
volume path can be recreated under `/Volumes` on the internal disk, producing a
new empty vault that looks like missing history. The volume identity check makes
the absence visible instead.

**Keep recovery state only in the relocating process.** Rejected because force
quit and power loss skip its rollback handler. A durable control record makes
the next launch either restore the source root or refuse to write either split
root.

## Consequences

**Bought:** one selected root contains the database, encrypted artifacts,
screenshots, recordings, GOPs, model downloads, and MLX runtime files. The
control socket remains on the internal disk, so the protocol's hardened socket
location and client discovery do not change.

**Cost:** a location change pauses capture and needs enough space for the
filesystem's move operation. Cross-volume moves are not atomic; the App can
roll back entries it moved before an error, and a durable manifest carries that
same fence across crashes. A storage failure that prevents confirming rollback
keeps capture stopped and requires the user to repair the two visible folders.
A disconnected external drive blocks startup rather than falling back silently.

## Related

[daemon owns the vault](2026-08-20-daemon-owns-the-vault.md) defines the process
ownership boundary this preserves. [development.md](../../../development.md)
documents the default and override paths.
