---
name: afterray
description: >
  Query this Mac's local AfterRay computer history — screens, system audio,
  transcripts, OCR, activity spans, and on-device answers with citations.
  Use when the user asks what they saw, heard, decided, searched, or did
  earlier; or mentions AfterRay, recall, computer history, replay, or the
  afterray CLI.
---

# AfterRay

AfterRay is local-first computer history on this Mac. Query it with the `afterray` CLI. Never open the vault, the database, or the Keychain.

## Prerequisite

`afterray` must be on `PATH` (the app installs it to `~/.local/bin`). If the binary is missing, tell the user to open AfterRay and turn on **Settings → Advanced → CLI for agents**.

Prefer `--json` on every command except when `afterray ask` is the whole answer.

## Read commands

```sh
afterray search '<query>' --json
afterray search '<query>' --from-ms <ms> --to-ms <ms> --json
afterray moment <moment-id> --json
afterray evidence ocr <moment-id> --json
afterray evidence ax <moment-id> --json
afterray activity --from-ms <ms> --to-ms <ms> --json
afterray memories --from-ms <ms> --to-ms <ms> --json
afterray ask '<question>'
```

### Whole days

Half-hour slots the daemon has already summarised — cheaper and better
structured than searching a day span moment by moment.

```sh
afterray slot day --at-ms <ms> --json          # every occupied slot of that day
afterray slot history --before-ms <ms> --limit 7 --json
```

`slot history` returns newest first; pass the `next_before_ms` from the previous
response to page further back.

### Follow-up turns

`ask` is one-shot. To keep context across turns, use a conversation:

```sh
afterray chat send '<message>' --json
afterray chat send '<message>' --conversation <conversation-id> --json
afterray chat list --json
afterray chat history <conversation-id> --json
```

## How to answer

1. Search or `ask` first. Follow a hit with `moment` / `evidence` only when the user needs the original screen or transcript.
2. For "what did I do today / that week", reach for `slot day` or `slot history` before `search`.
3. Cite clock time and app (and a moment id if you have one).
4. Do not run mutating or expensive commands unless the user explicitly asks: `record`, `favorite`, `history` (deletes), `chat delete`, `settings`, `download`, and the model passes `slot summarize` / `slot backfill` / `summarize`.

The vault key stays in the daemon. Agents never touch the database.
