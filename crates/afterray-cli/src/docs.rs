//! Agent-facing documentation served by `afterray docs`.
//!
//! The Skill tells agents to start here so the prose cannot drift from the
//! command tree.

use anyhow::Context;

#[derive(Clone, Copy)]
struct Page {
    id: &'static str,
    title: &'static str,
    body: &'static str,
}

const PAGES: &[Page] = &[
    Page {
        id: "overview",
        title: "AfterRay CLI",
        body: OVERVIEW,
    },
    Page {
        id: "permissions",
        title: "Permissions",
        body: PERMISSIONS,
    },
    Page {
        id: "search",
        title: "search",
        body: SEARCH,
    },
    Page {
        id: "moment",
        title: "moment",
        body: MOMENT,
    },
    Page {
        id: "activity",
        title: "activity",
        body: ACTIVITY,
    },
    Page {
        id: "memories",
        title: "memories",
        body: MEMORIES,
    },
    Page {
        id: "slot",
        title: "slot",
        body: SLOT,
    },
    Page {
        id: "evidence",
        title: "evidence",
        body: EVIDENCE,
    },
    Page {
        id: "frame",
        title: "frame",
        body: FRAME,
    },
    Page {
        id: "sessions",
        title: "sessions",
        body: SESSIONS,
    },
    Page {
        id: "status",
        title: "status",
        body: STATUS,
    },
];

const OVERVIEW: &str = "\
AfterRay CLI is a read-only query layer over this Mac's computer history.

Start here:
  afterray docs --json
  afterray docs permissions
  afterray docs <command>

Query commands (always allowed once the CLI is installed):
  search, moment, moments, sessions, activity, memories,
  slot day, slot history, status

Evidence commands (default denied; user must open a 30-minute window
in AfterRay → Settings → Advanced → CLI for agents):
  evidence ocr, evidence ax, frame, slot card

Not available on the CLI at all (use the AfterRay app):
  recording, deleting history, changing settings, ask, chat

Prefer --json on every command. Never open the vault, the database,
or the Keychain.

Typical flow:
  1. slot day / slot history for “what did I do today / that week”
  2. search to locate a moment id
  3. moment for metadata (app, time, window)
  4. evidence / frame only if the user enabled the 30-minute window
";

const PERMISSIONS: &str = "\
Two surfaces, one switch.

Query (default on, no switch):
  Locator and summary reads. search never includes OCR or screenshots.
  moment omits ocr_text and transcript_text. slot day / slot history
  return T2 summaries, not T1 screen-text cards.

Evidence (default off):
  Screenshots, OCR, accessibility trees, original audio, T1 slot cards.
  Settings has two states only: Off, or On for 30 minutes. The daemon
  expires the window; there is no permanent CLI evidence grant.

When evidence is off, those commands fail with:
  evidence_access_disabled: ...
Tell the user to open AfterRay → Settings → Advanced → CLI for agents
and choose “Allow for 30 minutes”. Do not retry as a different command
that might dump the same bytes.

Writes, ask, and chat are not on the CLI. They fail with:
  cli_forbidden: this action is only available in the AfterRay app.

`afterray status --json` includes cli_evidence_until_ms when a window
is open.
";

const SEARCH: &str = "\
afterray search '<query>' [--from-ms <ms>] [--to-ms <ms>] [--limit N] --json

Permission: Query (always).

Use to locate moments. Returns moment_id, time, source, score.
The text field is empty — search is a locator, not a reader.
Need the screen or transcript? That is evidence (separate permission).

Prefer slot day / slot history for “what did I do today”.
";

const MOMENT: &str = "\
afterray moment <moment-id> --json
afterray moment --at-ms <ms> --json
afterray moments <session-id> --json

Permission: Query (always).

Returns metadata: id, time, app, window, url, session.
ocr_text and transcript_text are omitted. Use `evidence ocr` when
the 30-minute window is open.
";

const ACTIVITY: &str = "\
afterray activity --from-ms <ms> --to-ms <ms> [--limit N] --json

Permission: Query (always).

Consecutive time on the same app / URL / document / window.
Answers “where was I”, not “what did the screen say”.
";

const MEMORIES: &str = "\
afterray memories --from-ms <ms> --to-ms <ms> [--limit N] --json

Permission: Query (always).

Short persisted episode summaries (a page or window, often ≥45s)
with a one- or two-line `summary`. Finer than a slot, coarser than
a moment.
";

const SLOT: &str = "\
afterray slot day --at-ms <ms> --json
afterray slot history [--before-ms <ms>] [--limit N] --json
afterray slot card --at-ms <ms> --json

slot day / slot history — Permission: Query.
  T2 summaries for wall-clock slots (10 minutes on new history;
  older vaults may still have 30-minute rows before their cutover).
  Trust each row's slot_start_ms / slot_end_ms. Page history with
  next_before_ms. This is the right first call for a day or week.

slot card — Permission: Evidence.
  Deterministic T1 card: deduplicated screen text, selected text,
  typing. Denied unless the 30-minute window is open. If T2 is
  missing, do not treat slot day as a T1 dump — it stays summary-only.
";

const EVIDENCE: &str = "\
afterray evidence ocr <moment-id> --json
afterray evidence ocr --at-ms <ms> --json
afterray evidence ax <moment-id> [--full] --json

Permission: Evidence (30-minute window).

OCR text / accessibility digest (or full tree with --full) for one
moment. Default denied. On evidence_access_disabled, tell the user
to enable the window in Settings. Do not fall back to slot card.
";

const FRAME: &str = "\
afterray frame --moment-id <id> [--out <path>]
afterray frame --at-ms <ms> [--out <path>]

Permission: Evidence (30-minute window).

Writes the nearest captured frame to a JPEG (or IVF) file.
Default denied. Same Settings window as evidence ocr.
";

const SESSIONS: &str = "\
afterray sessions list --json

Permission: Query (always).

Recording sessions with start / end times. Use a session id with
`moments` to list captures in that session.
";

const STATUS: &str = "\
afterray status --json

Permission: Query (always).

Daemon connectivity, versions, recording state, and
cli_evidence_until_ms when a window is open.
";

pub fn run(topic: Option<&str>, json: bool) -> anyhow::Result<()> {
    if json {
        print_json(topic)?;
        return Ok(());
    }
    let page = resolve(topic)?;
    println!("{}\n\n{}", page.title, page.body.trim());
    Ok(())
}

fn resolve(topic: Option<&str>) -> anyhow::Result<&'static Page> {
    let Some(topic) = topic.map(str::trim).filter(|value| !value.is_empty()) else {
        return Ok(&PAGES[0]);
    };
    let key = topic.to_ascii_lowercase();
    let key = key.strip_prefix("afterray ").unwrap_or(&key);
    PAGES
        .iter()
        .find(|page| page.id == key || page.title.eq_ignore_ascii_case(key))
        .or_else(|| match key {
            "ocr" | "ax" | "evidence ocr" | "evidence ax" => {
                PAGES.iter().find(|page| page.id == "evidence")
            }
            "slot day" | "slot history" | "slot card" | "day" | "t1" | "t2" => {
                PAGES.iter().find(|page| page.id == "slot")
            }
            "permission" | "access" => PAGES.iter().find(|page| page.id == "permissions"),
            _ => None,
        })
        .with_context(|| {
            format!(
                "no docs page `{topic}`. Try: {}",
                PAGES
                    .iter()
                    .map(|page| page.id)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })
}

fn print_json(topic: Option<&str>) -> anyhow::Result<()> {
    if let Some(topic) = topic {
        let page = resolve(Some(topic))?;
        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "id": page.id,
                "title": page.title,
                "body": page.body.trim(),
            }))?
        );
        return Ok(());
    }
    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "pages": PAGES.iter().map(|page| {
                serde_json::json!({
                    "id": page.id,
                    "title": page.title,
                    "body": page.body.trim(),
                })
            }).collect::<Vec<_>>(),
        }))?
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::resolve;

    #[test]
    fn default_page_is_overview() {
        assert_eq!(resolve(None).unwrap().id, "overview");
    }

    #[test]
    fn aliases_resolve() {
        assert_eq!(resolve(Some("permissions")).unwrap().id, "permissions");
        assert_eq!(resolve(Some("evidence ocr")).unwrap().id, "evidence");
        assert_eq!(resolve(Some("slot day")).unwrap().id, "slot");
        assert_eq!(resolve(Some("t1")).unwrap().id, "slot");
        assert!(resolve(Some("ask")).is_err());
    }
}
