//! The `TOOL`/`ARGS` ↔ `FINAL` wire format, and the gate that keeps drafts of
//! it out of the user's view.
//!
//! Small local models will not reliably emit JSON tool calls, so the protocol
//! is two lines of plain text. This module is the only place that knows it.
//!
//! It used to be two places. `agent.rs` and `stream.rs` each carried a parser,
//! and they had already diverged: one rejected unparseable `ARGS`, the other
//! silently substituted `{}` and called the tool anyway.

use serde_json::Value;

/// What a completed model round is asking for.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    /// A user-facing answer. The loop stops.
    Answer(String),
    /// A tool to run before the next round.
    Call { name: String, args: Value },
    /// Nothing usable came back.
    Empty,
}

/// Reads one round.
///
/// Order matters. `FINAL` wins over `TOOL` because a model that writes both is
/// far more often finishing than calling. Bare prose is accepted as an answer
/// last: local models ignore the schema often enough that refusing would strand
/// the turn on output the user could have read.
#[must_use]
pub fn classify(text: &str) -> Step {
    if let Some(answer) = parse_final(text) {
        return Step::Answer(answer);
    }
    if let Some((name, args)) = parse_tool_call(text) {
        return Step::Call { name, args };
    }
    let trimmed = text.trim();
    if trimmed.is_empty() {
        Step::Empty
    } else {
        Step::Answer(trimmed.to_owned())
    }
}

/// The body of a `FINAL` block, if this is one.
#[must_use]
pub fn parse_final(text: &str) -> Option<String> {
    let body = strip_final_prefix(text)?;
    let body = body.trim();
    if body.is_empty() {
        None
    } else {
        Some(body.to_owned())
    }
}

/// Everything after a leading `FINAL`, before trimming. `None` if absent.
#[must_use]
pub fn strip_final_prefix(text: &str) -> Option<String> {
    let trimmed = text.trim();
    let upper = trimmed.to_ascii_uppercase();
    let rest = upper.strip_prefix("FINAL")?;
    let original_rest = &trimmed[trimmed.len() - rest.len()..];
    Some(
        original_rest
            .trim_start_matches([':', ' ', '\n', '\r', '\t'])
            .to_owned(),
    )
}

/// A `TOOL name` / `ARGS {…}` pair.
///
/// Unparseable arguments make the whole call `None` rather than defaulting to
/// `{}`. Calling a tool with arguments the model did not write produces a
/// confidently wrong result — usually a range guard rejection the model then
/// has to reason about — where refusing sends the round back for a retry.
#[must_use]
pub fn parse_tool_call(text: &str) -> Option<(String, Value)> {
    let trimmed = text.trim();
    let mut name: Option<String> = None;
    let mut args_raw: Option<String> = None;
    for line in trimmed.lines() {
        let line = line.trim();
        let upper = line.to_ascii_uppercase();
        if let Some(rest) = upper.strip_prefix("TOOL") {
            let original = line[line.len() - rest.len()..].trim_start_matches([':', ' ', '\t']);
            if !original.is_empty() {
                name = Some(original.to_owned());
            }
        } else if let Some(rest) = upper.strip_prefix("ARGS") {
            let original = line[line.len() - rest.len()..].trim_start_matches([':', ' ', '\t']);
            args_raw = Some(original.to_owned());
        }
    }
    // Multi-line ARGS: everything after the first ARGS marker.
    if args_raw.is_none()
        && let Some(pos) = trimmed.to_ascii_uppercase().find("ARGS")
    {
        let after = trimmed[pos + 4..].trim_start_matches([':', ' ', '\n', '\r', '\t']);
        if after.starts_with('{') {
            args_raw = Some(after.to_owned());
        }
    }
    let name = name?;
    let args_raw = args_raw?;
    // Take the first JSON object if the model appended prose.
    let json_slice = extract_json_object(&args_raw).unwrap_or(args_raw.as_str());
    let args: Value = serde_json::from_str(json_slice).ok()?;
    if args.is_object() { Some((name, args)) } else { None }
}

/// The first balanced `{…}` in `text`.
#[must_use]
pub fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth = 0_i32;
    for (idx, ch) in text[start..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..=start + idx]);
                }
            }
            _ => {}
        }
    }
    None
}

/// Holds token deltas until it is clear they belong to the answer.
///
/// A round that turns out to be `TOOL get_ocr` must not have leaked "TOOL get_"
/// into the chat window on its way there, so deltas are buffered until the
/// first line can be classified.
#[derive(Debug, Default)]
pub struct AnswerGate {
    buf: String,
    state: GateState,
    emitted: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum GateState {
    #[default]
    Unknown,
    Answer,
    Hidden,
}

impl AnswerGate {
    /// Feeds one delta; returns whatever is now safe to show.
    pub fn push(&mut self, delta: &str) -> Vec<String> {
        match self.state {
            GateState::Hidden => Vec::new(),
            GateState::Answer => {
                if delta.is_empty() {
                    Vec::new()
                } else {
                    self.emitted = true;
                    vec![delta.to_owned()]
                }
            }
            GateState::Unknown => {
                self.buf.push_str(delta);
                self.classify()
            }
        }
    }

    /// The answer to emit when the round streamed nothing usable — an adapter
    /// that cannot stream, or one whose deltas were all buffered as a possible
    /// `TOOL` prefix that turned out to be `FINAL`.
    pub fn leftover_answer(&mut self, parsed: &str) -> Option<String> {
        if self.emitted || self.state == GateState::Hidden || parsed.is_empty() {
            None
        } else {
            Some(parsed.to_owned())
        }
    }

    fn classify(&mut self) -> Vec<String> {
        let trimmed = self.buf.trim_start();
        let upper = trimmed.to_ascii_uppercase();
        if is_open_prefix("FINAL", &upper) || is_open_prefix("TOOL", &upper) {
            return Vec::new();
        }
        if let Some(body) = strip_final_prefix(trimmed) {
            self.state = GateState::Answer;
            self.buf.clear();
            if body.is_empty() {
                return Vec::new();
            }
            self.emitted = true;
            return vec![body];
        }
        if first_line_is_tool(trimmed) {
            self.state = GateState::Hidden;
            self.buf.clear();
            return Vec::new();
        }
        self.state = GateState::Answer;
        let body = std::mem::take(&mut self.buf);
        if body.is_empty() {
            return Vec::new();
        }
        self.emitted = true;
        vec![body]
    }
}

/// Whether `upper` could still grow into `word` — "TO" might become "TOOL".
fn is_open_prefix(word: &str, upper: &str) -> bool {
    upper.is_empty() || (word.starts_with(upper) && upper.len() < word.len())
}

fn first_line_is_tool(text: &str) -> bool {
    text.trim_start()
        .lines()
        .next()
        .is_some_and(|line| line.trim().to_ascii_uppercase().starts_with("TOOL"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_final_block() {
        assert_eq!(
            parse_final("FINAL\nYou used Safari.").as_deref(),
            Some("You used Safari.")
        );
        assert_eq!(
            parse_final("FINAL: short answer").as_deref(),
            Some("short answer")
        );
    }

    #[test]
    fn parses_tool_call() {
        let (name, args) = parse_tool_call("TOOL get_ocr\nARGS {\"moment_id\":\"m1\"}\n").unwrap();
        assert_eq!(name, "get_ocr");
        assert_eq!(args, json!({"moment_id":"m1"}));
    }

    #[test]
    fn extracts_json_with_trailing_prose() {
        let raw = r#"{"moment_id":"abc"} then more text"#;
        assert_eq!(extract_json_object(raw), Some(r#"{"moment_id":"abc"}"#));
    }

    /// The behaviour the two old copies disagreed on. Guessing `{}` sends the
    /// tool arguments the model never wrote.
    #[test]
    fn rejects_invalid_or_non_object_tool_args() {
        assert!(parse_tool_call("TOOL get_ocr\nARGS {not json}").is_none());
        assert!(parse_tool_call("TOOL get_ocr\nARGS [\"moment_id\"]").is_none());
        assert!(parse_tool_call("TOOL get_ocr").is_none());
        assert_eq!(classify("TOOL get_ocr"), Step::Answer("TOOL get_ocr".into()));
    }

    #[test]
    fn classify_prefers_final_then_tool_then_prose() {
        assert_eq!(classify("FINAL\ndone"), Step::Answer("done".into()));
        assert_eq!(
            classify("TOOL get_now\nARGS {}"),
            Step::Call {
                name: "get_now".into(),
                args: json!({})
            }
        );
        assert_eq!(classify("You used Safari."), Step::Answer("You used Safari.".into()));
        assert_eq!(classify("   \n "), Step::Empty);
    }

    #[test]
    fn gate_hides_tool_drafts_and_streams_final() {
        let mut gate = AnswerGate::default();
        assert!(gate.push("TO").is_empty());
        assert!(gate.push("OL list_activity\nARGS {}").is_empty());
        assert!(gate.leftover_answer("ignored").is_none());

        let mut answer = AnswerGate::default();
        assert!(answer.push("FI").is_empty());
        assert_eq!(answer.push("NAL\n你今天"), ["你今天"]);
        assert_eq!(answer.push("下午"), ["下午"]);
        assert!(answer.leftover_answer("你今天下午").is_none());
    }

    #[test]
    fn gate_treats_bare_prose_as_the_answer() {
        let mut gate = AnswerGate::default();
        assert_eq!(gate.push("You used Safari."), ["You used Safari."]);
        assert!(gate.leftover_answer("You used Safari.").is_none());
    }

    /// An adapter that cannot stream emits nothing at all, so the parsed answer
    /// has to come out through the leftover path or the user sees a blank turn.
    #[test]
    fn gate_hands_back_the_answer_when_nothing_streamed() {
        let mut gate = AnswerGate::default();
        assert_eq!(gate.leftover_answer("the whole answer").as_deref(), Some("the whole answer"));
    }
}
