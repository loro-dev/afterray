//! Read-only history tools shared by CLI handlers and the internal agent loop.

use afterray_models::ModelQueue;
use afterray_protocol::{AxEvidence, Moment, OcrEvidence, OcrRegion, local_calendar_day_bounds_ms};
use afterray_store::{ReadOnlyVault, parse_accessibility_digest};
use chrono::Local;
use serde_json::{Value, json};

use afterray_harness::ContextBudget;
use crate::search_hits;
use afterray_harness::{Budgeted, truncate_head};


const DEFAULT_SEARCH_LIMIT: usize = 8;
const DEFAULT_LIST_LIMIT: usize = 40;
const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 86_400_000;

#[derive(Clone)]
pub struct ToolHost<'a> {
    /// Reads only. The agent's tools cannot write to the vault because the
    /// handle they hold has no writing methods — see `afterray_store::readonly`.
    pub store: ReadOnlyVault<'a>,
    pub models: &'a ModelQueue,
    /// The wall clock for this turn. Every range answer is anchored to it so
    /// the model never has to derive epoch milliseconds on its own.
    pub now_ms: i64,
    /// What one result may occupy. Carried on the host rather than read from a
    /// constant so a caller with a wider window is not held to the narrowest.
    pub budget: ContextBudget,
}

impl ToolHost<'_> {
    /// Dispatch. The arms below are the authority on what exists; the tests at
    /// the bottom of this file read them straight out of the source and hold
    /// [`tool_catalog_text`] and every system prompt to them. Two hand-written
    /// lists is how `get_day_summary` came to be callable but absent from
    /// chat's prompt for a whole release.
    pub async fn invoke(&self, name: &str, args: &Value) -> Result<Budgeted, String> {
        let result = match name {
            "get_now" => self.get_now(),
            "search_evidence" => self.search_evidence(args).await,
            "list_activity" => self.list_activity(args),
            "list_memories" => self.list_memories(args),
            "list_moments" => self.list_moments(args),
            "get_transcript" => self.get_transcript(args),
            "get_day_summary" => self.get_day_summary(args),
            "get_slot_card" => self.get_slot_card(args),
            "get_moment" => self.get_moment(args),
            "get_ocr" => self.get_ocr(args),
            "get_ax_digest" => self.get_ax_digest(args),
            "get_ax_tree" => self.get_ax_tree(args),
            other => Err(format!("unknown tool `{other}`")),
        }?;
        Ok(truncate_head(&result, self.budget.tool_result_tokens()))
    }

    /// The clock, ready-made windows, and what the vault actually holds.
    /// Small models get epoch arithmetic wrong by years, so hand them the
    /// numbers instead of asking them to compute any.
    fn get_now(&self) -> Result<String, String> {
        let now_ms = self.now_ms;
        let (today_start, today_end) = local_calendar_day_bounds_ms(now_ms);
        let (yesterday_start, yesterday_end) =
            local_calendar_day_bounds_ms(today_start.saturating_sub(DAY_MS));
        let coverage = self.store.moment_time_bounds().map_err(|e| e.to_string())?;
        Ok(serde_json::to_string_pretty(&json!({
            "now_ms": now_ms,
            "now_local": format_local_datetime(now_ms),
            "timezone": timezone_label(now_ms),
            "ranges": {
                "last_15_minutes": window(now_ms.saturating_sub(15 * 60_000), now_ms),
                "last_hour": window(now_ms.saturating_sub(HOUR_MS), now_ms),
                "last_3_hours": window(now_ms.saturating_sub(3 * HOUR_MS), now_ms),
                "today": window(today_start, today_end),
                "yesterday": window(yesterday_start, yesterday_end),
                "last_7_days": window(now_ms.saturating_sub(7 * DAY_MS), now_ms),
            },
            "vault_covers": match coverage {
                Some((first, last)) => window(first, last),
                None => json!(null),
            },
            "note": "Copy from_ms and to_ms out of this reply verbatim. Do not compute epoch milliseconds yourself.",
        }))
        .unwrap_or_else(|_| "{}".into()))
    }

    async fn search_evidence(&self, args: &Value) -> Result<String, String> {
        let query = args
            .get("query")
            .and_then(Value::as_str)
            .ok_or_else(|| "search_evidence requires query".to_owned())?
            .trim();
        if query.is_empty() {
            return Err("search_evidence query must not be empty".into());
        }
        let limit = args
            .get("limit")
            .and_then(Value::as_u64)
            .map_or(DEFAULT_SEARCH_LIMIT, |n| n as usize)
            .clamp(1, 20);
        let bounded = match (
            args.get("from_ms").and_then(Value::as_i64),
            args.get("to_ms").and_then(Value::as_i64),
        ) {
            (Some(from), Some(to)) => {
                let (from, to) = if from <= to { (from, to) } else { (to, from) };
                self.check_range(from, to)?;
                Some((from, to))
            }
            _ => None,
        };
        let mut hits = search_hits(self.store, self.models, query, limit.saturating_mul(2))
            .await
            .map_err(|e| e.to_string())?;
        if let Some((from, to)) = bounded {
            hits.retain(|hit| hit.captured_at_ms >= from && hit.captured_at_ms <= to);
        }
        hits.truncate(limit);
        if hits.is_empty() {
            if let Some((from, to)) = bounded {
                return Ok(self.nothing_found("matches", from, to));
            }
        }
        Ok(serde_json::to_string_pretty(&hits).unwrap_or_else(|_| "[]".into()))
    }

    fn list_activity(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = self.range_args(args, DEFAULT_LIST_LIMIT, 200)?;
        let spans = self
            .store
            .activity_spans(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        if spans.is_empty() {
            return Ok(self.nothing_found("activity spans", from_ms, to_ms));
        }
        Ok(serde_json::to_string_pretty(&spans).unwrap_or_else(|_| "[]".into()))
    }

    fn list_memories(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = self.range_args(args, DEFAULT_LIST_LIMIT, 100)?;
        let memories = self
            .store
            .memories(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        if memories.is_empty() {
            return Ok(self.nothing_found("memories", from_ms, to_ms));
        }
        Ok(serde_json::to_string_pretty(&memories).unwrap_or_else(|_| "[]".into()))
    }

    /// Moments in a window: the bridge from "three o'clock yesterday" to
    /// the ids every other evidence tool needs.
    fn list_moments(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = self.range_args(args, DEFAULT_LIST_LIMIT, 200)?;
        let moments = self
            .store
            .moment_ids_in_range(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        if moments.is_empty() {
            return Ok(self.nothing_found("moments", from_ms, to_ms));
        }
        let rows: Vec<Value> = moments
            .into_iter()
            .map(|(id, at_ms)| json!({"moment_id": id, "captured_at_ms": at_ms}))
            .collect();
        Ok(serde_json::to_string_pretty(&rows).unwrap_or_else(|_| "[]".into()))
    }

    /// Speech in a window. Transcripts hang off audio segments rather than
    /// moments, so without this a meeting is unreachable by time alone.
    fn get_transcript(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms, limit) = self.range_args(args, 60, 400)?;
        let rows = self
            .store
            .transcripts_in_range(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        if rows.is_empty() {
            return Ok(self.nothing_found("speech", from_ms, to_ms));
        }
        let items: Vec<Value> = rows
            .into_iter()
            .map(|(at_ms, track, text)| json!({"at_ms": at_ms, "track": track, "text": text}))
            .collect();
        Ok(serde_json::to_string_pretty(&items).unwrap_or_else(|_| "[]".into()))
    }

    /// The deterministic 30-minute card: application time, the run
    /// timeline with its deduplicated screen text, and revisits. One call
    /// covers a half hour that would otherwise take dozens of frame reads.
    /// The whole day at half-hour resolution, already summarised.
    ///
    /// This is what the day panel shows. Without it the only way to answer
    /// "what did I do today" was to pull T1 cards slot by slot — sixteen
    /// thousand characters of raw evidence each, for work a model had already
    /// summarised and written to the vault.
    fn get_day_summary(&self, args: &Value) -> Result<String, String> {
        let day_ms = args
            .get("day_ms")
            .and_then(Value::as_i64)
            .unwrap_or(self.now_ms);
        let (day_start, day_end) = local_calendar_day_bounds_ms(day_ms);
        self.check_range(day_start, day_end.min(self.now_ms))?;

        let summary = self
            .store
            .day_summary(day_ms, 10_000)
            .map_err(|e| e.to_string())?;
        if summary.slots.is_empty() {
            return Ok(format!("Nothing was recorded on {}.", summary.day));
        }

        let mut lines = vec![format!(
            "Day {} — {} half-hours with activity.",
            summary.day,
            summary.slots.len()
        )];
        let mut unsummarised = 0_usize;
        for slot in &summary.slots {
            let clock = chrono::DateTime::from_timestamp_millis(slot.slot_start_ms).map_or_else(
                || slot.slot_start_ms.to_string(),
                |dt| dt.with_timezone(&Local).format("%H:%M").to_string(),
            );
            match slot.title.as_deref() {
                Some(title) => {
                    lines.push(format!("{clock} at_ms={} — {title}", slot.slot_start_ms));
                    for bullet in slot.bullets.iter().flatten() {
                        lines.push(format!("    · {bullet}"));
                    }
                }
                None => {
                    // Say so rather than presenting the app list as a finding.
                    // A model handed "Zed 14m · Chrome 9m" with no marker will
                    // report it as what the user did.
                    unsummarised += 1;
                    let apps = slot
                        .facts
                        .apps
                        .iter()
                        .take(3)
                        .map(|app| app.name.clone())
                        .collect::<Vec<_>>()
                        .join(", ");
                    lines.push(format!(
                        "{clock} at_ms={} — [not summarised: {}] apps: {}",
                        slot.slot_start_ms,
                        slot.state.as_str(),
                        if apps.is_empty() {
                            "none recorded".to_owned()
                        } else {
                            apps
                        }
                    ));
                }
            }
        }
        if unsummarised > 0 {
            lines.push(format!(
                "\n{unsummarised} of {} half-hours have no summary yet. For those, \
                 call get_slot_card with the at_ms above to read the evidence directly.",
                summary.slots.len()
            ));
        }
        Ok(lines.join("\n"))
    }

    fn get_slot_card(&self, args: &Value) -> Result<String, String> {
        let at_ms = args
            .get("at_ms")
            .and_then(Value::as_i64)
            .ok_or_else(|| "get_slot_card requires at_ms".to_owned())?;
        self.check_range(at_ms, at_ms)?;
        let mut card = self
            .store
            .slot_card(at_ms, 10_000)
            .map_err(|e| e.to_string())?;
        let background = self
            .store
            .background_stats(&card)
            .unwrap_or_else(|_| afterray_store::infoscore::BackgroundStats::empty());
        afterray_store::attach_entity_candidates(&mut card, &background);
        Ok(afterray_store::render_t2_prompt(
            &card,
            &[],
            "the user's language",
            &background,
        ))
    }

    fn get_moment(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let moment = self
            .store
            .moment_by_id(&moment_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("moment `{moment_id}` not found"))?;
        Ok(serde_json::to_string_pretty(&moment).unwrap_or_else(|_| "{}".into()))
    }

    fn get_ocr(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let evidence = ocr_evidence(self.store, &moment_id)?;
        Ok(serde_json::to_string_pretty(&evidence).unwrap_or_else(|_| "{}".into()))
    }

    fn get_ax_digest(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let evidence = ax_evidence(self.store, &moment_id, true)?;
        Ok(serde_json::to_string_pretty(&evidence).unwrap_or_else(|_| "{}".into()))
    }

    fn get_ax_tree(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let evidence = ax_evidence(self.store, &moment_id, false)?;
        Ok(serde_json::to_string_pretty(&evidence).unwrap_or_else(|_| "{}".into()))
    }

    fn range_args(
        &self,
        args: &Value,
        default_limit: usize,
        max_limit: usize,
    ) -> Result<(i64, i64, usize), String> {
        let (from_ms, to_ms, limit) = parse_range(args, default_limit, max_limit)?;
        self.check_range(from_ms, to_ms)?;
        Ok((from_ms, to_ms, limit))
    }

    /// Rejects a window that cannot possibly hold evidence, and says why with
    /// numbers the model can copy. A silent `[]` reads as "nothing happened"
    /// and the model stops looking; this makes a mistyped year recoverable.
    fn check_range(&self, from_ms: i64, to_ms: i64) -> Result<(), String> {
        let Some((first, last)) = self.store.moment_time_bounds().map_err(|e| e.to_string())?
        else {
            return Err(format!(
                "the vault holds no captures at all yet. {}",
                self.clock_hint()
            ));
        };
        if to_ms < first || from_ms > last {
            return Err(format!(
                "the requested window {} is outside the recorded history. \
                 The vault covers {} (from_ms={first}, to_ms={last}). {} \
                 Call get_now and copy a range out of its reply instead of computing one.",
                describe_span(from_ms, to_ms),
                describe_span(first, last),
                self.clock_hint(),
            ));
        }
        Ok(())
    }

    /// An empty window that *is* inside the recording, reported with the same
    /// anchors so the model can widen or move rather than give up.
    fn nothing_found(&self, what: &str, from_ms: i64, to_ms: i64) -> String {
        let coverage = match self.store.moment_time_bounds() {
            Ok(Some((first, last))) => format!(" The vault covers {}.", describe_span(first, last)),
            _ => String::new(),
        };
        format!(
            "[] // no {what} between {}.{coverage} {}",
            describe_span(from_ms, to_ms),
            self.clock_hint(),
        )
    }

    fn clock_hint(&self) -> String {
        format!(
            "now_ms={} ({}).",
            self.now_ms,
            format_local_datetime(self.now_ms)
        )
    }
}

fn window(from_ms: i64, to_ms: i64) -> Value {
    json!({
        "from_ms": from_ms,
        "to_ms": to_ms,
        "from_local": format_local_datetime(from_ms),
        "to_local": format_local_datetime(to_ms),
    })
}

fn describe_span(from_ms: i64, to_ms: i64) -> String {
    format!(
        "{} … {} (from_ms={from_ms}, to_ms={to_ms})",
        format_local_datetime(from_ms),
        format_local_datetime(to_ms)
    )
}

fn format_local_datetime(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms).map_or_else(
        || ms.to_string(),
        |dt| {
            dt.with_timezone(&Local)
                .format("%Y-%m-%d %H:%M:%S")
                .to_string()
        },
    )
}

fn timezone_label(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms).map_or_else(
        || "unknown".to_owned(),
        |dt| dt.with_timezone(&Local).format("%:z").to_string(),
    )
}

pub fn ocr_evidence(store: ReadOnlyVault<'_>, moment_id: &str) -> Result<OcrEvidence, String> {
    let row = store
        .ocr_evidence_for_moment(moment_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no OCR for moment `{moment_id}`"))?;
    let (text, layout_json) = row;
    let regions = layout_json
        .as_deref()
        .and_then(|raw| serde_json::from_str::<Vec<OcrRegion>>(raw).ok())
        .unwrap_or_default();
    Ok(OcrEvidence {
        moment_id: moment_id.to_owned(),
        text,
        regions,
    })
}

pub fn ax_evidence(
    store: ReadOnlyVault<'_>,
    moment_id: &str,
    digest_only: bool,
) -> Result<AxEvidence, String> {
    let bytes = store
        .accessibility_bytes_for_moment(moment_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no accessibility snapshot for moment `{moment_id}`"))?;
    let digest = parse_accessibility_digest(&bytes);
    let digest_value = serde_json::to_value(&json_digest(&digest)).ok();
    let tree_json = if digest_only {
        None
    } else {
        Some(String::from_utf8_lossy(&bytes).into_owned())
    };
    Ok(AxEvidence {
        moment_id: moment_id.to_owned(),
        digest: digest_value,
        tree_json,
    })
}

pub fn moment_detail(store: ReadOnlyVault<'_>, moment_id: &str) -> Result<Moment, String> {
    store
        .moment_by_id(moment_id)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("moment `{moment_id}` not found"))
}

fn json_digest(digest: &afterray_store::AccessibilityDigest) -> Value {
    json!({
        "application_name": digest.application_name,
        "bundle_identifier": digest.bundle_identifier,
        "window_title": digest.window_title,
        "url": digest.url,
        "document": digest.document,
        "focused_role": digest.focused_role,
        "focused_title": digest.focused_title,
        "focused_value": digest.focused_value,
        "selected_text": digest.selected_text,
        "headings": digest.headings,
        "visible_text": digest.visible_text,
        "compact": digest.compact_text(),
        "sufficient": digest_looks_sufficient(digest),
    })
}

/// Heuristic: enough structure to describe activity without OCR.
#[must_use]
pub fn digest_looks_sufficient(digest: &afterray_store::AccessibilityDigest) -> bool {
    if afterray_store::is_idle_digest(digest) {
        return false;
    }
    let has_place = digest.url.is_some()
        || digest.document.is_some()
        || digest
            .window_title
            .as_ref()
            .is_some_and(|t| t.len() >= 3 && t != "Weixin" && t != "WeChat");
    let has_focus = digest
        .focused_value
        .as_ref()
        .is_some_and(|v| v.chars().count() >= 8);
    let has_visible = digest.visible_text.iter().any(|t| t.chars().count() >= 8);
    has_place || has_focus || has_visible
}

fn require_moment_id(args: &Value) -> Result<String, String> {
    args.get("moment_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| "moment_id is required".to_owned())
}

fn parse_range(
    args: &Value,
    default_limit: usize,
    max_limit: usize,
) -> Result<(i64, i64, usize), String> {
    let from_ms = args.get("from_ms").and_then(Value::as_i64).ok_or_else(|| {
        "from_ms is required (Unix milliseconds; call get_now for one)".to_owned()
    })?;
    let to_ms = args
        .get("to_ms")
        .and_then(Value::as_i64)
        .ok_or_else(|| "to_ms is required (Unix milliseconds; call get_now for one)".to_owned())?;
    let (from_ms, to_ms) = if from_ms <= to_ms {
        (from_ms, to_ms)
    } else {
        (to_ms, from_ms)
    };
    let limit = args
        .get("limit")
        .and_then(Value::as_u64)
        .map_or(default_limit, |n| n as usize)
        .clamp(1, max_limit);
    Ok((from_ms, to_ms, limit))
}

/// Catalog shown to the LLM in agent prompts.
#[must_use]
pub fn tool_catalog_text() -> &'static str {
    r#"Tools (call at most one per reply). Timestamps are Unix milliseconds.

Never work out a Unix millisecond value yourself — you will get the year
wrong. Take every from_ms, to_ms and at_ms from get_now or from a previous
tool result, verbatim.

- get_now: {}
    The current time, ready-made windows (last_hour, today, yesterday, …)
    and the span the vault actually covers. Call this first whenever the
    question mentions a time, unless the numbers are already in front of you.

Start wide, then narrow:
- get_day_summary: {"day_ms":0}
    Every half-hour of one local day, already summarised — a title and a few
    bullets each, plus the at_ms to drill into. Omit day_ms for today. This
    is the right first call for "what did I do today / yesterday", and it is
    far cheaper than reading each half-hour's evidence. Half-hours no model
    has reached yet are marked "not summarised"; treat those as unknown, not
    as a finding, and use get_slot_card on them if they matter.
- get_slot_card: {"at_ms":0}
    A whole 30-minute window at once: which apps for how long, a timeline of
    what was open, the screen text each stretch introduced, and what the
    person kept returning to. Usually the cheapest way to answer "what was I
    doing around <time>".
- list_activity: {"from_ms":0,"to_ms":0,"limit":40}
    Application and document spans over a range — good for spotting when
    something started or stopped.
- search_evidence: {"query":"…","from_ms":0,"to_ms":0,"limit":8}
    Full-text and semantic search across captured screen text.
- list_memories: {"from_ms":0,"to_ms":0,"limit":40}
    Short notes already written for each stretch of activity.
- list_moments: {"from_ms":0,"to_ms":0,"limit":40}
    Capture ids and their timestamps — use when you know a time but need an
    id for the tools below.

Then, for one captured instant:
- get_moment: {"moment_id":"…"}       metadata, and transcript_text if any
- get_ocr: {"moment_id":"…"}          text read off the screen, with boxes
- get_ax_digest: {"moment_id":"…"}    compact accessibility summary
- get_ax_tree: {"moment_id":"…"}      full accessibility JSON (large; rare)

And for speech:
- get_transcript: {"from_ms":0,"to_ms":0,"limit":60}
    Everything said in a window, across microphone and system audio.

Reply format (exactly one):
TOOL <name>
ARGS <json object>

or

FINAL
<answer text>"#
}

#[cfg(test)]
mod jail {
    //! What the agent's tools may not do, checked in the source.
    //!
    //! Half the jail is the type system: tools hold an
    //! `afterray_store::ReadOnlyVault`, so they cannot write to the vault —
    //! the methods are not on the handle. That half needs no test.
    //!
    //! The other half cannot be a type. Rust has no capability-based module
    //! system: `std::fs`, `std::process` and `std::net` are in scope in every
    //! crate, and no dependency list, newtype or sealed trait takes them away.
    //! `ToolSurface` is an open trait precisely so the daemon can implement it
    //! outside the harness, which also means anyone can implement one that
    //! writes files or opens sockets.
    //!
    //! So this reads the tool modules and fails on the constructs that would
    //! make an agent tool do anything but read the vault. It is deliberately
    //! bypassable — a reviewer editing this list is the point. What must not
    //! happen is a tool acquiring those powers *without anyone noticing*.

    /// Every region that defines a surface the model can call.
    ///
    /// `main.rs` is the daemon and legitimately spawns workers and writes
    /// files, so only the slot summariser's tool surface is taken from it —
    /// scanning the whole file would be a permanent false positive.
    fn tool_sources() -> Vec<(&'static str, String)> {
        let main = include_str!("main.rs");
        let slot_tools = main
            .split_once(concat!("impl SlotT2", "Tools<'_> {"))
            .map(|(_, rest)| {
                let end = rest
                    .find(concat!("fn model_", "library"))
                    .unwrap_or(rest.len());
                rest[..end].to_owned()
            })
            .expect("the SlotT2Tools impl moved; update this scan");
        vec![
            (
                "tools.rs",
                production_source(include_str!("tools.rs")).to_owned(),
            ),
            ("main.rs (SlotT2Tools)", slot_tools),
        ]
    }

    /// Constructs that would take a tool outside "read the vault".
    ///
    /// Split and rejoined so this list cannot match itself.
    fn forbidden() -> Vec<(&'static str, &'static str)> {
        vec![
            (concat!("std::", "process"), "spawning a process"),
            (concat!("Command", "::new"), "spawning a process"),
            (concat!("std::", "fs::"), "touching the filesystem"),
            (concat!("File", "::create"), "touching the filesystem"),
            (concat!("File", "::open"), "touching the filesystem"),
            (concat!("std::", "net"), "opening a socket"),
            (concat!("UdpSocket", "::bind"), "opening a socket"),
            (concat!("TcpStream", "::connect"), "opening a socket"),
            ("reqwest", "making an HTTP request"),
            (concat!("tokio::", "net"), "opening a socket"),
            (concat!("tokio::", "fs"), "touching the filesystem"),
        ]
    }

    /// The source of a tool file, minus its own test modules.
    fn production_source(source: &str) -> &str {
        source
            .split_once("\n#[cfg(test)]")
            .map_or(source, |(before, _)| before)
    }

    /// The test the plan asks for: adding a tool that writes, spawns or dials
    /// out has to argue with this list first.
    #[test]
    fn tools_cannot_reach_the_filesystem_the_network_or_a_process() {
        for (name, production) in tool_sources() {
            for (needle, what) in forbidden() {
                assert!(
                    !production.contains(needle),
                    "{name} mentions `{needle}` — {what}. The agent's tools read the \
                     vault and nothing else. If this is genuinely needed, say so in \
                     docs/harness-threat-model.md and add it to the allowlist here."
                );
            }
        }
    }

    /// The type-level half, asserted from the outside: the tool surfaces hold
    /// a read-only handle, not a `&Vault` they could write through.
    #[test]
    fn tool_surfaces_hold_a_read_only_vault() {
        let tools = production_source(include_str!("tools.rs"));
        assert!(
            tools.contains(concat!("pub store: ReadOnly", "Vault<'a>")),
            "ToolHost stopped holding a read-only handle"
        );
        let main = production_source(include_str!("main.rs"));
        assert!(
            main.contains(concat!("store: afterray_store::ReadOnly", "Vault<'a>")),
            "SlotT2Tools stopped holding a read-only handle"
        );
    }

    /// The mutation this is meant to catch, run for real: a tool that reads a
    /// file is exactly what the list above forbids.
    #[test]
    fn the_check_actually_fires() {
        let pretend_tool = concat!(
            "fn get_config(&self) -> Result<String, String> {\n",
            "    std::",
            "fs::read_to_string(\"/etc/passwd\").map_err(|e| e.to_string())\n}"
        );
        let hit = forbidden()
            .into_iter()
            .find(|(needle, _)| pretend_tool.contains(needle));
        assert!(hit.is_some(), "a filesystem-reading tool slipped past the list");
    }
}

#[cfg(test)]
mod catalog_drift {
    //! The tool catalog, the dispatch table and three system prompts are four
    //! hand-written texts describing one thing. They have already drifted once:
    //! `get_day_summary` was dispatchable and documented while `chat.rs` still
    //! told the model to "start wide with `get_slot_card`".
    //!
    //! These tests read the dispatch arms out of this file's own source, so the
    //! `match` stays the single authority and the prose has to follow it.

    use super::tool_catalog_text;

    /// Every name in `ToolHost::invoke`'s `match`, read from the source.
    ///
    /// The markers are split across two literals and rejoined by `concat!`, so
    /// the joined text appears in this file exactly once — in the real code —
    /// and this scan cannot accidentally find itself.
    fn dispatched_names() -> Vec<String> {
        const START: &str = concat!("let result = ", "match name {");
        const END: &str = concat!("other =>", " format!");
        let source = include_str!("tools.rs");
        let (_, rest) = source
            .split_once(START)
            .expect("the dispatch match moved; update START");
        let (arms, _) = rest
            .split_once(END)
            .unwrap_or_else(|| rest.split_once("other =>").expect("no fallback arm"));
        arms.lines()
            .filter_map(|line| {
                let line = line.trim();
                let rest = line.strip_prefix('"')?;
                let (name, _) = rest.split_once("\" =>")?;
                Some(name.to_owned())
            })
            .collect()
    }

    /// Tool-shaped identifiers a prompt mentions.
    fn tools_named_in(source: &str) -> Vec<String> {
        let prefixes = ["get_", "list_", "search_"];
        let mut found: Vec<String> = Vec::new();
        for token in source.split(|ch: char| !(ch.is_ascii_alphanumeric() || ch == '_')) {
            if prefixes.iter().any(|prefix| token.starts_with(prefix))
                && !found.iter().any(|seen| seen == token)
            {
                found.push(token.to_owned());
            }
        }
        found
    }

    #[test]
    fn the_scan_finds_the_real_dispatch_table() {
        let names = dispatched_names();
        assert!(names.len() >= 10, "scan found only {names:?}");
        assert!(names.iter().any(|name| name == "get_day_summary"), "{names:?}");
        assert!(names.iter().any(|name| name == "get_now"), "{names:?}");
    }

    /// The test the plan asks for: nothing callable may be undocumented.
    #[test]
    fn every_dispatched_tool_appears_in_the_catalog() {
        let catalog = tool_catalog_text();
        for name in dispatched_names() {
            assert!(
                catalog.contains(&format!("- {name}:")),
                "`{name}` is callable but the catalog never lists it"
            );
        }
    }

    /// And the other direction: nothing documented may be uncallable, or the
    /// model spends a round discovering `unknown tool`.
    #[test]
    fn every_catalogued_tool_is_dispatched() {
        let dispatched = dispatched_names();
        for line in tool_catalog_text().lines() {
            let Some(rest) = line.trim().strip_prefix("- ") else {
                continue;
            };
            let Some((name, _)) = rest.split_once(':') else {
                continue;
            };
            assert!(
                dispatched.iter().any(|known| known == name),
                "the catalog documents `{name}`, which nothing dispatches"
            );
        }
    }

    /// The drift that actually shipped was subtler than a wrong name: chat's
    /// prompt said "start wide with `get_slot_card`" and simply never learned
    /// about `get_day_summary`. No test can require a prompt to *mention* a
    /// tool, so the rule is the other way round — a system prompt may not name
    /// tools at all. Ordering advice lives in the catalog, next to the tools it
    /// orders, where adding one puts the advice in front of whoever adds it.
    #[test]
    fn system_prompts_leave_tool_advice_to_the_catalog() {
        let dispatched = dispatched_names();
        let prompts = [
            ("chat.rs", include_str!("chat.rs")),
            ("stream.rs", include_str!("stream.rs")),
            ("ask.rs", include_str!("ask.rs")),
        ];
        for (file, source) in prompts {
            // Only the prompt constants, not the whole file: the handlers
            // legitimately call `store.get_*` helpers of their own.
            for constant in source.split("_PROMPT: &str = ").skip(1) {
                let body = constant.split(";\n").next().unwrap_or_default();
                let named = tools_named_in(body);
                let (tools, strangers): (Vec<_>, Vec<_>) = named
                    .into_iter()
                    .partition(|name| dispatched.iter().any(|tool| tool == name));
                assert!(
                    tools.is_empty(),
                    "{file}'s system prompt names {tools:?}. Move the advice into \
                     tool_catalog_text() so it cannot fall behind the tool list."
                );
                assert!(
                    strangers.is_empty(),
                    "{file}'s system prompt names {strangers:?}, which are not tools at all"
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // The fixtures build a real vault before narrowing it; production code in
    // this file only ever sees the read-only handle.
    use afterray_models::QueueConfig;
    use afterray_store::Vault;
    use afterray_store::VaultConfig;

    const DAY: i64 = 86_400_000;
    /// 2026-08-15, roughly. The screenshot that prompted these guards showed a
    /// model reaching for 2024 instead.
    const NOW: i64 = 1_786_729_937_000;

    fn host_fixture() -> (tempfile::TempDir, Vault, ModelQueue) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [7_u8; 32],
        )
        .unwrap();
        let models = ModelQueue::new(Vec::new(), QueueConfig::default()).unwrap();
        (directory, vault, models)
    }

    fn seed_moments(vault: &Vault, stamps: &[i64]) {
        let session = vault.create_session_sync(stamps[0]).unwrap();
        for stamp in stamps {
            vault
                .insert_moment(&session.id, *stamp, "image/jpeg", b"frame")
                .unwrap();
        }
    }

    /// Seeds one half-hour with moments and gives it a T2 card, leaving a
    /// second half-hour with evidence but no summary.
    fn seed_day(vault: &Vault, summarised_at: i64, bare_at: i64) {
        seed_moments(vault, &[summarised_at, summarised_at + 60_000, bare_at]);
        let card = vault.slot_card(summarised_at, 10_000).unwrap();
        vault
            .put_t2_summary(
                &card,
                &afterray_store::T2Card {
                    artifacts: Vec::new(),
                    title: "Chased a GOP header bug".to_owned(),
                    bullets: vec!["Read the IVF length check".to_owned()],
                    category: Some("coding".to_owned()),
                    confidence: Some(0.8),
                },
                "test",
                summarised_at,
                Some(1),
            )
            .unwrap();
    }

    /// The day panel's contents, reachable by the agent. Before this the only
    /// route to "what did I do today" was a T1 card per half hour.
    #[tokio::test]
    async fn get_day_summary_returns_the_written_summaries() {
        let (_dir, vault, models) = host_fixture();
        // Inside today's local bounds: NOW is early morning, so subtracting
        // hours would land on yesterday and the day tool would rightly refuse.
        let noon = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        seed_day(&vault, noon, noon + 1_800_000);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let text = host.invoke("get_day_summary", &json!({})).await.unwrap().text;
        assert!(text.contains("Chased a GOP header bug"), "{text}");
        assert!(text.contains("Read the IVF length check"), "{text}");
        // The at_ms has to come back or the model cannot drill in.
        assert!(text.contains(&format!("at_ms={noon}")), "{text}");
    }

    /// A half-hour nothing has summarised must not present its app list as a
    /// finding — a model handed a bare list will report it as what happened.
    #[tokio::test]
    async fn get_day_summary_marks_the_gaps() {
        let (_dir, vault, models) = host_fixture();
        // Inside today's local bounds: NOW is early morning, so subtracting
        // hours would land on yesterday and the day tool would rightly refuse.
        let noon = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        seed_day(&vault, noon, noon + 1_800_000);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let text = host.invoke("get_day_summary", &json!({})).await.unwrap().text;
        assert!(text.contains("not summarised"), "{text}");
        assert!(
            text.contains("get_slot_card"),
            "the gap note must say how to dig in: {text}"
        );
    }

    /// A day with nothing in it, but inside the recorded span — a weekend
    /// between two working days. The range guard cannot answer this one, so
    /// the tool has to say it plainly instead of returning an empty list.
    #[tokio::test]
    async fn get_day_summary_says_so_when_a_day_is_empty() {
        let (_dir, vault, models) = host_fixture();
        let today = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        seed_day(&vault, today, today + 1_800_000);
        // Push coverage back two days so yesterday sits inside the span.
        seed_moments(&vault, &[today - 2 * DAY]);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let text = host
            .invoke("get_day_summary", &json!({"day_ms": NOW - DAY}))
            .await
            .unwrap()
            .text;
        assert!(text.contains("Nothing was recorded"), "{text}");
    }

    #[tokio::test]
    async fn get_now_hands_over_ready_made_windows() {
        let (_dir, vault, models) = host_fixture();
        seed_moments(&vault, &[NOW - DAY, NOW - 60_000]);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let raw = host.invoke("get_now", &json!({})).await.unwrap().text;
        let value: Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(value["now_ms"], json!(NOW));
        assert_eq!(value["ranges"]["last_hour"]["to_ms"], json!(NOW));
        assert_eq!(
            value["ranges"]["last_hour"]["from_ms"],
            json!(NOW - 3_600_000)
        );
        assert_eq!(value["vault_covers"]["from_ms"], json!(NOW - DAY));
        assert_eq!(value["vault_covers"]["to_ms"], json!(NOW - 60_000));
    }

    #[tokio::test]
    async fn window_outside_history_explains_itself() {
        let (_dir, vault, models) = host_fixture();
        seed_moments(&vault, &[NOW - DAY, NOW - 60_000]);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        // The exact arguments from the failing chat: right time of day, wrong year.
        let error = host
            .invoke(
                "list_activity",
                &json!({"from_ms": 1_723_703_599_000_i64, "to_ms": 1_723_721_199_000_i64}),
            )
            .await
            .unwrap_err();
        assert!(error.contains("outside the recorded history"), "{error}");
        assert!(error.contains(&NOW.to_string()), "{error}");
        assert!(error.contains("get_now"), "{error}");
    }

    #[tokio::test]
    async fn quiet_window_inside_history_keeps_the_anchors() {
        let (_dir, vault, models) = host_fixture();
        seed_moments(&vault, &[NOW - 10 * DAY, NOW - 60_000]);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let result = host
            .invoke(
                "list_activity",
                &json!({"from_ms": NOW - 5 * DAY, "to_ms": NOW - 4 * DAY}),
            )
            .await
            .unwrap()
            .text;
        assert!(result.starts_with("[] // no activity spans"), "{result}");
        assert!(result.contains("The vault covers"), "{result}");
        assert!(result.contains(&NOW.to_string()), "{result}");
    }

    #[tokio::test]
    async fn empty_vault_is_reported_rather_than_silently_empty() {
        let (_dir, vault, models) = host_fixture();
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let error = host
            .invoke("list_moments", &json!({"from_ms": 0, "to_ms": NOW}))
            .await
            .unwrap_err();
        assert!(error.contains("no captures at all yet"), "{error}");
    }

    #[tokio::test]
    async fn missing_bounds_point_at_the_clock_tool() {
        let (_dir, vault, models) = host_fixture();
        seed_moments(&vault, &[NOW - 60_000]);
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            models: &models,
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        };

        let error = host
            .invoke("list_activity", &json!({"limit": 5}))
            .await
            .unwrap_err();
        assert!(error.contains("get_now"), "{error}");
    }
}
