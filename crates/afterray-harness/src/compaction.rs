//! Keeping the transcript inside the window, replaceably.
//!
//! The split is deepseek-harness's: the contract here is a handful of lines,
//! and the policy lives in an ordinary type next to it. Swapping
//! [`PruneToolResults`] for something model-backed is a different value in
//! `LoopConfig::compaction`, not a change to the loop.
//!
//! Two rules every strategy must keep, because getting them wrong makes the
//! model quietly worse rather than visibly broken:
//!
//! 1. **Non-destructive.** What goes is announced through a
//!    [`CompactionNotice`], and the tool call that produced a dropped body
//!    stays in the transcript. A result that vanishes without a word reads to
//!    the model as "that call returned nothing", and it answers accordingly.
//! 2. **Boundaries, not offsets.** Compaction removes whole results. A cut
//!    inside one hands the model a fragment it has no way to recognise as one.

use crate::budget::ContextBudget;
use crate::history::History;
use crate::transcript::Transcript;

/// One compaction pass, for the log and for the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactionNotice {
    /// Which policy acted. Stable enough to show a user.
    pub strategy: &'static str,
    /// Inclusive round range the pass covered, zero-based.
    pub from_round: usize,
    pub to_round: usize,
    pub tokens_before: usize,
    pub tokens_after: usize,
}

impl CompactionNotice {
    #[must_use]
    pub fn tokens_freed(&self) -> usize {
        self.tokens_before.saturating_sub(self.tokens_after)
    }
}

/// A policy for bringing a transcript back inside its budget.
pub trait CompactionStrategy: Send + Sync {
    /// Compacts `transcript` until it fits, or until nothing more can go.
    ///
    /// Returns one notice per pass — empty when the transcript already fitted.
    /// Not being able to fit is not an error: the round cap bounds how far over
    /// it can get, and an over-budget prompt the runtime trims is still better
    /// than a turn that refuses to run.
    fn compact(
        &self,
        transcript: &mut Transcript,
        budget: ContextBudget,
    ) -> Vec<CompactionNotice>;

    /// The same job on the conversation *before* this turn started.
    ///
    /// One policy for both, deliberately. Running out of room inside a turn and
    /// running out of room across turns are the same problem, and until this
    /// existed they were handled differently: the in-turn path announced what
    /// it dropped and showed it in the UI, while the cross-turn path silently
    /// deleted the middle of the conversation.
    ///
    /// `limit` is what the history may occupy, in estimated tokens. The
    /// operations [`History`] offers are the only ones available — fold a
    /// result, drop from the front, leave a marker — so no implementation of
    /// this trait can rewrite a message the model has already been shown.
    fn compact_history(&self, history: &mut History, limit: usize) -> Vec<CompactionNotice>;
}

/// Drops the oldest tool-result bodies until the transcript fits.
///
/// The cheap strategy, and the right default: it needs no extra model call, so
/// it cannot itself fail, stall a turn, or cost a second round-trip on the very
/// turn that is already under pressure.
///
/// Oldest first because the newest result is the one the model is reasoning
/// about right now.
#[derive(Debug, Default, Clone, Copy)]
pub struct PruneToolResults;

impl PruneToolResults {
    pub const NAME: &'static str = "prune_tool_results";
    /// The cross-turn pass. A separate name because what a user loses is
    /// different — whole exchanges rather than evidence bodies — and a line
    /// that says "dropped earlier tool results" when half the conversation
    /// went is worse than no line at all.
    pub const HISTORY_NAME: &'static str = "drop_earlier_turns";
}

impl CompactionStrategy for PruneToolResults {
    fn compact(
        &self,
        transcript: &mut Transcript,
        budget: ContextBudget,
    ) -> Vec<CompactionNotice> {
        let limit = budget.transcript_tokens();
        let tokens_before = transcript.tokens();
        if tokens_before <= limit {
            return Vec::new();
        }

        let mut first = None;
        let mut last = 0;
        while transcript.tokens() > limit {
            let Some(index) = transcript.oldest_intact() else {
                break;
            };
            if transcript.prune_round(index).is_none() {
                break;
            }
            first.get_or_insert(index);
            last = index;
        }

        let Some(from_round) = first else {
            return Vec::new();
        };
        vec![CompactionNotice {
            strategy: Self::NAME,
            from_round,
            to_round: last,
            tokens_before,
            tokens_after: transcript.tokens(),
        }]
    }

    fn compact_history(&self, history: &mut History, limit: usize) -> Vec<CompactionNotice> {
        let tokens_before = history.tokens();
        if tokens_before <= limit {
            return Vec::new();
        }

        // Tool results first, oldest first, in the same shape as the in-turn
        // pass: the body goes, the call stays, and the replacement says so.
        // They are the largest thing a conversation holds, the most stale, and
        // the only part that can be fetched again on demand — where a question
        // or an answer, once gone, is gone.
        let mut folded = 0;
        let mut total = tokens_before;
        while total > limit {
            let Some(index) = history.oldest_intact_result() else {
                break;
            };
            let Some(freed) = history.fold_result(index) else {
                break;
            };
            total = total.saturating_sub(freed);
            folded += 1;
        }

        // Still over: whole messages from the oldest end, which is the point at
        // which a conversation really does start losing turns. It may go all
        // the way to nothing — the question being asked right now is not in
        // here, so there is no case where this loses what the turn is about.
        let mut dropped = 0;
        while history.tokens() > limit && !history.is_empty() {
            history.drop_oldest();
            dropped += 1;
        }
        if dropped > 0 {
            history.mark(format!(
                "{dropped} earlier message(s) in this conversation were dropped to fit the \
                 context window. They are still in the thread; ask about them again if needed."
            ));
        }
        if folded == 0 && dropped == 0 {
            return Vec::new();
        }
        vec![CompactionNotice {
            strategy: Self::HISTORY_NAME,
            // Rounds are an in-turn idea; a cross-turn pass covers the whole
            // opening, and what actually went is named in the marker.
            from_round: 0,
            to_round: 0,
            tokens_before,
            tokens_after: history.tokens(),
        }]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fence;
    use crate::truncate::Budgeted;
    use serde_json::json;

    fn loaded(results: usize, body_chars: usize) -> Transcript {
        let mut transcript = Transcript::new("User task:\nwhat did I do\n".to_owned(), fence::untrusted);
        for index in 0..results {
            transcript.push(
                "get_slot_card".to_owned(),
                json!({ "at_ms": index }),
                Budgeted::verbatim(format!("{{\"slot\":{index},\"t\":\"{}\"}}", "x".repeat(body_chars))),
            );
        }
        transcript
    }

    #[test]
    fn a_transcript_that_fits_is_left_alone() {
        let mut transcript = loaded(2, 40);
        let before = transcript.render();
        assert!(PruneToolResults.compact(&mut transcript, ContextBudget::DEFAULT).is_empty());
        assert_eq!(transcript.render(), before);
    }

    #[test]
    fn prunes_oldest_first_until_it_fits() {
        let mut transcript = loaded(6, 20_000);
        let notices = PruneToolResults.compact(&mut transcript, ContextBudget::DEFAULT);

        let notice = notices.first().expect("something should have been pruned");
        assert_eq!(notice.strategy, PruneToolResults::NAME);
        assert_eq!(notice.from_round, 0);
        assert!(notice.tokens_freed() > 0);
        assert!(transcript.tokens() <= ContextBudget::DEFAULT.transcript_tokens());
        assert!(transcript.rounds().next().unwrap().pruned);
        assert!(
            !transcript.rounds().last().unwrap().pruned,
            "the newest result is what the model is reasoning about"
        );
    }

    /// Non-destructive: the call survives, so the model does not repeat a
    /// lookup it has already paid for, and the drop is stated in the prompt.
    #[test]
    fn a_pruned_round_keeps_its_call_and_says_so() {
        let mut transcript = loaded(6, 20_000);
        PruneToolResults.compact(&mut transcript, ContextBudget::DEFAULT);
        let rendered = transcript.render();
        assert!(rendered.contains(r#"ARGS {"at_ms":0}"#));
        assert!(rendered.contains("dropped to make room"));
        assert!(rendered.contains("Call it again if you still need it"));
    }

    /// One notice per pass, covering the range, so the UI draws one separator
    /// rather than one per round.
    #[test]
    fn one_notice_covers_the_whole_pass() {
        let mut transcript = loaded(8, 20_000);
        let notices = PruneToolResults.compact(&mut transcript, ContextBudget::DEFAULT);
        assert_eq!(notices.len(), 1);
        let notice = &notices[0];
        assert!(notice.to_round > notice.from_round, "{notice:?}");
        assert!(notice.tokens_after < notice.tokens_before);
    }

    /// Nothing left to drop is a fact to report, not a panic or a hang.
    #[test]
    fn a_transcript_it_cannot_fit_terminates() {
        let mut transcript = Transcript::new("x".repeat(400_000), fence::untrusted);
        transcript.push(
            "get_ocr".to_owned(),
            json!({}),
            Budgeted::verbatim("small".to_owned()),
        );
        let notices = PruneToolResults.compact(&mut transcript, ContextBudget::DEFAULT);
        assert_eq!(notices.len(), 1);
        assert!(transcript.tokens() > ContextBudget::DEFAULT.transcript_tokens());
    }
}

#[cfg(test)]
mod history_tests {
    use super::*;
    use crate::history::DROPPED_RESULT;
    use crate::message::{Message, is_prefix_of};

    fn conversation(turns: usize) -> History {
        History::from_stored(
            (0..turns)
                .flat_map(|index| {
                    [
                        Message::user(format!("question {index} {}", "x".repeat(200))),
                        Message::assistant(format!("answer {index} {}", "y".repeat(200))),
                    ]
                })
                .collect(),
        )
    }

    /// Order of loss: results before words. A tool result can be looked up
    /// again; a question cannot, and an answer the user has already read
    /// disappearing from the thread's context is how a follow-up stops making
    /// sense.
    #[test]
    fn tool_results_are_folded_before_anything_a_person_said() {
        let mut history = History::from_stored(vec![
            Message::user("what was I reading"),
            Message::tool_call("TOOL get_ocr\nARGS {}"),
            Message::tool_result("x".repeat(4_000)),
            Message::assistant("the AV1 spec"),
            Message::user("and before that"),
            Message::tool_call("TOOL list_activity\nARGS {}"),
            Message::tool_result("y".repeat(4_000)),
            Message::assistant("Mail"),
        ]);
        let notices = PruneToolResults.compact_history(&mut history, 200);

        assert_eq!(notices.len(), 1);
        // Every word a person said is still there, in order.
        assert_eq!(history.len(), 8, "a message was dropped: {history:?}");
        assert_eq!(history.messages()[0].content(), "what was I reading");
        assert_eq!(history.messages()[3].content(), "the AV1 spec");
        assert_eq!(history.messages()[4].content(), "and before that");
        assert_eq!(history.messages()[7].content(), "Mail");
        // And both results went, oldest first.
        assert_eq!(history.messages()[2].content(), DROPPED_RESULT);
        assert_eq!(history.messages()[6].content(), DROPPED_RESULT);
        // The calls survive their results: that is what stops the model simply
        // running them again.
        assert!(history.messages()[1].content().starts_with("TOOL get_ocr"));
    }

    /// Only as many as it takes. A conversation two hundred tokens over budget
    /// should not lose every result it has.
    #[test]
    fn folding_stops_as_soon_as_it_fits() {
        let mut history = History::from_stored(vec![
            Message::tool_result("x".repeat(4_000)),
            Message::tool_result("y".repeat(40)),
            Message::assistant("done"),
        ]);
        PruneToolResults.compact_history(&mut history, 60);
        assert_eq!(history.messages()[0].content(), DROPPED_RESULT);
        assert_eq!(history.messages()[1].content(), "y".repeat(40), "folded more than it had to");
    }

    /// The cross-turn pass keeps the same contract as the in-turn one: whole
    /// messages, and a line saying what went.
    #[test]
    fn dropping_the_oldest_messages_is_announced_and_marked() {
        let mut history = conversation(20);
        let notices = PruneToolResults.compact_history(&mut history, 500);

        assert_eq!(notices.len(), 1);
        assert_eq!(notices[0].strategy, PruneToolResults::HISTORY_NAME);
        assert!(notices[0].tokens_after < notices[0].tokens_before);
        assert!(
            history.messages()[0].content().starts_with("[AfterRay]"),
            "no marker where the conversation was cut: {:?}",
            history.messages()[0]
        );
        // The newest exchange survives: it is what a follow-up refers to.
        assert!(history.messages().last().unwrap().content().contains("answer 19"));
    }

    /// A compaction moves the prefix once — that is the price — and then the
    /// prefix is stable again for every turn after it.
    #[test]
    fn the_prefix_settles_again_after_a_compaction() {
        let mut history = conversation(20);
        PruneToolResults.compact_history(&mut history, 500);
        let after_first = history.clone();

        // Two more turns arrive, and each is compacted the same way.
        for index in 20..22 {
            history.push(Message::user(format!("question {index}")));
            history.push(Message::assistant(format!("answer {index}")));
            let before = history.clone();
            PruneToolResults.compact_history(&mut history, 5_000);
            assert!(
                is_prefix_of(before.messages(), history.messages()),
                "a pass that did not need to drop anything still rewrote the history"
            );
        }
        assert!(
            is_prefix_of(after_first.messages(), history.messages()),
            "the settled prefix moved again without pressure"
        );
    }

    #[test]
    fn a_conversation_that_fits_is_left_exactly_as_it_was() {
        let mut history = conversation(2);
        let before = history.clone();
        assert!(PruneToolResults.compact_history(&mut history, 100_000).is_empty());
        assert_eq!(history, before);
    }
}
