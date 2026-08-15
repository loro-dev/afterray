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
    /// The round is clearly a tool call, and its arguments do not parse.
    ///
    /// Kept apart from [`Step::Answer`] deliberately. Treating it as prose sent
    /// the raw `TOOL …` text down the answer path, where the gate hid it for
    /// starting with `TOOL` — so the turn reported success and stored an empty
    /// assistant message. A malformed call has to be visible to the loop, which
    /// can hand the model its own mistake and let it try again.
    Malformed { name: String, reason: String },
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
    match parse_tool_call(text) {
        ToolCall::Parsed { name, args } => return Step::Call { name, args },
        ToolCall::Malformed { name, reason } => return Step::Malformed { name, reason },
        ToolCall::Absent => {}
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
    let rest = strip_keyword(trimmed, "FINAL")?;
    Some(rest.to_owned())
}

/// `text` with a leading `keyword` removed, if it is there **as a word**.
///
/// Without the boundary check, "Finally, I looked at Safari" begins with
/// `FINAL` and is delivered as "ly, I looked at Safari" — a sentence mangled
/// into nonsense by the parser rather than by the model. Only a separator or
/// the end of the text may follow the keyword.
fn strip_keyword<'a>(text: &'a str, keyword: &str) -> Option<&'a str> {
    let upper = text.to_ascii_uppercase();
    let rest = upper.strip_prefix(keyword)?;
    let boundary = rest
        .chars()
        .next()
        .is_none_or(|ch| ch == ':' || ch.is_whitespace());
    if !boundary {
        return None;
    }
    let original = &text[text.len() - rest.len()..];
    Some(original.trim_start_matches([':', ' ', '\n', '\r', '\t']))
}

/// What a round's text turned out to be, tool-wise.
#[derive(Debug, Clone, PartialEq)]
pub enum ToolCall {
    Parsed { name: String, args: Value },
    /// A `TOOL` line was present and the arguments could not be read.
    Malformed { name: String, reason: String },
    /// No tool call here at all.
    Absent,
}

/// A `TOOL name` / `ARGS {…}` pair.
///
/// Arguments are never guessed. Calling a tool with arguments the model did not
/// write produces a confidently wrong result — usually a range-guard rejection
/// the model then has to reason about — where reporting the mistake sends the
/// round back for a retry.
#[must_use]
pub fn parse_tool_call(text: &str) -> ToolCall {
    let trimmed = text.trim();
    let mut name: Option<String> = None;
    for line in trimmed.lines() {
        let line = line.trim();
        if let Some(rest) = strip_keyword(line, "TOOL")
            && !rest.is_empty()
        {
            name = Some(rest.to_owned());
            break;
        }
    }
    let Some(name) = name else {
        return ToolCall::Absent;
    };

    // Everything after the first ARGS marker, so a pretty-printed object that
    // begins on the `ARGS` line and continues over the next several is read as
    // one value. Taking only the rest of that line — which is what this used to
    // do — left `{` as the whole of the arguments.
    let Some(marker) = trimmed.to_ascii_uppercase().find("ARGS") else {
        return ToolCall::Malformed {
            name,
            reason: "no ARGS line".into(),
        };
    };
    let after = trimmed[marker + 4..].trim_start_matches([':', ' ', '\n', '\r', '\t']);
    let Some(slice) = extract_json_object(after) else {
        return ToolCall::Malformed {
            name,
            reason: "ARGS is not a complete JSON object".into(),
        };
    };
    match serde_json::from_str::<Value>(slice) {
        Ok(args) if args.is_object() => ToolCall::Parsed { name, args },
        Ok(_) => ToolCall::Malformed {
            name,
            reason: "ARGS must be a JSON object".into(),
        },
        Err(error) => ToolCall::Malformed {
            name,
            reason: format!("ARGS is not valid JSON: {error}"),
        },
    }
}

/// The first balanced `{…}` in `text`, ignoring braces inside JSON strings.
///
/// Counting braces blindly breaks on the arguments most worth getting right:
/// `{"query": "a } b"}` is a legal search, and a naive scan ends the object at
/// the brace inside the string.
#[must_use]
pub fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let mut depth = 0_i32;
    let mut in_string = false;
    let mut escaped = false;
    for (idx, ch) in text[start..].char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        match ch {
            '\\' if in_string => escaped = true,
            '"' => in_string = !in_string,
            '{' if !in_string => depth += 1,
            '}' if !in_string => {
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


    /// A pretty-printed ARGS block, which is what most models emit when the
    /// object has more than one field. This used to parse as `"{"`, fail, and
    /// then be reported as an answer.
    #[test]
    fn parses_args_spread_over_several_lines() {
        assert_eq!(
            parse_tool_call("TOOL search_evidence\nARGS {\n  \"query\": \"foo\",\n  \"limit\": 5\n}"),
            ToolCall::Parsed {
                name: "search_evidence".into(),
                args: json!({"query": "foo", "limit": 5}),
            }
        );
    }

    /// A brace inside a JSON string is legal and common in a search query.
    #[test]
    fn a_brace_inside_a_string_does_not_end_the_object() {
        assert_eq!(
            parse_tool_call(r#"TOOL search_evidence
ARGS {"query": "a } b"}"#),
            ToolCall::Parsed {
                name: "search_evidence".into(),
                args: json!({"query": "a } b"}),
            }
        );
        // And an escaped quote does not end the string.
        assert_eq!(
            extract_json_object(r#"{"query": "say \"} \" now"}"#),
            Some(r#"{"query": "say \"} \" now"}"#)
        );
    }

    /// The failure this all guards: a malformed call must never be mistaken for
    /// prose, because the gate then hides it and the turn "succeeds" blank.
    #[test]
    fn a_malformed_tool_call_is_not_an_answer() {
        for raw in [
            "TOOL search_evidence\nARGS {oops",
            "TOOL search_evidence\nARGS not-json-at-all",
            "TOOL search_evidence",
        ] {
            match classify(raw) {
                Step::Malformed { name, .. } => assert_eq!(name, "search_evidence"),
                other => panic!("{raw:?} classified as {other:?}"),
            }
        }
    }

    /// `FINAL` and `TOOL` are keywords, not prefixes. A model that begins its
    /// answer "Finally, …" had the word eaten and shipped "ly, …".
    #[test]
    fn a_word_that_merely_starts_with_a_keyword_is_prose() {
        assert_eq!(classify("Finally, you read the design doc."), 
            Step::Answer("Finally, you read the design doc.".into()));
        assert!(parse_final("Finality is a strong word").is_none());
        assert!(matches!(
            classify("Toolbars were open all afternoon."),
            Step::Answer(_)
        ));
        // The keywords themselves still work, with each separator.
        assert_eq!(parse_final("FINAL: done").as_deref(), Some("done"));
        assert_eq!(parse_final("FINAL\ndone").as_deref(), Some("done"));
        assert_eq!(parse_final("FINAL done").as_deref(), Some("done"));
    }

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
        assert_eq!(
            parse_tool_call("TOOL get_ocr\nARGS {\"moment_id\":\"m1\"}\n"),
            ToolCall::Parsed {
                name: "get_ocr".into(),
                args: json!({"moment_id":"m1"})
            }
        );
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
        assert!(matches!(
            parse_tool_call("TOOL get_ocr\nARGS {not json}"),
            ToolCall::Malformed { .. }
        ));
        assert!(matches!(
            parse_tool_call("TOOL get_ocr\nARGS [\"moment_id\"]"),
            ToolCall::Malformed { .. }
        ));
        assert!(matches!(
            parse_tool_call("TOOL get_ocr"),
            ToolCall::Malformed { .. }
        ));
        // And none of those may be mistaken for prose.
        assert!(matches!(classify("TOOL get_ocr"), Step::Malformed { .. }));
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
