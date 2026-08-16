//! The conversation so far, in a shape that cannot be rewritten by accident.
//!
//! The append-only prefix is the whole design: every provider caches on the
//! longest identical prefix, and a local runtime re-prefills from the first
//! byte that changed. A `Vec<Message>` cannot hold that property. Anything with
//! `&mut` can edit any element, and the mistake is invisible — no error, no
//! event, just a prompt that quietly stops matching anything cached and a bill
//! that goes up.
//!
//! So the vector is private and the only operations are the legal ones:
//!
//! * [`History::push`] — add at the end. This is what a finished turn does.
//! * [`History::fold_result`] — replace one tool result's body with the standard
//!   marker. The call above it stays, so the model still knows it ran.
//! * [`History::drop_oldest`] — remove from the front.
//! * [`History::mark`] — put an `[AfterRay]` line where dropped messages were.
//!
//! The last three exist for compaction and are the *only* way anything can
//! leave. There is deliberately no `messages_mut`, no `IndexMut`, no setter on
//! [`Message::content`]: a policy — including one written later, by someone
//! else — can fold and drop, and cannot forge.

use crate::message::{Kind, Message};

/// What replaces a folded result.
///
/// The same sentence the in-turn transcript uses, so the model reads one story
/// about missing evidence rather than two.
pub const DROPPED_RESULT: &str =
    "Tool result: dropped to make room. Call it again if you still need it.";

/// Prior turns, oldest first.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct History {
    messages: Vec<Message>,
}

impl History {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Adopts messages that were rendered from durable storage.
    ///
    /// The caller promises they are a deterministic function of what is stored
    /// — the same rows must always produce the same messages, or the prefix
    /// moves for a reason no compaction notice can explain. Nothing here can
    /// check that; it is the one obligation this type cannot enforce, which is
    /// why it is written down.
    #[must_use]
    pub fn from_stored(messages: Vec<Message>) -> Self {
        Self { messages }
    }

    /// Adds a message at the end. The only way to grow.
    pub fn push(&mut self, message: Message) {
        self.messages.push(message);
    }

    #[must_use]
    pub fn messages(&self) -> &[Message] {
        &self.messages
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.messages.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.messages.is_empty()
    }

    /// Estimated tokens the whole conversation occupies.
    #[must_use]
    pub fn tokens(&self) -> usize {
        self.messages.iter().map(Message::tokens).sum()
    }

    /// Position of the oldest tool result that still has its body.
    #[must_use]
    pub fn oldest_intact_result(&self) -> Option<usize> {
        self.messages.iter().position(|message| {
            message.kind == Kind::ToolResult && message.content() != DROPPED_RESULT
        })
    }

    /// Replaces one tool result's body with the marker.
    ///
    /// Returns the tokens that freed, or `None` if the index is not an intact
    /// result. The call that produced it is untouched by design: a model that
    /// cannot see it already ran `list_activity` simply runs it again.
    pub fn fold_result(&mut self, index: usize) -> Option<usize> {
        let message = self.messages.get(index)?;
        if message.kind != Kind::ToolResult || message.content() == DROPPED_RESULT {
            return None;
        }
        let before = message.tokens();
        self.messages[index] = Message::tool_result(DROPPED_RESULT);
        Some(before.saturating_sub(self.messages[index].tokens()))
    }

    /// Removes the oldest message, returning it.
    pub fn drop_oldest(&mut self) -> Option<Message> {
        if self.messages.is_empty() {
            return None;
        }
        Some(self.messages.remove(0))
    }

    /// Puts a notice at the front, where the dropped messages were.
    ///
    /// A gap with nothing in it reads to the model as a conversation that
    /// started mid-sentence — and to the user as an assistant that forgot.
    pub fn mark(&mut self, text: impl Into<String>) {
        self.messages
            .insert(0, Message::control(format!("[AfterRay] {}", text.into())));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conversation() -> History {
        History::from_stored(vec![
            Message::user("what was I reading"),
            Message::tool_call("TOOL get_ocr\nARGS {}"),
            Message::tool_result("x".repeat(400)),
            Message::assistant("the AV1 spec"),
        ])
    }

    #[test]
    fn folding_replaces_only_the_result_and_frees_room() {
        let mut history = conversation();
        let before = history.tokens();
        let freed = history.fold_result(2).expect("index 2 is an intact result");

        assert!(freed > 0);
        assert_eq!(history.tokens(), before - freed);
        assert_eq!(history.messages()[2].content(), DROPPED_RESULT);
        // Everything else is exactly as it was.
        assert_eq!(history.messages()[0].content(), "what was I reading");
        assert_eq!(history.messages()[1].content(), "TOOL get_ocr\nARGS {}");
        assert_eq!(history.messages()[3].content(), "the AV1 spec");
    }

    /// Folding is not something that can be done twice, and not something that
    /// can be pointed at a question.
    #[test]
    fn nothing_but_an_intact_result_can_be_folded() {
        let mut history = conversation();
        assert!(history.fold_result(0).is_none(), "a question is not foldable");
        assert!(history.fold_result(1).is_none(), "a call is not foldable");
        assert!(history.fold_result(3).is_none(), "an answer is not foldable");
        assert!(history.fold_result(99).is_none(), "no such message");

        assert!(history.fold_result(2).is_some());
        assert!(
            history.fold_result(2).is_none(),
            "a folded result folds again, so a policy could loop forever"
        );
    }

    #[test]
    fn the_oldest_intact_result_is_the_next_one_to_go() {
        let mut history = History::from_stored(vec![
            Message::tool_result("first"),
            Message::user("q"),
            Message::tool_result("second"),
        ]);
        assert_eq!(history.oldest_intact_result(), Some(0));
        history.fold_result(0);
        assert_eq!(history.oldest_intact_result(), Some(2));
        history.fold_result(2);
        assert_eq!(history.oldest_intact_result(), None);
    }

    #[test]
    fn dropping_takes_from_the_front_and_marking_says_so() {
        let mut history = conversation();
        let dropped = history.drop_oldest().expect("not empty");
        assert_eq!(dropped.content(), "what was I reading");

        history.mark("1 earlier message was dropped");
        assert_eq!(history.messages()[0].kind, Kind::Control);
        assert!(history.messages()[0].content().starts_with("[AfterRay] 1 earlier"));
    }
}

/// The compile-fail cases, kept as documentation because the type system is
/// the enforcement and a reader should be able to see what it rules out.
///
/// ```compile_fail
/// # use afterray_harness::{History, Message};
/// let mut history = History::from_stored(vec![Message::user("q")]);
/// // No way to reach inside and rewrite what the model was already shown.
/// history.messages()[0].content = "something else".to_owned();
/// ```
///
/// ```compile_fail
/// # use afterray_harness::{History, Message};
/// let mut history = History::from_stored(vec![Message::user("q")]);
/// // And no way to swap one out, either.
/// history.messages_mut()[0] = Message::user("something else");
/// ```
#[cfg(doctest)]
struct CannotRewriteHistory;
