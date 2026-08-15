<p align="center">
  <img src="apps/AfterRay/Resources/AppIcon.png" width="180" height="180" alt="AfterRay app icon">
</p>

<h1 align="center">AfterRay</h1>

<p align="center">
  <strong>Your Mac's private, searchable memory.</strong><br>
  Recall what you saw, heard, and worked on — then let agents query only the
  history you choose to share.
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://afterray.com">Website</a> ·
  <a href="#install">Install</a> ·
  <a href="#using-afterray">Using AfterRay</a> ·
  <a href="#privacy">Privacy</a> ·
  <a href="docs/development.md">Development</a>
</p>

AfterRay is a local-first computer-history app for macOS. It captures your
screen and, when enabled, system and microphone audio plus foreground-app
Accessibility context. Local OCR, speech recognition, and search turn that
recording into a timeline you can return to: the exact screen, words, app, and
audio around a moment. Captures, indexes, and the vault key stay on your Mac.

## What you can do

- **Scrub back to any moment** on a native timeline, with the audio that went
  with it.
- **Search by words or by meaning** across OCR text, transcripts, window
  titles, and Accessibility context. Return lands you on the newest match,
  highlighted in place on the frame.
- **Ask questions and get citations** from a built-in assistant that can only
  read your history.
- **Keep what matters** — favorited moments survive retention cleanup.
- **Decide what is never seen** by excluding apps and websites; private
  browsing is never recorded.
- **Let your agents use it** — Claude Code, Codex, and similar tools can query
  history through the `afterray` CLI you install explicitly.

> [!IMPORTANT]
> AfterRay is a developer V0. There is no public signed build yet, so today you
> install it by building from source, and the bundled CLI is still a developer
> CLI rather than the scoped read-only gateway planned for the public release.

## Install

**Requirements:** an Apple Silicon Mac (M3 or newer recommended), macOS 15+,
and about 8 GB free for the transcription and search models — plus another
~17 GB if you want the optional local assistant.

Signed DMGs will be published on the
[Releases page](https://github.com/loro-dev/afterray/releases). Until then,
build from a checkout. You need Xcode with the Command Line Tools and a Rust
toolchain ([rustup.rs](https://rustup.rs/)):

```sh
git clone https://github.com/loro-dev/afterray.git
cd afterray

# One time: build the CLI and download the local models
cargo build -p afterray-cli --release
./scripts/download-models/download.sh

# Build and launch a signed development AfterRay.app
make v0
```

`make v0` runs in the foreground; stop it with `Control-C`. A source build
keeps its recordings in `.afterray/v0-data` inside the checkout. Everything
else about working from source is in [Development](docs/development.md).

## First launch

AfterRay walks you through four steps: pick the shortcut that opens it
(**⇧⌘Space** by default), exclude any apps and websites it should never see,
optionally install the `afterray` CLI for your coding agents, and download the
on-device models.

macOS then asks separately for **Screen & System Audio Recording**,
**Microphone**, and **Accessibility** — the last one must be enabled in System
Settings. Recording starts automatically once permissions are granted, taking a
screenshot every 10 seconds.

## Using AfterRay

| Action | How |
| --- | --- |
| Open AfterRay | ⇧⌘Space |
| Move through time | Drag the recall strip left or right |
| Play a moment's audio | Space |
| Search or ask | Type in the query field; Tab switches between **Search** and **Ask** |
| Jump to a match | Return lands on the newest match; the filmstrip holds the rest |
| Protect a moment | Favorite it |
| Stop capturing | **Pause** |
| Close AfterRay | Esc or ⌘W |

Each moment carries its screenshot, OCR text, Accessibility context,
transcript, and audio segment when one exists.

**Your data** lives in `~/Library/Application Support/AfterRay`, logs in
`~/Library/Logs/AfterRay`, and the vault key in the macOS Keychain. Metadata is
stored in an encrypted SQLCipher database and artifacts are encrypted
individually; the UI never opens the database or holds the key. The vault has a
100 GB budget — adjust it in **Settings → General → Storage**, where you can
also delete the last hour, today, or everything.

**The assistant** is chosen in **Settings → AI Models**: a built-in local
Qwen3.6-27B Q4 (~17 GB), your local Ollama, or any OpenAI-compatible `/v1`
endpoint. Capture, OCR, and search work fine with no assistant configured.

## Using it from your agent

AfterRay installs its CLI to `~/.local/bin/afterray` during onboarding, or
later from **Settings → Advanced → CLI for agents**. With that directory on
your `PATH`, agents query history directly:

```sh
afterray search 'the pricing table I saw yesterday' --json
afterray moment <moment-id> --json
afterray ask 'what did I decide about the release?'
```

This repository also ships an Agent Skill at
[`skills/afterray`](skills/afterray/SKILL.md) that teaches Claude Code, Codex,
and similar tools which commands to use.

## Privacy

Capture, storage, OCR, transcription, embeddings, and search are local. Only
two choices extend that boundary, and both are explicit:

| Path | Where data can go |
| --- | --- |
| Built-in model | Prompts and retrieved evidence stay on the Mac |
| Local Ollama | The Ollama endpoint you configured — normally a local process |
| OpenAI-compatible URL | The provider you chose; their storage, logging, and training policies apply |
| External agent through the CLI | The agent's process and any model provider it uses |

The built-in assistant is deliberately not a general-purpose computer agent. It
can search and read moments, activity, memories, OCR, and Accessibility
evidence, and has no tool for running shell commands, editing files, changing
settings, controlling capture, deleting history, or writing to the vault.

Anything returned through the CLI becomes visible to that agent. The V0 CLI is
the full developer CLI, so treat it as trusted local access rather than a
security boundary.

## Troubleshooting

**Recording never starts.** Check all three permissions in **System Settings →
Privacy & Security**. In a source build the permission belongs to the terminal
that launched AfterRay, and macOS may need that app quit and reopened.

**A model is missing.** Use **Settings → AI Models → Download Missing**, or
re-run `./scripts/download-models/download.sh` — existing files are reused.

**Something else.** **Settings → Diagnostics** reveals the log folder and
copies a diagnostic report.

## Uninstall

Quit AfterRay and move it to the Trash, then:

```sh
rm -rf ~/Library/Application\ Support/AfterRay ~/Library/Logs/AfterRay
rm -f ~/.local/bin/afterray
```

Delete the `dev.afterray.v0.vault` entry in Keychain Access to remove the vault
key; without it any leftover copy of the vault is unreadable.

## Documentation

- [Development](docs/development.md) — build from source, dev CLI, architecture,
  environment variables
- [Releasing AfterRay](docs/releasing.md) — signing, notarization, DMG
- [Vault encryption design](docs/vault-encryption-design.md) — threat model and
  key hierarchy
- [V0 implementation plan](docs/afterray-v0-implementation-plan.md) — frozen
  scope and technical decisions

## License

AfterRay is source-available, not currently OSI Open Source. Unless a file says
otherwise it is licensed under [FSL-1.1-ALv2](LICENSE): inspect, build, run,
modify, and redistribute it for permitted purposes, but do not offer it as a
competing commercial product or service. Each version turns Apache-2.0 two
years after its release. [`afterray-protocol`](crates/afterray-protocol/LICENSE)
is Apache-2.0 today so clients can implement the integration boundary. The
license grants no rights to the AfterRay name, logo, or marks.

AfterRay is still in developer preview and external contributions are not yet
being accepted.

---

<p align="center">
  <a href="https://lody.ai">
    <img src="https://lody.ai/_docs-assets/logo-96.png" width="32" height="32" alt="Lody">
  </a>
  <br>
  Developed with <a href="https://lody.ai"><strong>Lody</strong></a> — a team
  workspace for running AI coding agents in parallel, each in its own Git
  worktree.
</p>
