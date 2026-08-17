---
name: afterray
description: >
  Query this Mac's local AfterRay computer history — summaries, activity,
  memories, and (only if the user opened a 30-minute window) original
  screenshots, OCR, and accessibility trees. Use when the user asks what
  they saw, heard, decided, searched, or did earlier; or mentions AfterRay,
  recall, computer history, replay, or the afterray CLI.
---

# AfterRay

AfterRay is local-first computer history on this Mac. Query it with the
`afterray` CLI. Never open the vault, the database, or the Keychain.

## Prerequisite

`afterray` must be on `PATH` (the app installs it to `~/.local/bin`). If the
binary is missing, tell the user to open AfterRay and turn on
**Settings → Advanced → CLI for agents**.

**Read the docs first.** They are the source of truth for commands,
permissions, and errors:

```sh
afterray docs --json
afterray docs permissions
afterray docs <command>
```

Prefer `--json` on every command except `docs`.

## How to answer

1. `afterray docs` if you have not read it this session.
2. For a day or week, `slot day` / `slot history` before `search`.
3. `search` only locates a moment id. It does not return OCR or screenshots.
4. Follow a hit with `moment` for metadata. Do not expect `ocr_text`.
5. Original evidence (`evidence ocr` / `evidence ax` / `frame` / `slot card`)
   is **off by default**. If the daemon returns `evidence_access_disabled`,
   tell the user to open **Settings → Advanced → CLI for agents** and choose
   **Allow for 30 minutes**. Do not invent another command to dump the same
   bytes.
6. Cite clock time and app (and a moment id if you have one).
7. Recording, deleting history, changing settings, `ask`, and `chat` are not
   on the CLI. They belong in the AfterRay app.

The vault key stays in the daemon. Agents never touch the database.
