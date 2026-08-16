//! The conversation as a list of messages, which is what a chat model wants.
//!
//! The loop used to hand the model one grown string per round. That works, but
//! it throws away the one property a chat API is built around: an **append-only
//! prefix**. Every provider caches on the longest identical prefix it has seen,
//! and a local runtime re-prefills only the part that changed. A prompt that is
//! rebuilt each turn — a different slice of history, a clock at the front —
//! matches nothing, and every turn pays full price for text it has already
//! processed.
//!
//! So the unit here is a message, and the rule is that a message, once emitted,
//! never changes. Anything volatile belongs at the *end*, next to the question,
//! not at the front where it invalidates everything behind it.

/// Who a message is from.
///
/// Deliberately the three roles every provider agrees on. Tool calls are
/// carried as assistant text and their results as user text (see
/// [`crate::transcript`]) rather than as a fourth role, because the shape of a
/// native tool-call message is the one thing providers do *not* agree on — and
/// a stored conversation that renders differently per provider is not a stored
/// conversation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    System,
    User,
    Assistant,
}

impl Role {
    /// The wire name every OpenAI-compatible and Ollama endpoint expects.
    #[must_use]
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
        }
    }
}

/// What a message is, beyond who said it.
///
/// Never goes on the wire — the seam sends `role` and `content` and nothing
/// else. It exists so a compaction policy can act on boundaries instead of
/// sniffing the text for a fence marker: the rule "fold tool results before
/// touching what a person wrote" needs to know which is which, and inferring
/// that from content is how a policy starts eating the wrong thing the day
/// somebody pastes a fence marker into a question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A question, an answer, anything a participant actually said.
    Text,
    /// The assistant asking for a tool.
    ToolCall,
    /// What that tool returned. The first thing to go under pressure: it is
    /// the largest, the most stale, and the only part that can be fetched
    /// again on demand.
    ToolResult,
    /// The harness talking to the model.
    Control,
}

/// One message. Immutable by construction, which is the point.
///
/// `content` is private and has no setter. A message is built whole and read
/// whole; the only way to "change" one is to build a different one, and the
/// only code allowed to swap one out is [`crate::history::History`]'s
/// compaction path. A `pub content: String` behind a `&mut Vec<Message>` — what
/// this was — meant any code anywhere could rewrite a message the model had
/// already been shown, and nothing would notice until a cache stopped matching.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub role: Role,
    pub kind: Kind,
    content: String,
}

impl Message {
    #[must_use]
    pub fn system(content: impl Into<String>) -> Self {
        Self::new(Role::System, Kind::Text, content)
    }

    #[must_use]
    pub fn user(content: impl Into<String>) -> Self {
        Self::new(Role::User, Kind::Text, content)
    }

    #[must_use]
    pub fn assistant(content: impl Into<String>) -> Self {
        Self::new(Role::Assistant, Kind::Text, content)
    }

    /// The assistant asking for a tool.
    #[must_use]
    pub fn tool_call(content: impl Into<String>) -> Self {
        Self::new(Role::Assistant, Kind::ToolCall, content)
    }

    /// What a tool returned. A user turn because that is the only role a
    /// provider will accept it as; `kind` is what says it is not a person.
    #[must_use]
    pub fn tool_result(content: impl Into<String>) -> Self {
        Self::new(Role::User, Kind::ToolResult, content)
    }

    /// The harness's own words — a correction, or a notice about the budget.
    #[must_use]
    pub fn control(content: impl Into<String>) -> Self {
        Self::new(Role::User, Kind::Control, content)
    }

    #[must_use]
    pub fn new(role: Role, kind: Kind, content: impl Into<String>) -> Self {
        Self {
            role,
            kind,
            content: content.into(),
        }
    }

    #[must_use]
    pub fn content(&self) -> &str {
        &self.content
    }

    /// Estimated tokens this message occupies, role label included.
    #[must_use]
    pub fn tokens(&self) -> usize {
        crate::tokens::estimate_tokens(&self.content) + ROLE_OVERHEAD_TOKENS
    }
}

/// What a role label and the blank line joining messages cost, charged per
/// message so a history of many short turns is not counted as free.
pub const ROLE_OVERHEAD_TOKENS: usize = 4;

/// Whether `earlier` is a strict prefix of `later`, message for message.
///
/// The invariant the whole design rests on, written as a function so tests can
/// state it directly rather than comparing lengths and hoping. A same-length
/// pair counts: nothing was rewritten.
#[must_use]
pub fn is_prefix_of(earlier: &[Message], later: &[Message]) -> bool {
    earlier.len() <= later.len() && earlier.iter().zip(later).all(|(a, b)| a == b)
}

/// The first position where two message lists disagree.
///
/// For test failure messages: "not a prefix" is useless on a twenty-message
/// conversation, and this says which one moved.
#[must_use]
pub fn first_divergence(earlier: &[Message], later: &[Message]) -> Option<usize> {
    earlier
        .iter()
        .zip(later)
        .position(|(a, b)| a != b)
        .or_else(|| (earlier.len() > later.len()).then_some(later.len()))
}

/// One flat string carrying the same conversation.
///
/// For runtimes that take a single prompt — the managed MLX worker speaks the
/// worker protocol, not `/api/chat`. Same content, same order, so the stable
/// prefix stays stable here too and a prefix-caching local runtime gets the
/// same benefit.
#[must_use]
pub fn flatten(messages: &[Message]) -> String {
    let mut out = String::new();
    for message in messages {
        if !out.is_empty() {
            out.push_str("\n\n");
        }
        match message.role {
            // The system message is handled separately by every caller; if one
            // arrives here it is still labelled rather than silently merged.
            Role::System => out.push_str("System:\n"),
            Role::User => out.push_str("User:\n"),
            Role::Assistant => out.push_str("Assistant:\n"),
        }
        out.push_str(&message.content);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_growing_conversation_keeps_its_prefix() {
        let turn_one = vec![Message::user("first"), Message::assistant("answer")];
        let mut turn_two = turn_one.clone();
        turn_two.push(Message::user("second"));

        assert!(is_prefix_of(&turn_one, &turn_two));
        assert_eq!(first_divergence(&turn_one, &turn_two), None);
        // And not the other way round: the longer list is not a prefix of the
        // shorter one.
        assert!(!is_prefix_of(&turn_two, &turn_one));
    }

    /// The failure this exists to catch: an earlier message rewritten rather
    /// than appended to.
    #[test]
    fn a_rewritten_message_breaks_the_prefix_and_says_where() {
        let before = vec![
            Message::user("first"),
            Message::assistant("answer"),
            Message::user("second"),
        ];
        let mut after = before.clone();
        after[1] = Message::assistant("answer, summarised");

        assert!(!is_prefix_of(&before, &after));
        assert_eq!(first_divergence(&before, &after), Some(1));
    }

    #[test]
    fn flattening_keeps_the_order_and_names_the_speaker() {
        let flat = flatten(&[Message::user("q"), Message::assistant("a")]);
        assert_eq!(flat, "User:\nq\n\nAssistant:\na");
    }
}
