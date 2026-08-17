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
  <a href="https://afterray.com/download/latest">Download for macOS</a> ·
  <a href="#cli-for-agents">CLI for agents</a>
</p>

AfterRay is a local-first computer-history app for macOS. It captures your
screen and, when enabled, system and microphone audio plus foreground-app
Accessibility context, then turns them into a timeline you can search and
return to. Everything AfterRay captures and indexes stays local on your Mac.

Download the public signed build from
[afterray.com/download/latest](https://afterray.com/download/latest). You do
not need to build AfterRay or run separate first-launch setup commands.

Choose local models, such as your own Ollama, or any AI provider with an
OpenAI-compatible API.

## What you can do

- **Rewind your work.** Browse a native timeline back to the exact screen,
  words, app context, and audio around a moment.
- **Find the right moment.** Search OCR, transcripts, window titles, and
  Accessibility context by exact words or meaning, then land on the match.
- **Ask with evidence.** The built-in assistant answers from your history and
  cites the moments it used.
- **Summarize your work locally.** A local model turns your activity into a
  work log, so the day is easier to review than a raw timeline.
- **Turn history into better workflows (WIP).** As it accumulates, models will
  help improve your process and distill reusable Skills for your agents.

## CLI for agents

AfterRay can install an `afterray` CLI from **Settings → Advanced → CLI for
agents**. It lets tools such as Claude Code and Codex query summaries and
search hits. Original evidence (screenshots, OCR, accessibility trees) stays
off until you allow it for 30 minutes in that same settings section. Start
agents with `afterray docs`. This repository also includes an Agent Skill at
[`skills/afterray`](skills/afterray/SKILL.md).

The built-in assistant receives only allowlisted, read-only history tools. A
local model keeps prompts and retrieved evidence on this Mac; a remote model
provider receives them as part of each request. The complete boundary and its
accepted risks are documented in the
[agent harness threat model](docs/harness-threat-model.md).

## License

AfterRay is source-available, not currently OSI Open Source. Unless a file says
otherwise it is licensed under [FSL-1.1-ALv2](LICENSE): inspect, build, run,
modify, and redistribute it for permitted purposes, but do not offer it as a
competing commercial product or service. Each version turns Apache-2.0 two
years after its release. [`afterray-protocol`](crates/afterray-protocol/LICENSE)
is Apache-2.0 today so clients can implement the integration boundary. The
license grants no rights to the AfterRay name, logo, or marks.

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
