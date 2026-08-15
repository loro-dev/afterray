# Developing AfterRay

Everything needed to build, run, and hack on AfterRay from a checkout. If you
only want to *use* the app, read the [README](../README.md) instead.

## Prerequisites

- Apple Silicon Mac (M3 or newer recommended), macOS 15 or newer.
- Xcode and the Xcode Command Line Tools.
- A current Rust toolchain — install from [rustup.rs](https://rustup.rs/) if
  `cargo --version` is not already available.
- Around 8 GB of free space for the default model set (Qwen3-ASR + embeddings),
  plus space for recordings. The optional built-in assistant is another ~17 GB
  (Qwen3.6-27B Q4).

Model download and inference are compiled into AfterRay. There is no Python,
no Homebrew `ffmpeg`, and no external `llama.cpp` binary.

## First-time setup

```sh
cargo build -p afterray-cli --release
./scripts/download-models/download.sh
```

The script is a thin wrapper around `afterray download`; it writes weights into
`.afterray/models` and resumes rather than re-downloading. Fetch a single pack
with `AFTERRAY_DOWNLOAD_ONLY=<pack> ./scripts/download-models/download.sh`.

## Everyday commands

```sh
# Watch the complete app. Successful builds are signed and relaunched;
# failed builds leave the previous instance running.
make dev

# Storybook-like mock-data UI loop. No recording permissions, no real data.
make dev-ui

# Open the last successful build without rebuilding, or stop app + daemon.
make open
make stop

# One-shot build and launch of a signed development AfterRay.app
make v0

# Build everything without launching
make v0-build

# Daemon only, for CLI work
make v0-daemon

# Build a local-only, ad-hoc signed, release-shaped DMG
make release-local
```

`make v0` and `make dev` assemble the bundle into `.afterray-dev/AfterRay.app`.
Recorded data persists between runs at `.afterray/v0-data`. Stop a foreground
run with `Control-C` in the terminal that launched it.

Start from an empty, disposable vault instead — this never touches
`.afterray/v0-data`:

```sh
./scripts/run-v0.sh --ephemeral
```

## Tests and lint

```sh
cargo test --workspace
swift test
cargo clippy --workspace --all-targets -- -D warnings
```

## Repository layout

```text
apps/                         Swift app, Visual Lab, capture shim
crates/                       Rust daemon, CLI, store, protocol and adapters
swift/                        Reusable Recall UI and mock data
scripts/download-models/      Thin wrapper around `afterray download`
skills/afterray/              Agent Skill describing the read-only CLI surface
site/                         afterray.com marketing site
docs/                         Product specification and implementation notes
```

## Architecture

```text
AfterRay.app (SwiftUI)                 afterray CLI (Rust)
          │                                      │
          └──────── versioned Unix socket ───────┘
                                 │
                          afterrayd (Rust)
             ┌───────────────────┼────────────────────┐
             │                   │                    │
       Capture scheduler   Encrypted vault      Model queue
             │            SQLite + artifacts   OCR/ASR/Emb/LLM
             │                                        │
   macOS capture backend                    Local process adapter
             │                                        │
  ScreenCaptureKit + AX shim          Vision + MLX + native runtimes
```

The split is intentional:

- **Rust owns product state and policy:** sessions, scheduling, backpressure,
  retention, encryption, search, model jobs, IPC, and the CLI.
- **Swift owns the native interface:** recall interaction, rendering, playback,
  and the smallest possible bridge to Apple-only capture APIs.
- **The UI never opens the database or reads encryption keys.** It requests
  typed read models and decrypted artifacts from the daemon.

The vault key is created in the macOS Keychain under the service
`dev.afterray.v0.vault`. Metadata lives in an encrypted SQLCipher database,
while screenshot and audio artifacts are encrypted individually before being
persisted. Every response carries a protocol version that clients check
strictly, so a stale CLI cannot talk to a newer daemon.

The accepted threat model, key hierarchy, runtime locking rules, and V0 versus
release requirements are documented in the
[Vault encryption design](vault-encryption-design.md).

## Developer CLI and daemon

Run only the daemon when developing the CLI:

```sh
make v0-daemon
```

The runner prints the temporary socket path and ready-to-copy commands for a
second terminal. With `AFTERRAY_SOCKET` set to that path, read commands
include:

```sh
afterray status --json
afterray sessions list --json
afterray moments <session-id> --json
afterray moment <moment-id> --json
afterray search 'weekly planning' --json
afterray search 'bug' --from-ms 0 --to-ms 9999999999999 --json
afterray evidence ocr <moment-id> --json
afterray evidence ax <moment-id> --json
afterray activity --from-ms … --to-ms … --json
afterray memories --from-ms … --to-ms … --json
afterray models --json
afterray jobs list --json
```

When running from the repository, replace `afterray` with
`target/debug/afterray` (or `target/release/afterray`).

Without `AFTERRAY_SOCKET`, the CLI resolves the socket the same way the daemon
does: a binary inside `target/{debug,release}` uses
`<checkout>/.afterray-dev/afterray.sock`, and an installed copy uses
`~/Library/Application Support/AfterRay/afterray.sock`. Nothing falls back to
`/tmp`, where any process could have bound the path first.

The V0 developer binary also contains operational commands for development and
direct user actions: starting or stopping capture, changing settings, managing
favorites, clearing history, downloading models, retrying jobs, and requesting
summaries. Those commands are **not** part of the planned public Agent API.

### CLI on PATH for external agents

AfterRay can copy the bundled CLI to `~/.local/bin/afterray` from first-run
onboarding or **Settings → Advanced → CLI for agents**. Make sure the directory
is on your shell `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The current V0 install copies the complete developer CLI, including its
operational commands. Treat it as trusted local developer access, not as a
security boundary, and do not expose it to an Agent you do not trust.

Before public distribution, external Agent access moves behind a
server-enforced, read-only Context Gateway with per-client scopes, explicit
approval, revocation, result limits, and a local access log. The vault key
stays in the daemon; external tools never open the database directly.

## Visual development

The recall surface can be developed without recording real user data:

```sh
make visual-lab        # swift run afterray-visual-lab
make settings-lab      # settings surface with model rows
make chat-lab          # conversational overlay
make snapshots         # offscreen PNGs, override with OUT=/tmp/x
make onboarding        # rebuild and force the real first-run flow
```

The Visual Lab includes empty, short, long-day, processing, and favorites
scenarios. See [the Visual Lab workflow](visual-lab-workflow.md) for details.
To reveal the in-app replay control, open **Settings → Advanced**, type `loro`,
then enable **Developer Options**. Its replay action does not delete the
onboarding completion preference.

## Logs and data locations

| What | Development checkout | Packaged build |
| --- | --- | --- |
| Vault and artifacts | `.afterray/v0-data` | `~/Library/Application Support/AfterRay` |
| Model weights | `.afterray/models` | `~/Library/Application Support/AfterRay/Models` |
| Logs | `.afterray/logs/afterray.log` | `~/Library/Logs/AfterRay/afterray.log` |
| Socket | `.afterray-dev/afterray.sock` | `~/Library/Application Support/AfterRay/afterray.sock` |

Override the log directory with `AFTERRAY_LOG_DIR`. **Settings → Diagnostics**
can reveal the folder or copy a diagnostic report.

## Environment variables

| Variable | Purpose | Default |
| --- | --- | --- |
| `AFTERRAY_DATA_DIR` | Persistent vault location | `.afterray/v0-data` through the V0 runner |
| `AFTERRAY_SOCKET` | Unix socket shared by clients and daemon | Runner-generated temporary path |
| `AFTERRAY_CAPTURE_INTERVAL_SECONDS` | Screenshot interval | `10` |
| `AFTERRAY_GOP_ARCHIVE` | Pack cold stills into closed-GOP AV1 | `1` |
| `AFTERRAY_GOP_KEYINT` | Max frames per closed GOP (`6` `12` `20` `24` `30`) | `30` |
| `AFTERRAY_GOP_REQUIRE_AC` | Only encode while on AC power | `0` |
| `AFTERRAY_MODEL_WORKER` | Rust inference worker | Bundled `afterray-model-worker` |
| `AFTERRAY_MODEL_DIR` | Weight directory | `.afterray/models` |
| `AFTERRAY_ASR_MODEL` | Qwen3-ASR snapshot directory | `$AFTERRAY_MODEL_DIR/Qwen3-ASR-1.7B` |
| `AFTERRAY_ASR_REPOSITORY` | Hugging Face repo for ASR | `Qwen/Qwen3-ASR-1.7B` |
| `AFTERRAY_EMBEDDING_MODEL` | nomic GGUF path | `$AFTERRAY_MODEL_DIR/nomic-embed-text-v1.5.Q4_K_M.gguf` |
| `AFTERRAY_LLM_MODEL` | Optional built-in instruct GGUF path | `$AFTERRAY_MODEL_DIR/<AFTERRAY_LLM_FILE>` |
| `AFTERRAY_LLM_REPOSITORY` | Hugging Face repo for the built-in GGUF | `unsloth/Qwen3.6-27B-GGUF` |
| `AFTERRAY_LLM_FILE` | GGUF filename in that repo | `Qwen3.6-27B-Q4_K_M.gguf` |
| `AFTERRAY_LLM_PROVIDER` | Assistant backend (`builtin`, `ollama`, `openai_compatible`) | persisted Settings value, else `builtin` |
| `AFTERRAY_LLM_BASE_URL` | Ollama origin or OpenAI-compatible `/v1` URL | `http://127.0.0.1:11434` for Ollama |
| `AFTERRAY_LLM_CHAT_MODEL` | Remote chat model id | persisted Settings value |
| `AFTERRAY_LLM_API_KEY` | Optional bearer token for OpenAI-compatible URLs | persisted Settings value |
| `AFTERRAY_LLM_N_CTX` | llama.cpp context length | `8192` |
| `AFTERRAY_LLM_MAX_TOKENS` | Generation cap | `512` |
| `AFTERRAY_CODESIGN_IDENTITY` | Signing identity for dev and release builds | First `Developer ID Application` identity |
| `AFTERRAY_NOTARY_PROFILE` | `notarytool` keychain profile used by `make release` | — |

## Releasing

Production distribution uses a Developer ID-signed, hardened, notarized DMG
containing the Swift app and all bundled Rust/Swift helpers. See
[Releasing AfterRay](releasing.md) for certificate setup, commands, artifacts,
and verification details.

## V0 boundaries

V0 intentionally does not include activity-triggered capture, meeting
detection, subscriptions, production App Store packaging, multi-device sync,
the scoped public Context Gateway for third-party Agents, or Windows support.

The next product milestone is focused on the recall experience itself: making
navigation through hours, days, and eventually months feel immediate and
visually distinctive.

For the frozen V0 scope and technical decisions, read the
[V0 implementation plan](afterray-v0-implementation-plan.md).
