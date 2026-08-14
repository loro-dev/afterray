# AfterRay

**AfterRay** — a ray that persists after the day is gone.

**A private timeline for everything you saw and heard on your Mac.**

AfterRay continuously captures your screen, system audio, microphone audio,
and the foreground app's Accessibility tree. Local OCR and speech recognition turn those
captures into searchable context. A native recall timeline lets you drag back
through the day, recover the exact screen you saw, and play the audio around
that moment.

Everything runs on your Mac. Captures, indexes, model inputs, and model outputs
stay local.

> [!IMPORTANT]
> AfterRay is currently a developer V0, built to prove the complete local
> capture → understanding → recall loop on one Mac. It is not yet packaged or
> hardened for general distribution.

## What works today

- Automatic recording after the required macOS permissions are approved.
- A native macOS timeline with horizontal drag-to-recall.
- Screenshot previews, OCR text, transcripts, and audio playback by moment.
- Full-text and local embedding search across captured evidence, including the
  titles of the windows you had open.
- A search result set you travel rather than read: pressing return lands on the
  newest match, the matched words are highlighted in place on the frame, and a
  filmstrip of matched frames replaces the timeline while the search is open.
- Local session summaries through a built-in GGUF, local Ollama, or an
  OpenAI-compatible endpoint.
- Favorites that survive automatic retention cleanup.
- An encrypted local vault backed by SQLCipher and XChaCha20-Poly1305.
- A Rust CLI that exposes the same API used by the Swift app.
- A standalone Visual Lab for iterating on recall UI with deterministic mock
  data.

## Requirements

- Apple Silicon Mac (M3 or newer recommended).
- macOS 15 or newer.
- Around 8 GB of free space for the default development model set (Qwen3-ASR
  + embeddings), plus space for recordings. The optional built-in assistant is
  another ~17 GB (Qwen3.6-27B Q4). Qwen 3.7 has no local GGUF; use Ollama
  or an OpenAI-compatible URL for a hosted 3.7.
- Xcode and the Xcode Command Line Tools.
- A current Rust toolchain.

Install Rust from [rustup.rs](https://rustup.rs/) if `cargo --version` is not
already available. Model download and inference are compiled into AfterRay;
they do not use Python, Homebrew `ffmpeg`, or `llama.cpp` binaries.

## Quick start

Clone the repository and enter it, then let AfterRay download its own local
runtime and model files. This is required once:

```sh
cargo build -p afterray-cli --release
./scripts/download-models/download.sh
```

Build and launch AfterRay:

```sh
make v0
```

The command assembles and launches a signed development `AfterRay.app`. On its
first launch the app immediately requests Screen & System Audio Recording,
Microphone, and Accessibility access. macOS presents these as separate system
approvals; Accessibility must be enabled in System Settings. AfterRay starts
recording automatically as soon as all three are enabled.

Recorded data persists between runs at:

```text
.afterray/v0-data
```

Use a disposable vault for testing with:

```sh
./scripts/run-v0.sh --ephemeral
```

Stop AfterRay by pressing `Control-C` in the terminal that launched it.

## Using the app

1. Approve the three macOS permissions and use your Mac normally.
2. Use **Pause** only when you intentionally want capture to stop.
3. Drag the recall strip left or right to move through captured moments.
4. Inspect OCR, Accessibility, and transcript evidence for the selected moment.
5. Play its audio segment when one is available.
6. Favorite an important moment to protect it from retention cleanup.
7. Search for words or concepts to jump back to matching evidence.

Screenshots are captured every 10 seconds in V0. The interval can be changed
with `AFTERRAY_CAPTURE_INTERVAL_SECONDS`.

## Local models

AfterRay downloads ASR and embedding weights into `.afterray/models` and owns
those inference processes. Overlay Q&A can use one of three assistant sources,
chosen in **Settings → AI Models**:

- **Built-in** — AfterRay downloads Qwen3.6-27B Q4 (~17 GB) and runs it
  with the bundled llama.cpp worker.
- **Ollama** — AfterRay probes `http://127.0.0.1:11434`, lists installed chat
  models, and sends OpenAI-compatible `/v1/chat/completions` requests. Prefer
  a local `qwen3.6` tag when one is installed.
- **OpenAI compatible** — any `/v1` chat-completions URL, optional API key,
  and model name. This is the path for hosted Qwen 3.7 (no open weights).

Rust still owns scheduling, retries, cancellation, and result storage.
Capture, OCR, and search keep working if no assistant is configured.

Qwen 3.7 Max is API-only as of August 2026. Do not expect `ollama pull
qwen3.7` or a local GGUF to exist. Use a hosted OpenAI-compatible endpoint, or
run a local Qwen 3.6 from Ollama.

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

The vault key is created in macOS Keychain. Metadata is stored in an encrypted
SQLCipher database, while screenshot and audio artifacts are encrypted
individually before being persisted.

The accepted threat model, key hierarchy, runtime locking rules, and V0 versus
release requirements are documented in the
[Vault encryption design](docs/vault-encryption-design.md).

## CLI and daemon

Run only the daemon when developing the CLI:

```sh
make v0-daemon
```

The runner prints the temporary socket path and ready-to-copy commands for a
second terminal. With `AFTERRAY_SOCKET` set to that path, the main commands are:

```sh
afterray status --json
afterray record start
afterray record stop
afterray sessions list --json
afterray moments <session-id> --json
afterray moment <moment-id> --json
afterray search 'weekly planning' --json
afterray search 'bug' --from-ms 0 --to-ms 9999999999999 --json
afterray evidence ocr <moment-id> --json
afterray evidence ax <moment-id> --json
afterray activity --from-ms … --to-ms … --json
afterray memories --from-ms … --to-ms … --json
afterray favorite add <moment-id>
afterray favorite remove <moment-id>
afterray summarize <session-id> --json
afterray models --json
afterray jobs list --json
```

### PATH install for external agents

AfterRay can copy the bundled CLI to `~/.local/bin/afterray` so Claude Code,
Codex, Cursor, and similar tools can query local history without MCP.

- First-run onboarding offers **Install CLI**
- Settings → Advanced → **CLI for agents** reinstalls later
- Ensure `~/.local/bin` is on your shell `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The CLI is read-mostly agent surface (search, moment detail, OCR boxes, AX
digest/tree, activity spans, memories). The vault key stays in the daemon;
external tools never open the database.

When running from the repository, replace `afterray` with
`target/debug/afterray`.

## Visual development

The recall surface can be developed without recording real user data:

```sh
swift run afterray-visual-lab
```

The Visual Lab includes empty, short, long-day, processing, and favorites
scenarios plus a Settings surface for iterating the settings page without
opening the full overlay. See [the Visual Lab workflow](docs/visual-lab-workflow.md)
for details.

Logs append to `.afterray/logs/afterray.log` in a development checkout, or
`~/Library/Logs/AfterRay/afterray.log` in a packaged build. Override with
`AFTERRAY_LOG_DIR`. Settings → Diagnostics can reveal the folder or copy a
report.

## Development

```sh
# Watch the complete app. Successful builds are signed and relaunched;
# failed builds leave the previous instance running.
make dev

# Storybook-like mock-data UI loop. No recording permissions or real data.
make dev-ui

# Open the last successful build without rebuilding, or stop app + daemon.
make open
make stop

# Build everything without launching the app
make v0-build

# Run the Rust test suite
cargo test --workspace

# Run the Swift test suite
swift test

# Treat Rust warnings as errors
cargo clippy --workspace --all-targets -- -D warnings
```

Repository layout:

```text
apps/                         Swift app, Visual Lab, capture shim
crates/                       Rust daemon, CLI, store, protocol and adapters
swift/                        Reusable Recall UI and mock data
scripts/download-models/      Thin wrapper around `afterray download`
docs/                         Product specification and implementation notes
```

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `AFTERRAY_DATA_DIR` | Persistent vault location | `.afterray/v0-data` through the V0 runner |
| `AFTERRAY_SOCKET` | Unix socket shared by clients and daemon | Runner-generated temporary path |
| `AFTERRAY_CAPTURE_INTERVAL_SECONDS` | Screenshot interval | `10` |
| `AFTERRAY_GOP_ARCHIVE` | Pack cold stills into closed-GOP AV1 | `1` |
| `AFTERRAY_GOP_KEYINT` | Max frames per closed GOP (`6` `12` `20` `24` `30`) | `30` |
| `AFTERRAY_GOP_REQUIRE_AC` | Only encode while on AC power | `0` |
| `AFTERRAY_MAX_UNSTARRED_MOMENTS` | Retention ceiling for non-favorites | `10000` |
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

## Troubleshooting

### Recording fails immediately

Open **System Settings → Privacy & Security** and verify all three:

- **Screen & System Audio Recording**
- **Microphone**
- **Accessibility**

Enable the terminal application that launched AfterRay, or the AfterRay helper
if macOS lists it separately. macOS may require that application to be quit and
reopened before the permission becomes active.

### A model is missing

Resume the model setup script. Existing downloads are reused:

```sh
cargo build -p afterray-cli --release
./scripts/download-models/download.sh
```

### Start with an empty disposable vault

```sh
./scripts/run-v0.sh --ephemeral
```

This does not modify the persistent vault at `.afterray/v0-data`.

## V0 boundaries

V0 intentionally does not include activity-triggered capture, meeting
detection, subscriptions, production App Store packaging, multi-device sync,
third-party agent access, or Windows support. Model setup is still a developer
script rather than the final in-app download experience.

The next product milestone is focused on the recall experience itself: making
navigation through hours, days, and eventually months feel immediate and
visually distinctive.

For the frozen V0 scope and technical decisions, read the
[V0 implementation plan](docs/afterray-v0-implementation-plan.md).

## Project status

AfterRay is currently a private development project. External contributions are
not being accepted during V0, and no public source license has been selected in
this repository yet.
