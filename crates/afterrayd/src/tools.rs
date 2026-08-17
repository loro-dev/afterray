//! Read-only history tools shared by CLI handlers and the internal agent loop.
//!
//! Eight tools, in two groups: three that find a stretch of time, four that
//! read one, and a clock. That shape is the interface — a model choosing
//! between fourteen flat entries chooses badly, and the ones removed here were
//! either subsumed (`get_moment`, `get_ocr`, `get_ax_digest` all live inside
//! `get_moment_context`) or unaffordable (`get_ax_tree` cannot fit a 16k
//! window) or redundant now that ids come back attached to every hit
//! (`list_moments`, `list_memories`).
//!
//! **Timestamps are copied, never computed.** Every tool takes epoch
//! milliseconds and nothing else; `get_now` hands over a table of every period
//! a question is likely to name, with the dates beside the numbers. An earlier
//! design parsed `{"window":"yesterday"}` and four other spellings, on the
//! theory that copying thirteen digits was itself error-prone. It is not —
//! verbatim copying is the most reliable thing a small model does. What it
//! cannot do is arithmetic, and a table removes every occasion for it.

use afterray_protocol::{
    ActivitySpan, AxEvidence, Moment, OcrEvidence, OcrRegion, local_calendar_day_bounds_ms,
};
use afterray_store::{ReadOnlyVault, SearchFilter, parse_accessibility_digest};
use chrono::Local;
use serde_json::{Value, json};
use std::fmt::Write as _;

use crate::search_hits;
use afterray_harness::ContextBudget;
use afterray_harness::{Budgeted, truncate_head};

const DEFAULT_SEARCH_LIMIT: usize = 8;
const MAX_SEARCH_LIMIT: usize = 20;
const DEFAULT_MENTION_LIMIT: usize = 12;
const MAX_MENTION_LIMIT: usize = 40;
const DEFAULT_ACTIVITY_LIMIT: usize = 40;
const MAX_ACTIVITY_LIMIT: usize = 200;
const DEFAULT_TRANSCRIPT_LIMIT: usize = 60;
const MAX_TRANSCRIPT_LIMIT: usize = 400;
const DAY_MS: i64 = 86_400_000;

/// How many individual days `get_now` spells out before switching to weeks and
/// months. Seven covers "the day before yesterday", "last Wednesday" and a
/// date read off the screen, which is nearly every question that names a day.
const CLOCK_DAYS: i64 = 7;

/// Per-stretch caps on the day summary's structured lines.
///
/// Tighter than they look like they should be, for arithmetic rather than
/// taste. A worked day is ~48 ten-minute stretches against a
/// `tool_result_tokens` budget of roughly 1 900 — about 40 tokens a stretch —
/// and a summary written in Chinese costs one token per character. A moment id
/// is a 36-character UUID; citing three per thread spends more of the day on
/// identifiers than on what happened, and the overflow is cut from the tail,
/// which silently deletes the afternoon.
const MAX_ENTITIES: usize = 4;
const MAX_DECISIONS: usize = 2;
const MAX_DAY_THREAD_MOMENTS: usize = 1;
/// What a narrowed-down view may cite, where there is one stretch to pay for
/// rather than a day of them.
const MAX_THREAD_MOMENTS: usize = 3;

#[derive(Clone)]
pub struct ToolHost<'a> {
    /// Reads only. The agent's tools cannot write to the vault because the
    /// handle they hold has no writing methods — see `afterray_store::readonly`.
    pub store: ReadOnlyVault<'a>,
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
    #[allow(
        clippy::unused_async,
        reason = "ToolSurface is async; every tool reads the vault synchronously today"
    )]
    pub async fn invoke(&self, name: &str, args: &Value) -> Result<Budgeted, String> {
        let result = match name {
            "get_now" => self.get_now(),
            "get_day_summary" => self.get_day_summary(args),
            "search_summaries" => self.search_summaries(args),
            "search_evidence" => self.search_evidence(args),
            "get_slot_card" => self.get_slot_card(args),
            "get_moment_context" => self.get_moment_context(args),
            "get_transcript" => self.get_transcript(args),
            "list_activity" => self.list_activity(args),
            other => Err(format!("unknown tool `{other}`")),
        }?;
        Ok(truncate_head(&result, self.budget.tool_result_tokens()))
    }

    /// The clock, every period a question is likely to name, what the
    /// recording covers, and what is on screen now.
    ///
    /// This used to be a block prepended to every turn. It is a tool instead
    /// because it changes every turn: sitting in the prompt it broke the
    /// cached prefix each time and was paid for whether or not the question
    /// involved a time. As a tool it costs one round, once, and only when
    /// asked — so it answers everything at once rather than a window at a time.
    #[allow(
        clippy::unnecessary_wraps,
        reason = "one arm of a dispatch table whose other arms are fallible"
    )]
    fn get_now(&self) -> Result<String, String> {
        let mut lines = vec![format!(
            "Now: {} ({})   now_ms={}",
            format_local_datetime(self.now_ms),
            timezone_label(self.now_ms),
            self.now_ms
        )];
        for period in clock_periods(self.now_ms) {
            lines.push(format!(
                "{:<11} {:<15} from_ms={}  to_ms={}",
                period.label, period.dates, period.from_ms, period.to_ms
            ));
        }
        lines.push(match self.store.moment_time_bounds() {
            Ok(Some((first, last))) => format!(
                "Recording covers {} – {}.",
                local_date(first),
                local_date(last)
            ),
            Ok(None) => "Nothing has been recorded yet.".to_owned(),
            Err(error) => format!("Recording coverage unavailable ({error})."),
        });

        // What the person is doing right now, and what they have been doing
        // today. Both are derived from captured window titles, so they are
        // untrusted data — which is why they live in a tool result, inside the
        // data fence, and not in the catalog.
        let (day_start, _) = local_calendar_day_bounds_ms(self.now_ms);
        if let Ok(spans) = self.store.activity_spans(day_start, self.now_ms, 200) {
            if let Some(current) = spans.last() {
                lines.push(format!("Right now: {}", describe_span_place(current)));
            }
            let apps = distinct_apps(&spans, 8);
            if !apps.is_empty() {
                lines.push(format!("Today's apps: {}", apps.join(", ")));
            }
        }
        Ok(lines.join("\n"))
    }

    /// The whole day, one stretch at a time, already summarised.
    ///
    /// This is what the day panel shows. Without it the only way to answer
    /// "what did I do today" was to pull T1 cards slot by slot — sixteen
    /// thousand characters of raw evidence each, for work a model had already
    /// summarised and written to the vault.
    ///
    /// It renders the v2 card, not the derived bullet list. The stored card
    /// already holds the frames each thread cites, the identifiers worth
    /// searching for, and what was actually settled; projecting all of that
    /// down to `title` + `bullets` meant an agent that wanted a citation had
    /// to spend a round guessing which frame to open, and an agent asked "what
    /// did I finish" had to infer it from prose.
    fn get_day_summary(&self, args: &Value) -> Result<String, String> {
        let day_ms = match args.get("day").and_then(Value::as_str) {
            Some(text) => parse_local_day(text)
                .ok_or_else(|| {
                    format!(
                        "`{text}` is not a date. Write it as \"2026-08-13\" — get_now \
                         lists the recent ones."
                    )
                })?
                .0,
            // Accepted but undocumented: a model that copies a from_ms out of
            // the clock table instead of the date beside it still lands on the
            // right day, and correcting it would cost a round to no purpose.
            None => args
                .get("day_ms")
                .and_then(Value::as_i64)
                .unwrap_or(self.now_ms),
        };
        let (day_start, day_end) = local_calendar_day_bounds_ms(day_ms);
        self.check_range(day_start, day_end.min(self.now_ms))?;

        let summary = self
            .store
            .day_summary(day_ms, 10_000)
            .map_err(|e| e.to_string())?;
        if summary.slots.is_empty() {
            return Ok(format!("Nothing was recorded on {}.", summary.day));
        }

        // Detail first, and the whole day compactly if the detail will not
        // fit. A worked day is ~48 ten-minute stretches against a result
        // budget of roughly 1 900 tokens, so the rich form overflows and the
        // cut falls on the tail — deleting the afternoon from an answer to
        // "what did I do today", with only a truncation marker to say so.
        // Losing the *detail* of the afternoon is recoverable in one more
        // call; losing the fact that the afternoon happened is not.
        let detailed = render_day(&summary, true);
        if afterray_harness::estimate_tokens(&detailed) <= self.budget.tool_result_tokens() {
            return Ok(detailed);
        }
        Ok(render_day(&summary, false))
    }

    /// Stretches of work whose stored summary names something.
    ///
    /// The index the day panel could never be. "Which Lody issues did I
    /// handle" used to mean reading every stretch of the day and scanning the
    /// prose for the word; this asks the summaries directly and comes back
    /// with the times, what was settled, and the frames to cite.
    fn search_summaries(&self, args: &Value) -> Result<String, String> {
        let query = require_query(args, "search_summaries")?;
        let filter = self.search_filter(args)?;
        let limit = parse_limit(args, DEFAULT_MENTION_LIMIT, MAX_MENTION_LIMIT);
        let mentions = self
            .store
            .find_slot_mentions(query, &filter, limit)
            .map_err(|e| e.to_string())?;
        if mentions.is_empty() {
            // Only summarised stretches are searchable here, so "no mentions"
            // is not "did not happen" — saying which is the difference between
            // the model widening its search and it reporting a false negative.
            return Ok(format!(
                "// no summary mentions \"{query}\"{}. This reads written \
                 summaries only, so a stretch nothing has summarised yet \
                 cannot appear. search_evidence reads the captured screen \
                 text itself.",
                describe_filter(&filter)
            ));
        }

        let mut lines = vec![format!(
            "\"{query}\" appears in {}{}.",
            plural(mentions.len(), "summarised stretch", "summarised stretches"),
            describe_filter(&filter)
        )];
        for mention in &mentions {
            let mut header = format!(
                "{} {} at_ms={}",
                mention.local_day,
                clock_label(mention.slot_start_ms),
                mention.slot_start_ms
            );
            if let Some(title) = &mention.title {
                let _ = write!(header, " — {title}");
            }
            lines.push(header);
            for thread in &mention.matched_threads {
                lines.push(format!("    · {thread}"));
            }
            if !mention.matched_entities.is_empty() {
                lines.push(format!("    names: {}", mention.matched_entities.join(", ")));
            }
            if let Some(decisions) = joined(Some(&mention.decisions), MAX_DECISIONS, Clone::clone) {
                lines.push(format!("    decided: {decisions}"));
            }
            if !mention.moment_ids.is_empty() {
                lines.push(format!(
                    "    moments: {}",
                    mention
                        .moment_ids
                        .iter()
                        .take(MAX_THREAD_MOMENTS)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
        }
        Ok(lines.join("\n"))
    }

    /// Exact-text search over what was actually on screen and said.
    ///
    /// Every hit says where it was — time, frame, application, and the title
    /// of the stretch it falls in — because a bare id and a snippet cost the
    /// model a round to learn which app it was even looking at.
    fn search_evidence(&self, args: &Value) -> Result<String, String> {
        let query = require_query(args, "search_evidence")?;
        let filter = self.search_filter(args)?;
        let limit = parse_limit(args, DEFAULT_SEARCH_LIMIT, MAX_SEARCH_LIMIT);
        let hits = search_hits(self.store, query, &filter, limit).map_err(|e| e.to_string())?;
        if hits.is_empty() {
            return Ok(format!(
                "// nothing captured matches \"{query}\"{}. Try fewer or \
                 different words — this matches text exactly, not by meaning.",
                describe_filter(&filter)
            ));
        }

        let mut lines = vec![format!(
            "{} for \"{query}\"{}.",
            plural(hits.len(), "match", "matches"),
            describe_filter(&filter)
        )];
        for hit in hits {
            let moment = self.store.moment_by_id(&hit.moment_id).ok().flatten();
            let mut header = format!(
                "{} at_ms={} moment={}",
                format_local_time(hit.captured_at_ms),
                hit.captured_at_ms,
                hit.moment_id
            );
            match moment.as_ref().and_then(|m| m.application_name.as_deref()) {
                Some(app) => {
                    let _ = write!(header, " app={app}");
                }
                None => {
                    let _ = write!(header, " source={}", hit.source);
                }
            }
            lines.push(header);
            if let Ok(Some((slot_at_ms, title))) =
                self.store.slot_title_covering(hit.captured_at_ms)
            {
                lines.push(format!("    stretch: at_ms={slot_at_ms} — {title}"));
            }
            for line in hit.text.lines().filter(|line| !line.trim().is_empty()) {
                lines.push(format!("    {line}"));
            }
        }
        Ok(lines.join("\n"))
    }

    /// One stretch in full: the deterministic T1 card, which is what to read
    /// when no model has summarised the stretch yet.
    fn get_slot_card(&self, args: &Value) -> Result<String, String> {
        let at_ms = args.get("at_ms").and_then(Value::as_i64).ok_or_else(|| {
            "get_slot_card needs at_ms — copy one from a summary line or a \
             search hit, or call get_now for a range."
                .to_owned()
        })?;
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

    /// One frame, whole: what it was, what was on screen, what the app said.
    ///
    /// `get_moment` then `get_ocr` then `get_ax_digest` was three rounds of a
    /// turn that only has a handful, spent on one instant the model had
    /// already decided to look at. Nothing here is new evidence — it is the
    /// same three reads, billed once.
    fn get_moment_context(&self, args: &Value) -> Result<String, String> {
        let moment_id = require_moment_id(args)?;
        let moment = self
            .store
            .moment_by_id(&moment_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("moment `{moment_id}` not found"))?;

        let mut lines = vec![
            format!(
                "moment={} at_ms={} {}",
                moment.id,
                moment.captured_at_ms,
                format_local_datetime(moment.captured_at_ms)
            ),
            format!(
                "app={}  window={}",
                or_none(moment.application_name.as_deref()),
                or_none(moment.window_title.as_deref())
            ),
        ];
        if let Some(url) = &moment.url {
            lines.push(format!("url={url}"));
        }
        if let Some(document) = &moment.document {
            lines.push(format!("document={document}"));
        }
        if let Ok(Some((slot_at_ms, title))) = self.store.slot_title_covering(moment.captured_at_ms)
        {
            lines.push(format!("stretch: at_ms={slot_at_ms} — {title}"));
        }
        // A frame with no text on it and an app that exposes no accessibility
        // tree are both ordinary. Reported as absences rather than as failed
        // reads, which the model would otherwise retry.
        lines.push(format!(
            "screen text: {}",
            match ocr_evidence(self.store, &moment_id) {
                Ok(evidence) if !evidence.text.trim().is_empty() => evidence.text,
                _ => "none recorded".to_owned(),
            }
        ));
        lines.push(format!(
            "accessibility: {}",
            match ax_evidence(self.store, &moment_id, true) {
                Ok(evidence) => evidence
                    .digest
                    .as_ref()
                    .and_then(|digest| digest.get("compact"))
                    .and_then(Value::as_str)
                    .filter(|text| !text.trim().is_empty())
                    .unwrap_or("none recorded")
                    .to_owned(),
                Err(_) => "none recorded".to_owned(),
            }
        ));
        lines.push(format!(
            "said: {}",
            or_none(
                moment
                    .transcript_text
                    .as_deref()
                    .filter(|text| !text.trim().is_empty())
            )
        ));
        Ok(lines.join("\n"))
    }

    /// Speech in a window. Transcripts hang off audio segments rather than
    /// moments, so without this a meeting is unreachable by time alone.
    fn get_transcript(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms) = self.require_range(args)?;
        let limit = parse_limit(args, DEFAULT_TRANSCRIPT_LIMIT, MAX_TRANSCRIPT_LIMIT);
        let rows = self
            .store
            .transcripts_in_range(from_ms, to_ms, limit)
            .map_err(|e| e.to_string())?;
        if rows.is_empty() {
            return Ok(self.nothing_found("speech", from_ms, to_ms));
        }
        let filled = rows.len() == limit;
        let last_ms = rows.last().map_or(to_ms, |(at_ms, _, _)| *at_ms);
        let mut lines: Vec<String> = rows
            .into_iter()
            .map(|(at_ms, track, text)| {
                format!("{} {track:<7} {text}", format_local_time(at_ms))
            })
            .collect();
        // Say where the answer stops. A silent cut reads as "that is all that
        // was said", and the model has no way to discover otherwise.
        if filled {
            lines.push(more_from(limit, "lines", last_ms));
        }
        Ok(lines.join("\n"))
    }

    /// Application and document spans over a range — when something started
    /// and when it stopped.
    fn list_activity(&self, args: &Value) -> Result<String, String> {
        let (from_ms, to_ms) = self.require_range(args)?;
        let limit = parse_limit(args, DEFAULT_ACTIVITY_LIMIT, MAX_ACTIVITY_LIMIT);
        let app = optional_text(args, "app");
        // Widened when narrowing by application, because the store filters by
        // range only and the cut would otherwise land before the filter.
        let fetch = if app.is_some() {
            limit.saturating_mul(4).min(MAX_ACTIVITY_LIMIT)
        } else {
            limit
        };
        let spans = self
            .store
            .activity_spans(from_ms, to_ms, fetch)
            .map_err(|e| e.to_string())?;
        let matched: Vec<ActivitySpan> = spans
            .into_iter()
            .filter(|span| match app {
                Some(wanted) => span
                    .application_name
                    .as_deref()
                    .is_some_and(|name| name.eq_ignore_ascii_case(wanted)),
                None => true,
            })
            .collect();
        if matched.is_empty() {
            return Ok(self.nothing_found("activity", from_ms, to_ms));
        }
        let filled = matched.len() >= limit;
        let last_ms = matched.last().map_or(to_ms, |span| span.end_ms);
        let mut lines: Vec<String> = matched
            .into_iter()
            .take(limit)
            .map(|span| {
                format!(
                    "{} – {}  {}",
                    clock_label(span.start_ms),
                    clock_label(span.end_ms),
                    describe_span_place(&span)
                )
            })
            .collect();
        if filled {
            lines.push(more_from(limit, "spans", last_ms));
        }
        Ok(lines.join("\n"))
    }

    /// The narrowing both searches share. Identical on purpose: an agent that
    /// has to remember which search can be bounded by what will bound neither.
    fn search_filter(&self, args: &Value) -> Result<SearchFilter, String> {
        let from_ms = args.get("from_ms").and_then(Value::as_i64);
        let to_ms = args.get("to_ms").and_then(Value::as_i64);
        let (from_ms, to_ms) = match (from_ms, to_ms) {
            (Some(from), Some(to)) if from > to => (Some(to), Some(from)),
            pair => pair,
        };
        if let (Some(from), Some(to)) = (from_ms, to_ms) {
            self.check_range(from, to)?;
        }
        Ok(SearchFilter {
            from_ms,
            to_ms,
            app: optional_text(args, "app").map(ToOwned::to_owned),
        })
    }

    fn require_range(&self, args: &Value) -> Result<(i64, i64), String> {
        let from_ms = args
            .get("from_ms")
            .and_then(Value::as_i64)
            .ok_or_else(|| missing_range("from_ms"))?;
        let to_ms = args
            .get("to_ms")
            .and_then(Value::as_i64)
            .ok_or_else(|| missing_range("to_ms"))?;
        let (from_ms, to_ms) = if from_ms <= to_ms {
            (from_ms, to_ms)
        } else {
            (to_ms, from_ms)
        };
        self.check_range(from_ms, to_ms)?;
        Ok((from_ms, to_ms))
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
                 The recording covers {} (from_ms={first}, to_ms={last}). {} \
                 Call get_now and copy a range out of its table rather than \
                 working one out.",
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
            Ok(Some((first, last))) => {
                format!(" The recording covers {}.", describe_span(first, last))
            }
            _ => String::new(),
        };
        format!(
            "// no {what} between {}.{coverage} {}",
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

/// One row of `get_now`'s table.
struct ClockPeriod {
    label: &'static str,
    dates: String,
    from_ms: i64,
    to_ms: i64,
}

/// Every period `get_now` spells out.
///
/// One list, read by the tool and by the tests that hold the catalog to it.
/// The individual days come first because they are what most questions name;
/// the aggregates after, because "last month" is asked of a month, not a day.
fn clock_periods(now_ms: i64) -> Vec<ClockPeriod> {
    let mut periods = Vec::new();
    let (today_start, today_end) = local_calendar_day_bounds_ms(now_ms);
    for index in 0..CLOCK_DAYS {
        let (from_ms, to_ms) = if index == 0 {
            (today_start, today_end)
        } else {
            local_calendar_day_bounds_ms(today_start.saturating_sub(index * DAY_MS))
        };
        periods.push(ClockPeriod {
            label: match index {
                0 => "today",
                1 => "yesterday",
                _ => "",
            },
            dates: local_date(from_ms),
            from_ms,
            to_ms,
        });
    }
    let mut span = |label: &'static str, bounds: Option<(i64, i64)>| {
        if let Some((from_ms, to_ms)) = bounds {
            periods.push(ClockPeriod {
                label,
                dates: format!("{} – {}", short_date(from_ms), short_date(to_ms)),
                from_ms,
                to_ms,
            });
        }
    };
    let this_week = local_week_bounds_ms(now_ms);
    span("this week", this_week);
    span(
        "last week",
        this_week.and_then(|(start, _)| local_week_bounds_ms(start.saturating_sub(DAY_MS))),
    );
    let this_month = local_month_bounds_ms(now_ms);
    span("this month", this_month);
    span(
        "last month",
        this_month.and_then(|(start, _)| local_month_bounds_ms(start.saturating_sub(DAY_MS))),
    );
    periods
}

/// The local calendar week containing `at_ms`, Monday through Sunday.
///
/// Monday because that is what both ISO-8601 and the languages this is asked
/// in mean by "last week". A different question from a rolling seven days, not
/// a rounder version of it: asked on a Monday, the rolling window is six days
/// of last week and one of this one, which answers neither.
fn local_week_bounds_ms(at_ms: i64) -> Option<(i64, i64)> {
    use chrono::{Datelike as _, Days};

    let date = local_date_of(at_ms)?;
    let monday =
        date.checked_sub_days(Days::new(u64::from(date.weekday().num_days_from_monday())))?;
    let sunday = monday.checked_add_days(Days::new(6))?;
    Some((day_bounds_for_date(monday)?.0, day_bounds_for_date(sunday)?.1))
}

/// The local calendar month containing `at_ms`.
fn local_month_bounds_ms(at_ms: i64) -> Option<(i64, i64)> {
    use chrono::{Datelike as _, Days};

    let date = local_date_of(at_ms)?;
    let first = date.with_day(1)?;
    // Into the next month, then back a day: month lengths and leap years are
    // chrono's problem, not ours.
    let last = first
        .checked_add_days(Days::new(31))?
        .with_day(1)?
        .checked_sub_days(Days::new(1))?;
    Some((day_bounds_for_date(first)?.0, day_bounds_for_date(last)?.1))
}

fn local_date_of(at_ms: i64) -> Option<chrono::NaiveDate> {
    Some(
        chrono::DateTime::from_timestamp_millis(at_ms)?
            .with_timezone(&Local)
            .date_naive(),
    )
}

/// Local calendar bounds of a date.
///
/// Resolved through [`local_calendar_day_bounds_ms`] from midday rather than by
/// arithmetic, so the day a clock change falls on is still its own whole day.
fn day_bounds_for_date(date: chrono::NaiveDate) -> Option<(i64, i64)> {
    use chrono::TimeZone as _;

    let midday = date.and_hms_opt(12, 0, 0)?;
    let instant = Local.from_local_datetime(&midday).earliest()?;
    Some(local_calendar_day_bounds_ms(instant.timestamp_millis()))
}

/// A local calendar day written as `YYYY-MM-DD` — the one string form any tool
/// accepts, and the same column `get_now` prints.
fn parse_local_day(text: &str) -> Option<(i64, i64)> {
    let date = chrono::NaiveDate::parse_from_str(text.trim(), "%Y-%m-%d").ok()?;
    day_bounds_for_date(date)
}

/// The day, rendered at one of two densities. See [`ToolHost::get_day_summary`]
/// for why there are two.
fn render_day(summary: &afterray_store::DaySummary, detail: bool) -> String {
    let mut lines = vec![format!(
        "Day {} — {}.{}",
        summary.day,
        plural(
            summary.slots.len(),
            "stretch with activity",
            "stretches with activity"
        ),
        if detail {
            ""
        } else {
            " Too many to describe in full, so this is titles only — \
             call get_slot_card with an at_ms below for what happened inside one."
        }
    )];
    let mut unsummarised = 0_usize;
    for slot in &summary.slots {
        let clock = clock_label(slot.slot_start_ms);
        let Some(title) = slot.title.as_deref() else {
            // Say so rather than presenting the app list as a finding. A model
            // handed "Zed 14m · Chrome 9m" with no marker will report it as
            // what the user did.
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
            continue;
        };

        let threads = slot.threads.as_deref().filter(|threads| !threads.is_empty());
        // The anchor is the stretch's first frame, and the threads below
        // usually cite it too. Only offer it when they cite nothing, so a
        // stretch always has one id to point at and never the same id twice.
        let cited = threads.is_some_and(|threads| threads.iter().any(|t| !t.moment_ids.is_empty()));
        let mut header = format!("{clock} at_ms={} — {title}", slot.slot_start_ms);
        if let (false, Some(anchor)) = (cited && detail, &slot.anchor_moment_id) {
            let _ = write!(header, " [moment {anchor}]");
        }
        lines.push(header);
        if !detail {
            continue;
        }

        match threads {
            Some(threads) => {
                for thread in threads {
                    lines.push(format!(
                        "    · {}",
                        thread_line(thread, MAX_DAY_THREAD_MOMENTS)
                    ));
                }
            }
            // A v1 row, or a v2 card whose model wrote no threads.
            None => {
                for bullet in slot.bullets.iter().flatten() {
                    lines.push(format!("    · {bullet}"));
                }
            }
        }
        if let Some(names) = joined(slot.entities.as_deref(), MAX_ENTITIES, |entity| {
            entity.text.clone()
        }) {
            lines.push(format!("    names: {names}"));
        }
        if let Some(decisions) = joined(slot.decisions.as_deref(), MAX_DECISIONS, Clone::clone) {
            lines.push(format!("    decided: {decisions}"));
        }
        // `not_captured` is deliberately absent. It is the honest-gaps list,
        // and it earns its place when one stretch is under the microscope —
        // but a day of per-stretch caveats is the first thing the budget
        // should spend nothing on, and paying for it here costs the model the
        // end of the day.
    }
    if unsummarised > 0 {
        lines.push(format!(
            "\n{unsummarised} of {} stretches {} no summary yet. For those, \
             call get_slot_card with the at_ms above to read the evidence directly.",
            summary.slots.len(),
            if unsummarised == 1 { "has" } else { "have" }
        ));
    }
    lines.join("\n")
}

/// One thread of a stretch, with the frames it cites.
///
/// The moment ids ride on the line that mentions the work rather than in a
/// list at the end, so an agent quoting the line has the citation in hand.
fn thread_line(thread: &afterray_store::T2Thread, max_moments: usize) -> String {
    let mut line = match (thread.name.trim(), thread.prose.trim()) {
        ("", prose) => prose.to_owned(),
        (name, "") => name.to_owned(),
        (name, prose) => format!("{name}: {prose}"),
    };
    let cited: Vec<String> = thread
        .moment_ids
        .iter()
        .take(max_moments)
        .cloned()
        .collect();
    if !cited.is_empty() {
        let _ = write!(line, " [{}]", cited.join(", "));
    }
    line
}

/// A capped, comma-joined line, or `None` when there is nothing to say. The
/// overflow is counted rather than dropped in silence.
fn joined<T>(items: Option<&[T]>, max: usize, render: impl Fn(&T) -> String) -> Option<String> {
    let items = items?;
    let rendered: Vec<String> = items
        .iter()
        .map(&render)
        .filter(|text| !text.trim().is_empty())
        .collect();
    if rendered.is_empty() {
        return None;
    }
    let extra = rendered.len().saturating_sub(max);
    let mut line = rendered.into_iter().take(max).collect::<Vec<_>>().join(", ");
    if extra > 0 {
        let _ = write!(line, " (+{extra} more)");
    }
    Some(line)
}

/// The line every bounded list ends with when it filled up. Nothing is dropped
/// in silence; a cut the model cannot see reads as "that is all there was".
fn more_from(returned: usize, unit: &str, last_ms: i64) -> String {
    format!(
        "// {returned} {unit}, reaching {} — there may be more. Call again \
         with from_ms={last_ms} for the rest.",
        format_local_time(last_ms)
    )
}

/// What a narrowed search says it narrowed to, so a short answer is never
/// mistaken for an empty vault.
fn describe_filter(filter: &SearchFilter) -> String {
    let mut parts = Vec::new();
    match (filter.from_ms, filter.to_ms) {
        (Some(from), Some(to)) => parts.push(format!("between {}", describe_span(from, to))),
        (Some(from), None) => parts.push(format!("after {}", format_local_datetime(from))),
        (None, Some(to)) => parts.push(format!("before {}", format_local_datetime(to))),
        (None, None) => {}
    }
    if let Some(app) = &filter.app {
        parts.push(format!("in {app}"));
    }
    if parts.is_empty() {
        String::new()
    } else {
        format!(" ({})", parts.join(", "))
    }
}

fn require_query<'a>(args: &'a Value, tool: &str) -> Result<&'a str, String> {
    args.get("query")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{tool} requires query — the words to look for"))
}

fn optional_text<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn parse_limit(args: &Value, default_limit: usize, max_limit: usize) -> usize {
    args.get("limit")
        .and_then(Value::as_u64)
        .map_or(default_limit, |n| n as usize)
        .clamp(1, max_limit)
}

fn missing_range(key: &str) -> String {
    format!(
        "{key} is required, in Unix milliseconds. Call get_now and copy a \
         from_ms/to_ms pair out of its table — do not work one out."
    )
}

/// "1 stretch" / "3 stretches". These lines are read by a model that will
/// repeat their phrasing back to a person.
fn plural(count: usize, one: &str, many: &str) -> String {
    format!("{count} {}", if count == 1 { one } else { many })
}

fn or_none(value: Option<&str>) -> String {
    value.map_or_else(|| "none recorded".to_owned(), ToOwned::to_owned)
}

/// Where a span was: the most specific of document, url, or window title.
fn describe_span_place(span: &ActivitySpan) -> String {
    let app = span.application_name.as_deref().unwrap_or("Unknown");
    let place = span
        .document
        .as_deref()
        .or(span.url.as_deref())
        .or(span.window_title.as_deref())
        .filter(|text| !text.trim().is_empty());
    match place {
        Some(place) => format!("{app}  {place}"),
        None => app.to_owned(),
    }
}

fn distinct_apps(spans: &[ActivitySpan], max: usize) -> Vec<String> {
    let mut apps: Vec<String> = Vec::new();
    for span in spans {
        let Some(name) = span
            .application_name
            .as_deref()
            .filter(|name| !name.is_empty())
        else {
            continue;
        };
        if !apps.iter().any(|seen| seen == name) {
            apps.push(name.to_owned());
        }
        if apps.len() >= max {
            break;
        }
    }
    apps
}

fn clock_label(at_ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(at_ms).map_or_else(
        || at_ms.to_string(),
        |instant| instant.with_timezone(&Local).format("%H:%M").to_string(),
    )
}

fn describe_span(from_ms: i64, to_ms: i64) -> String {
    format!(
        "{} … {} (from_ms={from_ms}, to_ms={to_ms})",
        format_local_datetime(from_ms),
        format_local_datetime(to_ms)
    )
}

fn format_local_datetime(ms: i64) -> String {
    format_local(ms, "%Y-%m-%d %H:%M:%S")
}

fn format_local_time(ms: i64) -> String {
    format_local(ms, "%H:%M:%S")
}

fn local_date(ms: i64) -> String {
    format_local(ms, "%Y-%m-%d")
}

fn short_date(ms: i64) -> String {
    format_local(ms, "%m-%d")
}

fn format_local(ms: i64, pattern: &str) -> String {
    chrono::DateTime::from_timestamp_millis(ms).map_or_else(
        || ms.to_string(),
        |instant| instant.with_timezone(&Local).format(pattern).to_string(),
    )
}

fn timezone_label(ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(ms).map_or_else(
        || "unknown".to_owned(),
        |instant| instant.with_timezone(&Local).format("%:z").to_string(),
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
        .ok_or_else(|| {
            "moment_id is required — copy one out of a summary line or a search hit".to_owned()
        })
}

/// Catalog shown to the LLM in agent prompts.
///
/// Every tool documents all of its arguments and the exact shape of what it
/// returns. That is longer than a one-line-per-tool list and it is the point:
/// the previous catalog said what each tool was *for* and left the model to
/// discover the rest a round at a time. Nothing here describes a caveat that
/// the tool's own output already states — an empty result explains itself, a
/// truncated one says where it stopped — because a caveat repeated in two
/// places is a caveat that will disagree with itself.
#[must_use]
#[allow(clippy::too_many_lines, reason = "it is one string literal")]
pub fn tool_catalog_text() -> &'static str {
    r#"Tools. Call at most one per reply, then wait for its result.

Timestamps are Unix milliseconds. Every one you use must be copied from a tool
result — never work one out yourself, you will get the year wrong. Values
written key=value are there to be copied verbatim.

────────────────────────────────────────────────────────────────────────
get_now   {}

  Takes nothing. Ask for it once, first, whenever the question involves a
  time — everything needed to name any period is in the one reply.

  Returns:
    Now: 2026-08-15 01:52 (+08:00)   now_ms=1786729937000
    today       2026-08-15      from_ms=1786723200000  to_ms=1786809599999
    yesterday   2026-08-14      from_ms=1786636800000  to_ms=1786723199999
                2026-08-13      from_ms=…              to_ms=…
                …five more days, one line each…
    this week   08-11 – 08-17   from_ms=…              to_ms=…
    last week   08-04 – 08-10   from_ms=…              to_ms=…
    this month  08-01 – 08-31   from_ms=…              to_ms=…
    last month  07-01 – 07-31   from_ms=…              to_ms=…
    Recording covers 2026-07-02 – 2026-08-15.
    Right now: Zed  tools.rs
    Today's apps: Zed, Chrome, Weixin

  The date column feeds get_day_summary; the from_ms/to_ms columns feed
  every tool taking a range. Nothing outside "Recording covers" exists.

────────────────────────────────────────────────────────────────────────
get_day_summary   {"day":"2026-08-13"}

  day     optional, "YYYY-MM-DD" as printed by get_now. Omit for today.

  Returns every stretch of that day, in time order:
    Day 2026-08-13 — 27 stretches with activity.
    14:20 at_ms=1786551600000 — Fixed the recall day panel
        · lody #38: hid idle slots from the day summary [01a00dc5-…]
        names: lody, afterray-store
        decided: hide idle slots rather than dim them

  A stretch nothing has summarised yet reads instead:
    15:10 at_ms=… — [not summarised: degraded] apps: Zed, Chrome
  That is "unknown", not a finding. get_slot_card reads it.

  On a busy day only the title line of each stretch comes back and the
  first line says "titles only".

────────────────────────────────────────────────────────────────────────
search_summaries   {"query":"lody"}

  query     required. Words matched inside written summaries — stretch
            titles, thread names and prose, recorded identifiers. Case
            and spacing are ignored. Exact text, not meaning.
  from_ms   optional, from get_now. Stretches starting at or after it.
  to_ms     optional, from get_now. Stretches starting at or before it.
  app       optional, e.g. "Chrome". Only stretches using that app.
  limit     optional, default 12, maximum 40.

  Returns one block per stretch, oldest first:
    "lody" appears in 3 summarised stretches.
    2026-08-13 14:20 at_ms=1786551600000 — Fixed the recall day panel
        · lody #38: hid idle slots from the day summary
        names: lody
        decided: hide idle slots rather than dim them
        moments: 01a00dc5-…, 01a00dc5-…

────────────────────────────────────────────────────────────────────────
search_evidence   {"query":"lody"}

  query     required. Words to find in text read off the screen and in
            transcripts. Exact text, not meaning.
  from_ms   optional, from get_now.
  to_ms     optional, from get_now.
  app       optional.
  limit     optional, default 8, maximum 20.

  Returns one block per hit, closest match first:
    3 matches for "lody".
    14:23:10 at_ms=1786551790000 moment=01a00dc5-… app=Zed
        stretch: at_ms=1786551600000 — Fixed the recall day panel
        …the matching screen text…

  Each hit already says where it was. The moment goes to
  get_moment_context; the at_ms goes to get_slot_card.

────────────────────────────────────────────────────────────────────────
get_slot_card   {"at_ms":1786551600000}

  at_ms   required. Any timestamp inside the stretch, copied from a
          summary line or a search hit.

  Returns that one stretch in full: which applications for how long, a
  timeline of what was open, the screen text each run introduced, and
  what was returned to repeatedly. This is how to read a stretch that
  has no summary yet.

────────────────────────────────────────────────────────────────────────
get_moment_context   {"moment_id":"01a00dc5-…"}

  moment_id   required, copied from a summary line or a search hit.

  Returns one captured frame, whole:
    moment=01a00dc5-… at_ms=1786551790000 2026-08-13 14:23:10
    app=Zed  window=tools.rs
    url=…
    document=…
    stretch: at_ms=1786551600000 — Fixed the recall day panel
    screen text: …everything read off the screen…
    accessibility: …headings, focused field, selected text…
    said: …anything transcribed at that moment…

  A line reading "none recorded" is ordinary — that frame had no such
  evidence. Prefer this over asking for the pieces separately.

────────────────────────────────────────────────────────────────────────
get_transcript   {"from_ms":…,"to_ms":…}

  from_ms   required, from get_now or an earlier result.
  to_ms     required.
  limit     optional, default 60, maximum 400.

  Returns one line per utterance:
    14:23:10 mic     …what was said…
    14:23:18 system  …what came out of the speakers…

────────────────────────────────────────────────────────────────────────
list_activity   {"from_ms":…,"to_ms":…}

  from_ms   required.
  to_ms     required.
  app       optional.
  limit     optional, default 40, maximum 200.

  Returns one line per unbroken stretch of use, in time order:
    14:20 – 14:37  Zed  tools.rs
    14:37 – 14:41  Chrome  github.com/loro-dev/afterray/pull/38

  Use it for when something started or stopped.
────────────────────────────────────────────────────────────────────────

Whatever a tool could not fit, it says so on its last line, with the
timestamp to resume from. Nothing is dropped in silence.

Reply with exactly one of:

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
    //! The tool catalog, the dispatch table and the system prompt are three
    //! hand-written texts describing one thing. They have already drifted
    //! twice: `get_day_summary` was dispatchable while chat's prompt still
    //! said to start with `get_slot_card`, and chat's prompt described a seed
    //! block months after the seed had changed shape.
    //!
    //! These tests read the dispatch arms out of this file's own source, so
    //! the `match` stays the single authority and the prose has to follow it.

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
        let prefixes = ["get_", "list_", "search_", "find_"];
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

    /// The production half of this file, without the tests that talk about it.
    fn production() -> &'static str {
        include_str!("tools.rs")
            .split_once("\n#[cfg(test)]")
            .map_or(include_str!("tools.rs"), |(before, _)| before)
    }

    #[test]
    fn the_scan_finds_the_real_dispatch_table() {
        let names = dispatched_names();
        assert_eq!(names.len(), 8, "scan found {names:?}");
        assert!(names.iter().any(|name| name == "get_day_summary"), "{names:?}");
        assert!(names.iter().any(|name| name == "search_summaries"), "{names:?}");
    }

    /// Nothing callable may be undocumented.
    #[test]
    fn every_dispatched_tool_appears_in_the_catalog() {
        let catalog = tool_catalog_text();
        for name in dispatched_names() {
            assert!(
                catalog.contains(&format!("{name}   ")),
                "`{name}` is callable but the catalog never lists it"
            );
        }
    }

    /// And nothing documented may be uncallable, or the model spends a round
    /// discovering `unknown tool`.
    #[test]
    fn every_catalogued_tool_is_dispatched() {
        let dispatched = dispatched_names();
        for named in tools_named_in(tool_catalog_text()) {
            assert!(
                dispatched.contains(&named),
                "the catalog names `{named}`, which nothing dispatches"
            );
        }
    }

    /// The rule this catalog was rewritten for: every argument a tool actually
    /// reads is spelled out for the model.
    ///
    /// A tool that quietly accepts an argument nobody documented is one the
    /// model can only discover by accident, and the previous catalog had
    /// several. Scanned from `args.get("…")`, so adding a parameter and
    /// forgetting the prose fails here rather than in a chat six weeks later.
    #[test]
    fn every_argument_the_tools_read_is_documented() {
        // `day_ms` is deliberately undocumented: it exists so a model that
        // copies a from_ms out of the clock table instead of the date beside
        // it still lands on the right day. Documenting it would offer a second
        // spelling of the same argument, which is what this catalog is for
        // getting rid of.
        const UNDOCUMENTED_ON_PURPOSE: [&str; 1] = ["day_ms"];

        let catalog = tool_catalog_text();
        let mut seen: Vec<String> = Vec::new();
        for (index, _) in production().match_indices("args.get(\"") {
            let rest = &production()[index + "args.get(\"".len()..];
            let Some((key, _)) = rest.split_once('"') else {
                continue;
            };
            if !seen.iter().any(|known| known == key) {
                seen.push(key.to_owned());
            }
        }
        assert!(seen.len() >= 6, "the argument scan found only {seen:?}");
        for key in seen {
            if UNDOCUMENTED_ON_PURPOSE.contains(&key.as_str()) {
                continue;
            }
            assert!(
                catalog.contains(&key),
                "`{key}` is read from tool arguments but the catalog never names it"
            );
        }
    }

    /// The catalog occupies the window whether or not it is read, so its size
    /// is a budget line and not a matter of taste.
    ///
    /// `ContextBudget::system_tokens` is documented as a *measurement*. If this
    /// fails, re-measure and move the constant deliberately — do not shave the
    /// catalog until the number fits.
    #[test]
    fn the_catalog_and_system_prompt_fit_the_budget_they_are_charged_to() {
        let system = format!(
            "{}\n\n{}",
            crate::agent::RECALL_SYSTEM_PROMPT,
            tool_catalog_text()
        );
        let tokens = afterray_harness::estimate_tokens(&system);
        let budgeted = afterray_harness::ContextBudget::DEFAULT.system_tokens;
        assert!(
            tokens <= budgeted,
            "the system prompt and catalog measure {tokens} tokens against a \
             budgeted {budgeted}; re-measure ContextBudget::system_tokens"
        );
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
            ("agent.rs", include_str!("agent.rs")),
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

    /// The seed is gone and must stay gone: a clock block in front of every
    /// turn changes on every turn, which breaks the cached prefix on every
    /// turn and is paid for whether or not the question involves a time.
    #[test]
    fn no_chat_surface_builds_a_clock_into_its_opening() {
        for (file, source) in [
            ("chat.rs", include_str!("chat.rs")),
            ("stream.rs", include_str!("stream.rs")),
        ] {
            // Cut only the trailing test module: `#[cfg(test)]` also marks
            // test-only imports near the top of a file, and splitting on the
            // first one hid everything this scan exists to look at.
            let production = source
                .rsplit_once("\n#[cfg(test)]\nmod ")
                .map_or(source, |(before, _)| before);
            assert!(
                production.contains("seed: String::new()"),
                "{file} stopped building an empty seed; the clock belongs in get_now"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // The fixtures build a real vault before narrowing it; production code in
    // this file only ever sees the read-only handle.
    use afterray_store::Vault;
    use afterray_store::VaultConfig;

    const DAY: i64 = 86_400_000;
    /// 2026-08-15, roughly. The screenshot that prompted the range guards
    /// showed a model reaching for 2024 instead.
    const NOW: i64 = 1_786_729_937_000;

    fn host_fixture() -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [7_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    fn host_for(vault: &Vault) -> ToolHost<'_> {
        ToolHost {
            store: ReadOnlyVault::new(vault),
            now_ms: NOW,
            budget: ContextBudget::DEFAULT,
        }
    }

    fn seed_moments(vault: &Vault, stamps: &[i64]) {
        let session = vault.create_session_sync(stamps[0]).unwrap();
        for stamp in stamps {
            vault
                .insert_moment(&session.id, *stamp, "image/jpeg", b"frame")
                .unwrap();
        }
    }

    /// A stretch summarised the way the T2 summariser writes them now: threads
    /// that cite their frames, grounded entities, decisions.
    fn seed_summarised(vault: &Vault, at_ms: i64) -> Vec<String> {
        seed_moments(vault, &[at_ms, at_ms + 60_000]);
        let card = vault.slot_card(at_ms, 10_000).unwrap();
        let ids = card.evidence.moment_ids.clone();
        vault
            .put_t2_summary_v2(
                &card,
                &afterray_store::T2CardV2 {
                    title: "Fixed the recall day panel".to_owned(),
                    description: "Idle slots were being drawn as work.".to_owned(),
                    threads: vec![afterray_store::T2Thread {
                        name: "lody #38".to_owned(),
                        prose: "hid idle slots from the day summary".to_owned(),
                        moment_ids: ids.clone(),
                    }],
                    entities: vec![afterray_store::T2Entity {
                        text: "lody".to_owned(),
                        kind: Some("project".to_owned()),
                        moment_id: ids.first().cloned(),
                    }],
                    decisions: vec!["Hide idle slots rather than dim them".to_owned()],
                    not_captured: vec!["whether the branch was pushed".to_owned()],
                    category: Some("coding".to_owned()),
                    confidence: Some(0.8),
                },
                "test",
                at_ms,
                Some(1),
            )
            .unwrap();
        ids
    }

    /// The one reply that has to carry everything: a model that reads it must
    /// be able to name any period without doing arithmetic.
    #[tokio::test]
    async fn get_now_hands_over_a_table_that_can_be_copied() {
        let (_dir, vault) = host_fixture();
        seed_moments(&vault, &[NOW - 10 * DAY, NOW - 60_000]);
        let host = host_for(&vault);

        let text = host.invoke("get_now", &json!({})).await.unwrap().text;
        assert!(text.contains(&format!("now_ms={NOW}")), "{text}");
        // Dates beside the numbers, so a date read off the screen can be
        // matched against a row rather than converted.
        for period in clock_periods(NOW) {
            assert!(
                text.contains(&format!(
                    "from_ms={}  to_ms={}",
                    period.from_ms, period.to_ms
                )),
                "`{}` is missing its copyable pair: {text}",
                period.label
            );
            assert!(text.contains(&period.dates), "{}: {text}", period.label);
        }
        for label in ["today", "yesterday", "this week", "last week", "last month"] {
            assert!(text.contains(label), "`{label}` is missing: {text}");
        }
        assert!(text.contains("Recording covers"), "{text}");
    }

    /// Structural, not against fixed dates: whichever weekday `NOW` lands on,
    /// the days must tile backwards and the weeks must meet exactly.
    #[test]
    fn the_clock_table_tiles_the_calendar() {
        use chrono::Datelike as _;

        let periods = clock_periods(NOW);
        let find = |label: &str| {
            periods
                .iter()
                .find(|period| period.label == label)
                .map(|period| (period.from_ms, period.to_ms))
                .expect("period is missing")
        };

        // Seven consecutive days, newest first, each meeting the next.
        let days: Vec<&ClockPeriod> = periods
            .iter()
            .take(usize::try_from(CLOCK_DAYS).unwrap())
            .collect();
        assert_eq!(days.len(), 7);
        for pair in days.windows(2) {
            assert_eq!(
                pair[1].to_ms + 1,
                pair[0].from_ms,
                "days {} and {} do not meet",
                pair[1].dates,
                pair[0].dates
            );
        }
        assert!(days[0].from_ms <= NOW && NOW <= days[0].to_ms, "today is wrong");

        let (this_week_start, _) = find("this week");
        let (_, last_week_end) = find("last week");
        assert_eq!(last_week_end + 1, this_week_start, "the weeks do not meet");
        let (this_month_start, _) = find("this month");
        let (_, last_month_end) = find("last month");
        assert_eq!(last_month_end + 1, this_month_start, "the months do not meet");

        let weekday = chrono::DateTime::from_timestamp_millis(this_week_start)
            .unwrap()
            .with_timezone(&Local)
            .weekday();
        assert_eq!(weekday, chrono::Weekday::Mon, "the week starts on {weekday}");
    }

    /// The date column of the clock table is what this argument takes. One
    /// spelling, and the same one the model just read.
    #[tokio::test]
    async fn a_day_is_named_by_its_date() {
        let (_dir, vault) = host_fixture();
        let yesterday_noon = local_calendar_day_bounds_ms(NOW - DAY).0 + 12 * 3_600_000;
        seed_summarised(&vault, yesterday_noon);
        seed_moments(&vault, &[NOW - 60_000]);
        let host = host_for(&vault);

        let day = afterray_store::local_day_for(yesterday_noon);
        let text = host
            .invoke("get_day_summary", &json!({"day": day}))
            .await
            .unwrap()
            .text;
        assert!(text.contains(&format!("Day {day}")), "{text}");
        assert!(text.contains("Fixed the recall day panel"), "{text}");

        // A date that is not one says so, rather than silently answering about
        // today.
        let error = host
            .invoke("get_day_summary", &json!({"day": "yesterday"}))
            .await
            .unwrap_err();
        assert!(error.contains("2026-08-13"), "{error}");
    }

    /// The stored card already holds the frames, the names and the decisions;
    /// the day summary used to project all of it down to title + bullets.
    #[tokio::test]
    async fn the_day_summary_carries_citations_names_and_decisions() {
        let (_dir, vault) = host_fixture();
        let noon = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        let ids = seed_summarised(&vault, noon);
        let host = host_for(&vault);

        let text = host.invoke("get_day_summary", &json!({})).await.unwrap().text;
        assert!(text.contains("Fixed the recall day panel"), "{text}");
        assert!(text.contains("hid idle slots from the day summary"), "{text}");
        assert!(text.contains(&ids[0]), "no moment id to cite: {text}");
        assert!(text.contains("names: lody"), "{text}");
        assert!(
            text.contains("decided: Hide idle slots rather than dim them"),
            "{text}"
        );
        // `not_captured` is not rendered here; the day-scale budget cannot
        // afford a caveat per stretch.
        assert!(!text.contains("not captured"), "{text}");
    }

    /// A worked day must arrive whole.
    ///
    /// A day is ~48 ten-minute stretches; describing each in full costs about
    /// four times `tool_result_tokens`, and the cut falls on the tail — so
    /// "what did I do today" came back having silently deleted the afternoon.
    /// Losing the detail of a stretch costs one more call; losing the stretch
    /// costs a wrong answer. The summaries are Chinese because that is the
    /// expensive case: a token per character, not a quarter of one.
    #[tokio::test]
    async fn a_busy_day_arrives_whole_even_if_it_arrives_compact() {
        let (_dir, vault) = host_fixture();
        let day_start = local_calendar_day_bounds_ms(NOW).0;
        let session = vault.create_session_sync(day_start).unwrap();
        let mut starts = Vec::new();
        for index in 0..48_i64 {
            let at_ms = day_start + index * 600_000;
            starts.push(at_ms);
            for step in 0..3_i64 {
                vault
                    .insert_moment(&session.id, at_ms + step * 60_000, "image/jpeg", b"f")
                    .unwrap();
            }
            let card = vault.slot_card(at_ms, 10_000).unwrap();
            let ids = card.evidence.moment_ids.clone();
            vault
                .put_t2_summary_v2(
                    &card,
                    &afterray_store::T2CardV2 {
                        title: "修复回忆面板的空闲时段显示".to_owned(),
                        description: "空闲时段被当成工作画了出来。".to_owned(),
                        threads: vec![afterray_store::T2Thread {
                            name: "lody #38".to_owned(),
                            prose: "把空闲时段从日摘要面板里隐藏掉，改了渲染分支".to_owned(),
                            moment_ids: ids.clone(),
                        }],
                        entities: vec![afterray_store::T2Entity {
                            text: "lody".to_owned(),
                            kind: None,
                            moment_id: ids.first().cloned(),
                        }],
                        decisions: vec!["隐藏而不是置灰空闲时段".to_owned()],
                        not_captured: vec![],
                        category: Some("coding".to_owned()),
                        confidence: Some(0.8),
                    },
                    "test",
                    at_ms,
                    Some(1),
                )
                .unwrap();
        }
        let host = ToolHost {
            store: ReadOnlyVault::new(&vault),
            now_ms: day_start + 8 * 3_600_000,
            budget: ContextBudget::DEFAULT,
        };

        let result = host.invoke("get_day_summary", &json!({})).await.unwrap();
        assert!(
            !result.truncated,
            "a day of ordinary length did not fit: {} tokens against {}",
            afterray_harness::estimate_tokens(&result.text),
            ContextBudget::DEFAULT.tool_result_tokens()
        );
        for at_ms in &starts {
            assert!(
                result.text.contains(&format!("at_ms={at_ms}")),
                "the stretch at {at_ms} was dropped from the day"
            );
        }
        // It got there by dropping detail, and says so — otherwise the model
        // reads the absence as "nothing else was going on".
        assert!(result.text.contains("titles only"), "{}", result.text);
    }

    /// The index the day panel could never be.
    #[tokio::test]
    async fn search_summaries_locates_the_stretch_that_names_it() {
        let (_dir, vault) = host_fixture();
        let noon = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        let ids = seed_summarised(&vault, noon);
        let host = host_for(&vault);

        let text = host
            .invoke("search_summaries", &json!({"query": "lody"}))
            .await
            .unwrap()
            .text;
        assert!(text.contains("Fixed the recall day panel"), "{text}");
        assert!(text.contains(&format!("at_ms={noon}")), "{text}");
        assert!(text.contains(&ids[0]), "no frame to cite: {text}");
        assert!(text.contains("decided: Hide idle slots"), "{text}");
    }

    /// Only summarised stretches are searchable this way, so an empty answer
    /// must not read as "it never happened" — that is a false negative the
    /// model would report as fact.
    #[tokio::test]
    async fn search_summaries_says_it_only_reads_written_summaries() {
        let (_dir, vault) = host_fixture();
        seed_summarised(&vault, local_calendar_day_bounds_ms(NOW).0 + 3_600_000);
        let host = host_for(&vault);

        let text = host
            .invoke("search_summaries", &json!({"query": "kubernetes"}))
            .await
            .unwrap()
            .text;
        assert!(text.contains("written summaries only"), "{text}");
        assert!(text.contains("search_evidence"), "{text}");
    }

    /// Both searches take the same narrowing, and the narrowing has to reach
    /// the query rather than filter its output: ranked-then-filtered answers
    /// "the best matches anywhere, if any happen to fall in this range".
    #[tokio::test]
    async fn both_searches_narrow_by_time_and_application() {
        let (_dir, vault) = host_fixture();
        let day_start = local_calendar_day_bounds_ms(NOW).0;
        let session = vault.create_session_sync(day_start).unwrap();
        let morning = day_start + 3_600_000;
        let evening = day_start + 10 * 3_600_000;
        for at_ms in [morning, evening] {
            let moment = vault
                .insert_moment(&session.id, at_ms, "image/jpeg", b"frame")
                .unwrap();
            vault
                .insert_text_evidence(
                    &session.id,
                    Some(&moment.id),
                    None,
                    "ocr",
                    "lody notes on screen",
                    at_ms,
                    None,
                    "ocr-model",
                    None,
                )
                .unwrap();
        }
        let host = host_for(&vault);

        let all = host
            .invoke("search_evidence", &json!({"query": "lody"}))
            .await
            .unwrap()
            .text;
        assert!(all.contains("2 matches"), "{all}");

        // Narrowed to the morning, and the ranking alone would not have
        // chosen it: one result, and it is the earlier one.
        let bounded = host
            .invoke(
                "search_evidence",
                &json!({"query": "lody", "from_ms": morning - 1, "to_ms": morning + 1, "limit": 1}),
            )
            .await
            .unwrap()
            .text;
        assert!(bounded.contains("1 match"), "{bounded}");
        assert!(bounded.contains(&format!("at_ms={morning}")), "{bounded}");
        // And it says what it narrowed to, so a short answer is never read as
        // an empty vault.
        assert!(bounded.contains("between"), "{bounded}");

        let by_app = host
            .invoke(
                "search_evidence",
                &json!({"query": "lody", "app": "NoSuchApp"}),
            )
            .await
            .unwrap()
            .text;
        assert!(by_app.contains("nothing captured"), "{by_app}");
        assert!(by_app.contains("in NoSuchApp"), "{by_app}");
    }

    /// A hit that cannot be placed costs a round to place. Time, frame, app
    /// and the stretch it belongs to all ride along.
    #[tokio::test]
    async fn a_search_hit_says_where_it_was() {
        let (_dir, vault) = host_fixture();
        let noon = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        let ids = seed_summarised(&vault, noon);
        vault
            .insert_text_evidence(
                &vault.moment_by_id(&ids[0]).unwrap().unwrap().session_id,
                Some(&ids[0]),
                None,
                "ocr",
                "recall day panel on screen",
                noon,
                None,
                "ocr-model",
                None,
            )
            .unwrap();
        let host = host_for(&vault);

        let text = host
            .invoke("search_evidence", &json!({"query": "panel"}))
            .await
            .unwrap()
            .text;
        assert!(text.contains(&format!("moment={}", ids[0])), "{text}");
        assert!(text.contains(&format!("at_ms={noon}")), "{text}");
        assert!(text.contains("stretch: at_ms="), "{text}");
        assert!(text.contains("Fixed the recall day panel"), "{text}");
    }

    /// Three reads of one instant, billed once.
    #[tokio::test]
    async fn get_moment_context_answers_in_one_call() {
        let (_dir, vault) = host_fixture();
        let noon = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        let ids = seed_summarised(&vault, noon);
        let host = host_for(&vault);

        let text = host
            .invoke("get_moment_context", &json!({"moment_id": ids[0]}))
            .await
            .unwrap()
            .text;
        assert!(text.contains(&format!("moment={}", ids[0])), "{text}");
        assert!(text.contains(&format!("at_ms={noon}")), "{text}");
        // The stretch it belongs to, so the model can go up as well as down.
        assert!(text.contains("Fixed the recall day panel"), "{text}");
        // Absent evidence is ordinary, and reported as an absence rather than
        // as a failed read the model would retry.
        for field in ["screen text:", "accessibility:", "said:"] {
            assert!(text.contains(field), "{field} missing: {text}");
        }
        assert!(text.contains("none recorded"), "{text}");
    }

    /// A cut the model cannot see reads as "that is all there was". Every
    /// bounded list says where it stopped and how to resume.
    #[tokio::test]
    async fn a_filled_transcript_says_where_it_stopped() {
        let (_dir, vault) = host_fixture();
        let start = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        let session = vault.create_session_sync(start).unwrap();
        seed_moments(&vault, &[start]);
        let segment = vault
            .insert_audio_segment(&session.id, afterray_protocol::AudioTrack::Microphone, start, start + 600_000, "audio/mp4", b"aud")
            .unwrap();
        for index in 0..8_i64 {
            vault
                .insert_text_evidence(
                    &session.id,
                    None,
                    Some(&segment.id),
                    "transcript",
                    &format!("line {index}"),
                    start + index * 1_000,
                    None,
                    "asr",
                    None,
                )
                .unwrap();
        }
        let host = host_for(&vault);

        let text = host
            .invoke(
                "get_transcript",
                &json!({"from_ms": start, "to_ms": start + 600_000, "limit": 3}),
            )
            .await
            .unwrap()
            .text;
        assert!(text.contains("line 0"), "{text}");
        assert!(text.contains("3 lines"), "{text}");
        assert!(text.contains("there may be more"), "{text}");
        assert!(text.contains("from_ms="), "{text}");
    }

    #[tokio::test]
    async fn list_activity_reports_spans_and_narrows_by_app() {
        let (_dir, vault) = host_fixture();
        let start = local_calendar_day_bounds_ms(NOW).0 + 3_600_000;
        seed_moments(&vault, &[start, start + 60_000]);
        let host = host_for(&vault);

        let text = host
            .invoke(
                "list_activity",
                &json!({"from_ms": start, "to_ms": start + 600_000}),
            )
            .await
            .unwrap()
            .text;
        assert!(text.contains(" – "), "no span line: {text}");

        let filtered = host
            .invoke(
                "list_activity",
                &json!({"from_ms": start, "to_ms": start + 600_000, "app": "NoSuchApp"}),
            )
            .await
            .unwrap()
            .text;
        assert!(filtered.contains("no activity"), "{filtered}");
    }

    #[tokio::test]
    async fn window_outside_history_explains_itself() {
        let (_dir, vault) = host_fixture();
        seed_moments(&vault, &[NOW - DAY, NOW - 60_000]);
        let host = host_for(&vault);

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
    async fn empty_vault_is_reported_rather_than_silently_empty() {
        let (_dir, vault) = host_fixture();
        let host = host_for(&vault);

        let error = host
            .invoke("list_activity", &json!({"from_ms": 0, "to_ms": NOW}))
            .await
            .unwrap_err();
        assert!(error.contains("no captures at all yet"), "{error}");
    }

    /// A range that was never given must point at the one place to get one.
    #[tokio::test]
    async fn a_missing_range_points_at_the_clock() {
        let (_dir, vault) = host_fixture();
        seed_moments(&vault, &[NOW - 60_000]);
        let host = host_for(&vault);

        let error = host
            .invoke("list_activity", &json!({"limit": 5}))
            .await
            .unwrap_err();
        assert!(error.contains("get_now"), "{error}");
        assert!(error.contains("do not work one out"), "{error}");
    }
}
