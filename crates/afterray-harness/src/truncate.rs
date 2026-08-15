//! Line-safe truncation for anything that goes into a prompt.
//!
//! Two invariants, both learned the hard way:
//!
//! 1. **Never emit a partial line.** Cutting by character count splits a tool
//!    result mid-JSON, and `{"moment_id": "01J2X` reads to the model as a
//!    complete — and wrong — value. The single exception is a first line that
//!    is on its own over budget; then there is nothing to keep whole, and the
//!    result says so through [`Budgeted::partial_line`].
//! 2. **Mark every seam.** Text that was silently shortened is worse than text
//!    that is obviously shortened: the model cannot ask for the rest of
//!    something it does not know is missing.
//!
//! Callers get a struct, not a string, so the daemon can tell the UI what was
//! dropped instead of the user wondering why an answer went vague.

use crate::tokens::{TokenCounter, estimate_tokens};

/// A shortened piece of text plus what it cost to shorten it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Budgeted {
    /// The text to put in the prompt, marker included.
    pub text: String,
    /// Whether anything was removed.
    pub truncated: bool,
    /// Whole lines removed. Zero when nothing was removed.
    pub dropped_lines: usize,
    /// Estimated tokens removed, for logging and the `usage` event.
    pub dropped_tokens: usize,
    /// Set when the budget could not hold even one whole line, so the single
    /// kept line was cut on a character boundary.
    pub partial_line: bool,
}

impl Budgeted {
    /// Text that never went through a budget — an error string, a fixture.
    #[must_use]
    pub fn verbatim(text: String) -> Self {
        Self::kept(text)
    }

    /// The untouched case, so callers can build one without branching.
    fn kept(text: String) -> Self {
        Self {
            text,
            truncated: false,
            dropped_lines: 0,
            dropped_tokens: 0,
            partial_line: false,
        }
    }
}

/// Tokens held back for the marker line itself, so adding it cannot push the
/// result back over budget.
const MARKER_RESERVE_TOKENS: usize = 32;

/// Room that has to be left over before it is worth cutting into the next line.
/// Below this the fragment is too short to say anything, and a clean stop reads
/// better than a word and a half.
const PARTIAL_LINE_MIN_TOKENS: usize = 64;

/// Keeps whole lines from the start of `text` until `max_tokens` is reached.
///
/// Head-first because our tool results are ordered most-useful-first: a JSON
/// array of hits, a day's slots in clock order, a card's timeline. The tail is
/// what a reader would skim.
#[must_use]
pub fn truncate_head(text: &str, max_tokens: usize) -> Budgeted {
    let total = estimate_tokens(text);
    if total <= max_tokens {
        return Budgeted::kept(text.to_owned());
    }
    if max_tokens == 0 {
        return Budgeted {
            text: marker(line_count(text), total),
            truncated: true,
            dropped_lines: line_count(text),
            dropped_tokens: total,
            partial_line: false,
        };
    }

    let body_budget = max_tokens.saturating_sub(MARKER_RESERVE_TOKENS);
    let lines: Vec<&str> = text.lines().collect();
    let mut kept: Vec<&str> = Vec::new();
    let mut used = 0_usize;
    for line in &lines {
        // +1 for the newline this line will be joined with.
        let cost = estimate_tokens(line) + 1;
        if used + cost > body_budget {
            break;
        }
        kept.push(line);
        used += cost;
    }

    if kept.is_empty() {
        // One line, over budget on its own. Nothing can be kept whole, so cut
        // it and be explicit that this is the exceptional case.
        let head = take_tokens(lines.first().copied().unwrap_or_default(), body_budget);
        let dropped_tokens = total.saturating_sub(estimate_tokens(&head));
        let dropped_lines = lines.len().saturating_sub(1);
        let mut out = head;
        out.push('\n');
        out.push_str(&marker(dropped_lines, dropped_tokens));
        return Budgeted {
            text: out,
            truncated: true,
            dropped_lines,
            dropped_tokens,
            partial_line: true,
        };
    }

    // The line that broke the loop may be the only one that carried anything.
    // A tool result is JSON, and `serde_json` puts a whole OCR page on the one
    // line that holds `"text"`; stopping cleanly before it keeps the envelope
    // and drops every word of the evidence, while most of the allowance goes
    // unspent. Cutting into that line spends the room on something.
    let mut partial_line = false;
    let leftover = body_budget.saturating_sub(used);
    if leftover >= PARTIAL_LINE_MIN_TOKENS {
        if let Some(next) = lines.get(kept.len()) {
            let head = take_tokens(next, leftover.saturating_sub(1));
            if !head.is_empty() {
                partial_line = true;
                let body = format!("{}\n{head}", kept.join("\n"));
                let dropped_lines = lines.len() - kept.len();
                let dropped_tokens = total.saturating_sub(estimate_tokens(&body));
                return Budgeted {
                    text: format!("{body}\n{}", marker(dropped_lines, dropped_tokens)),
                    truncated: true,
                    dropped_lines,
                    dropped_tokens,
                    partial_line,
                };
            }
        }
    }

    let dropped_lines = lines.len() - kept.len();
    let body = kept.join("\n");
    let dropped_tokens = total.saturating_sub(estimate_tokens(&body));
    let text = format!("{body}\n{}", marker(dropped_lines, dropped_tokens));
    Budgeted {
        text,
        truncated: true,
        dropped_lines,
        dropped_tokens,
        partial_line,
    }
}

/// Keeps whole lines from the *end* of `text` until `max_tokens` is reached.
///
/// The counterpart to [`truncate_head`], for text whose newest part matters
/// most: a folded conversation runs oldest to newest, so keeping its head keeps
/// exactly the turns nobody is asking about.
#[must_use]
pub fn truncate_tail(text: &str, max_tokens: usize) -> Budgeted {
    let total = estimate_tokens(text);
    if total <= max_tokens {
        return Budgeted::kept(text.to_owned());
    }
    if max_tokens == 0 {
        return Budgeted {
            text: marker(line_count(text), total),
            truncated: true,
            dropped_lines: line_count(text),
            dropped_tokens: total,
            partial_line: false,
        };
    }
    let body_budget = max_tokens.saturating_sub(MARKER_RESERVE_TOKENS);
    let lines: Vec<&str> = text.lines().collect();
    let mut kept: Vec<&str> = Vec::new();
    let mut used = 0_usize;
    for line in lines.iter().rev() {
        let cost = estimate_tokens(line) + 1;
        if used + cost > body_budget {
            break;
        }
        kept.push(line);
        used += cost;
    }
    kept.reverse();
    let dropped_lines = lines.len() - kept.len();
    let body = kept.join("\n");
    let dropped_tokens = total.saturating_sub(estimate_tokens(&body));
    Budgeted {
        text: format!("{}\n{body}", marker(dropped_lines, dropped_tokens)),
        truncated: true,
        dropped_lines,
        dropped_tokens,
        partial_line: false,
    }
}

/// The seam marker. Phrased as an instruction because a model that reads only
/// "truncated" tends to answer from the fragment instead of narrowing.
fn marker(dropped_lines: usize, dropped_tokens: usize) -> String {
    format!(
        "…[{dropped_lines} more lines (~{dropped_tokens} tokens) were cut to fit. \
         Narrow the time range, lower `limit`, or ask for one id.]"
    )
}

fn line_count(text: &str) -> usize {
    text.lines().count()
}

/// Longest prefix of `text` whose estimate stays within `max_tokens`.
fn take_tokens(text: &str, max_tokens: usize) -> String {
    if max_tokens == 0 {
        return String::new();
    }
    let mut out = String::new();
    let mut counter = TokenCounter::default();
    for ch in text.chars() {
        if counter.peek(ch) > max_tokens {
            break;
        }
        counter.push(ch);
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn json_rows(count: usize) -> String {
        (0..count)
            .map(|index| format!("  {{\"moment_id\": \"01J2X{index:04}\", \"at_ms\": 17867299370{index:02}}},"))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The shape every JSON tool result has: a short envelope and one line
    /// holding all the evidence. Stopping cleanly at the line boundary keeps
    /// the envelope, drops every word of the payload, and leaves most of the
    /// allowance unspent — the model is handed a receipt for evidence it never
    /// sees.
    #[test]
    fn a_payload_on_one_line_is_cut_into_rather_than_dropped_whole() {
        let payload = "the quick brown fox jumped over the lazy dog. ".repeat(1_200);
        let body = format!("{{\n  \"moment_id\": \"01J2X\",\n  \"text\": \"{payload}\"\n}}");
        let out = truncate_head(&body, 512);

        assert!(out.truncated);
        assert!(out.partial_line, "the payload line had to be cut into");
        assert!(
            out.text.contains("the quick brown fox"),
            "kept no evidence at all: {}",
            &out.text[..out.text.len().min(200)]
        );
        assert!(estimate_tokens(&out.text) <= 512, "over its own budget");
        // Most of the allowance is now spent on evidence rather than wasted:
        // stopping at the boundary kept about a fifth of it.
        assert!(
            estimate_tokens(&out.text) > 512 / 2,
            "only {} of 512 tokens used",
            estimate_tokens(&out.text)
        );
    }

    /// The preference is still whole lines: a body that fits line by line is
    /// never cut mid-line just because there is room left over.
    #[test]
    fn whole_lines_are_still_preferred_when_they_fit() {
        let out = truncate_head(&json_rows(400), 512);
        assert!(out.truncated);
        assert!(!out.partial_line, "no line should have been cut: {}", out.text);
    }

    #[test]
    fn short_text_is_returned_untouched() {
        let out = truncate_head("hello\nworld", 100);
        assert_eq!(out.text, "hello\nworld");
        assert!(!out.truncated);
        assert_eq!(out.dropped_lines, 0);
    }

    /// The bug this module exists for: a character cut lands inside a JSON
    /// object and the model reads the fragment as a whole value.
    #[test]
    fn never_cuts_inside_a_line() {
        let rows = json_rows(200);
        let out = truncate_head(&rows, 200);
        assert!(out.truncated);
        assert!(!out.partial_line);
        for line in out.text.lines() {
            if line.starts_with('…') {
                continue;
            }
            assert!(
                line.trim_end().ends_with("},"),
                "kept a partial row: {line}"
            );
        }
    }

    #[test]
    fn marks_the_seam_and_says_how_much_went() {
        let out = truncate_head(&json_rows(200), 200);
        let last = out.text.lines().next_back().unwrap();
        assert!(last.starts_with('…'), "{last}");
        assert!(last.contains("more lines"), "{last}");
        assert!(last.contains("Narrow the time range"), "{last}");
        assert_eq!(out.dropped_lines, 200 - out.text.lines().count() + 1);
        assert!(out.dropped_tokens > 0);
    }

    #[test]
    fn stays_within_the_budget() {
        for budget in [40_usize, 200, 1_000] {
            let out = truncate_head(&json_rows(500), budget);
            assert!(
                estimate_tokens(&out.text) <= budget,
                "budget {budget} exceeded: {}",
                estimate_tokens(&out.text)
            );
        }
    }

    /// One enormous line — a whole OCR page with no newlines — is the only case
    /// where a partial line is allowed, and it has to be flagged.
    #[test]
    fn one_oversized_line_is_cut_and_flagged() {
        let text = "x".repeat(10_000);
        let out = truncate_head(&text, 100);
        assert!(out.truncated);
        assert!(out.partial_line);
        assert_eq!(out.dropped_lines, 0);
        assert!(estimate_tokens(&out.text) <= 100);
        assert!(out.text.lines().next_back().unwrap().starts_with('…'));
    }

    #[test]
    fn chinese_lines_are_budgeted_by_token_not_character() {
        let line = "这一段是中文的屏幕文本，每个字大约算一个 token。";
        let text = (0..100).map(|_| line).collect::<Vec<_>>().join("\n");
        let out = truncate_head(&text, 200);
        assert!(out.truncated);
        assert!(estimate_tokens(&out.text) <= 200);
        // A character-based cut at the same number would have kept far more.
        assert!(out.text.lines().count() < 20, "{}", out.text.lines().count());
    }

    /// A folded conversation runs oldest to newest, so what has to survive is
    /// its end.
    #[test]
    fn tail_truncation_keeps_the_most_recent_lines() {
        let text = (0..200)
            .map(|index| format!("turn {index}"))
            .collect::<Vec<_>>()
            .join("\n");
        let out = truncate_tail(&text, 100);
        assert!(out.truncated);
        assert!(out.text.contains("turn 199"), "the newest turn was dropped");
        assert!(!out.text.contains("turn 0\n"), "{}", out.text);
        assert!(out.text.lines().next().unwrap().starts_with('…'));
        assert!(estimate_tokens(&out.text) <= 100);
    }

    #[test]
    fn zero_budget_keeps_only_the_marker() {
        let out = truncate_head("a\nb\nc", 0);
        assert!(out.truncated);
        assert!(out.text.starts_with('…'));
        assert_eq!(out.dropped_lines, 3);
    }
}
