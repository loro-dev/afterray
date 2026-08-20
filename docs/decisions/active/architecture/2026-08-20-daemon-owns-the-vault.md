# Decision: The daemon owns the vault; the UI reaches it only over the socket

Status: active
Area: privacy
Anchors:
- crates/afterray-protocol/src/socket.rs @dec:daemon-owns-the-vault
- swift/AfterRayRecall/Sources/DaemonClient.swift @dec:daemon-owns-the-vault
Supersedes: —
Superseded-by: —

The choice predates this file. It is recorded here on 2026-08-20 from
[docs/development.md](../../../development.md) ("Architecture"),
[docs/vault-encryption-design.md](../../../vault-encryption-design.md) §1 (Accepted 2026-08-13),
and [crates/afterray-protocol/AGENTS.md](../../../../crates/afterray-protocol/AGENTS.md).

## Problem

A SwiftUI app rendering a timeline wants the data as directly as it can get it, and the shortest path is to open the SQLCipher database and the artifact files itself. Doing so would put the vault key, the decryption code, and the retention and deletion rules on both sides of the process line, in two languages, with no single place to state what is allowed.

## Decision

`afterrayd` is the sole owner of the vault. It holds the key, does every encrypt and decrypt, and owns retention, search, deletion, and model scheduling. **The UI never opens the database and never reads an encryption key.** It asks for typed read models and already-decrypted artifacts over a versioned Unix socket, and nothing else.

The split by role: Rust owns product state and policy; Swift owns the native interface and the smallest possible bridge to Apple-only capture APIs.

Three properties hold this in place:

- **One socket-path resolver.** `afterray-protocol::socket` is the only answer to "where does the daemon listen", used by the daemon, the CLI, and the app. The daemon and the CLI once answered it separately and both fell back to `$TMPDIR` — world-writable, so any process could pre-bind the path, and not where the app's daemon actually listened. The module doc records this; the resolver never falls back to a temporary directory, and never keys dev detection off the working directory, which is attacker-chosen.
- **Filesystem permissions on the socket are the entire trust boundary.** Artifact bytes cross it already decrypted. There is nothing behind the socket to check afterwards.
- **Strict version equality, no negotiation.** Every response carries `PROTOCOL_VERSION`; the Swift client hard-rejects a mismatch. A stale client cannot half-speak to a newer daemon and reach the vault through a gap in the vocabulary.

Peers are not equal across that boundary: `cli_access` classifies each request Query / Evidence / Privileged, and the app is recognised by socket audit token plus code signature, never by path.

## Alternatives considered

Not recorded; reconstructed from the sources in the header, which state the split as intended without listing what it beat. What the sources do support:

**Letting Swift read the vault directly** is the option the decision names and forbids, but no record shows it was weighed with its trade-offs rather than ruled out on principle. The `$TMPDIR` history shows the related failure — two components independently deciding where the boundary is — which is evidence for the single-resolver rule, not for the ownership rule itself.

**FileVault instead of application-level encryption** was considered and declined, but that is the neighbouring encryption decision ([vault-encryption-design.md](../../../vault-encryption-design.md) §1), not this one.

Do not read this section as "no alternatives existed". It means the record does not have them, and inventing them would be worse than admitting the gap.

## Consequences

**Bought:** one place where "who may read what" is decided and can be audited. The key never leaves one process, the CLI and agents are constrained by the same classifier as the app, and a privacy rule such as `delete_history` has exactly one implementation to be correct in.

**Cost:** every read model the UI needs is a protocol change — a request variant, a wire-shape test, a version bump, and a mirrored Swift type. That friction is the decision working, not a defect, and it is why the protocol has ~50 request variants. Artifact bytes are decrypted in the daemon and copied across the socket rather than mapped, so large reads pay a copy; `ArtifactPayload` zeroizes on drop because of it.

**Do not "fix" the asymmetry:** the Swift client still lists the retired `$TMPDIR` path as a last-resort fallback. The hardened Rust behavior is the correct one; aligning Rust to Swift would undo this decision.

## Related

[context/wire-protocol.md](../../../../context/wire-protocol.md) — what crosses the socket today.
