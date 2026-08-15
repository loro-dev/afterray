//! The transcript's first block, budgeted a part at a time.
//!
//! This used to be one opaque `String` that the loop trimmed with
//! [`truncate_head`]. The string is built seed, then history, then the question
//! the user just asked — so keeping the head kept the clock and a stale
//! conversation and **deleted the question**. On a Chinese thread it took very
//! little to trigger: the folded history alone can be eight thousand tokens
//! against an opening allowance under two thousand. The model then answered,
//! carefully, something nobody had asked.
//!
//! Splitting it is the fix. Each part has its own budget and its own direction
//! to trim in, and the one part that must never disappear cannot, because
//! nothing here is allowed to drop it.

use crate::budget::ContextBudget;
use crate::tokens::estimate_tokens;
use crate::truncate::{truncate_head, truncate_tail};

/// Share of the opening reserved for the clock and seed.
///
/// Small: it is a handful of epoch anchors and a sketch of the day. It has a
/// floor rather than a share of what is left so that a long history cannot
/// squeeze out the numbers every tool argument is copied from.
const SEED_SHARE: usize = 4;

/// Share reserved for the current question when everything cannot fit.
///
/// The question is the only part with no fallback: history can be summarised
/// later and the seed can be re-derived, but a turn that loses the question has
/// nothing to answer.
const TASK_SHARE: usize = 3;

/// What the model is told before the first round.
#[derive(Debug, Clone, Default)]
pub struct Opening {
    /// Clock, epoch anchors, and any cheap sketch of the day.
    pub seed: String,
    /// Prior conversation, oldest first. Trimmed from the front.
    pub history: String,
    /// What the user just asked. Never dropped.
    pub task: String,
}

/// What budgeting an opening had to remove.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpeningTrim {
    pub seed_dropped: usize,
    pub history_dropped: usize,
    /// Non-zero only when the question alone exceeds its budget, which is a
    /// different and much louder situation than a long history.
    pub task_dropped: usize,
}

impl OpeningTrim {
    #[must_use]
    pub fn happened(self) -> bool {
        self.seed_dropped > 0 || self.history_dropped > 0 || self.task_dropped > 0
    }

    /// A sentence naming what actually went, for the thread.
    ///
    /// Distinct wording per cause, because "dropped earlier tool results" —
    /// which is what this used to be labelled — is wrong and misleading when
    /// what went was half the conversation.
    #[must_use]
    pub fn describe(self) -> String {
        let mut parts = Vec::new();
        if self.history_dropped > 0 {
            parts.push(format!(
                "~{} tokens of earlier conversation",
                self.history_dropped
            ));
        }
        if self.seed_dropped > 0 {
            parts.push(format!("~{} tokens of the clock sketch", self.seed_dropped));
        }
        if self.task_dropped > 0 {
            parts.push(format!(
                "~{} tokens of your question, which was longer than one turn can hold",
                self.task_dropped
            ));
        }
        format!(
            "Trimmed {} to fit the context window.",
            parts.join(" and ")
        )
    }
}

impl Opening {
    /// Renders the opening, trimming each part within its own budget.
    ///
    /// The order of preference when it does not all fit: the question survives
    /// whole, the seed keeps its anchors, and history gives up its oldest turns
    /// first. History is trimmed from the front because a folded conversation
    /// runs oldest to newest and the recent end is what a follow-up refers to.
    /// `fence` wraps each part after it has been trimmed.
    ///
    /// After, not before: trimming a block that is already fenced can remove
    /// the opening or closing marker, leaving the question looking like part of
    /// the data — or leaving a stray closer that captured text could exploit.
    /// Fencing last means a fence is always well formed by construction.
    #[must_use]
    pub fn render(
        &self,
        budget: ContextBudget,
        fence: fn(&str, &str) -> String,
    ) -> (String, OpeningTrim) {
        let allowance = budget.opening_allowance();
        let mut trim = OpeningTrim::default();

        // The question first, and it is only ever cut against its own share —
        // never against what history left behind.
        let task_budget = allowance.saturating_sub(allowance / TASK_SHARE).max(1);
        let task = if estimate_tokens(&self.task) > task_budget {
            let cut = truncate_head(&self.task, task_budget);
            trim.task_dropped = cut.dropped_tokens;
            cut.text
        } else {
            self.task.clone()
        };

        let spent = estimate_tokens(&task);
        let left = allowance.saturating_sub(spent);
        let seed_budget = (allowance / SEED_SHARE).min(left);
        let seed = if estimate_tokens(&self.seed) > seed_budget {
            let cut = truncate_head(&self.seed, seed_budget);
            trim.seed_dropped = cut.dropped_tokens;
            cut.text
        } else {
            self.seed.clone()
        };

        let history_budget = left.saturating_sub(estimate_tokens(&seed));
        let history = if estimate_tokens(&self.history) > history_budget {
            let cut = truncate_tail(&self.history, history_budget);
            trim.history_dropped = cut.dropped_tokens;
            cut.text
        } else {
            self.history.clone()
        };

        let mut out = String::new();
        if !seed.trim().is_empty() {
            out.push_str("Clock and what the vault holds:\n");
            out.push_str(&fence("seed", &seed));
        }
        if !history.trim().is_empty() {
            out.push_str("\n\nEarlier in this conversation:\n");
            out.push_str(&fence("history", &history));
        }
        out.push_str("\n\nUser task:\n");
        out.push_str(&fence("user", task.trim()));
        out.push('\n');
        (out, trim)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn budget() -> ContextBudget {
        ContextBudget::DEFAULT
    }

    fn fence(kind: &str, body: &str) -> String {
        crate::fence::untrusted(kind, body)
    }

    /// The bug this module exists for. A long history must cost history, never
    /// the question.
    #[test]
    fn a_long_history_never_costs_the_question() {
        let opening = Opening {
            seed: "now_ms: 1786729937000".to_owned(),
            history: (0..4_000)
                .map(|index| format!("user: 这是第 {index} 轮的旧对话"))
                .collect::<Vec<_>>()
                .join("\n"),
            task: "我昨天下午在读什么".to_owned(),
        };
        let (rendered, trim) = opening.render(budget(), fence);

        assert!(
            rendered.contains("我昨天下午在读什么"),
            "the question was trimmed away"
        );
        assert!(rendered.contains("now_ms: 1786729937000"), "the clock went");
        assert!(trim.history_dropped > 0);
        assert_eq!(trim.task_dropped, 0);
        assert!(estimate_tokens(&rendered) <= budget().opening_allowance());
    }

    /// History is trimmed from the front: a follow-up refers to the recent end.
    #[test]
    fn history_gives_up_its_oldest_turns_first() {
        let opening = Opening {
            seed: "clock".to_owned(),
            history: (0..3_000)
                .map(|index| format!("user: turn {index}"))
                .collect::<Vec<_>>()
                .join("\n"),
            task: "and then?".to_owned(),
        };
        let (rendered, _) = opening.render(budget(), fence);
        assert!(rendered.contains("turn 2999"), "the newest turn went");
        assert!(!rendered.contains("turn 0\n"), "the oldest turn survived");
    }

    /// A question longer than one turn can hold is cut, but the cut is its own
    /// distinct fact rather than being blamed on tool results.
    #[test]
    fn an_enormous_question_is_cut_and_named() {
        let opening = Opening {
            seed: "clock".to_owned(),
            history: String::new(),
            task: "please summarise this pasted log. ".repeat(20_000),
        };
        let (rendered, trim) = opening.render(budget(), fence);
        assert!(trim.task_dropped > 0);
        assert!(trim.describe().contains("your question"), "{}", trim.describe());
        assert!(estimate_tokens(&rendered) <= budget().opening_allowance());
    }

    /// Nothing is touched when it all fits.
    #[test]
    fn a_small_opening_is_left_alone() {
        let opening = Opening {
            seed: "clock".to_owned(),
            history: "user: hi\nassistant: hello".to_owned(),
            task: "what did I do".to_owned(),
        };
        let (rendered, trim) = opening.render(budget(), fence);
        assert!(!trim.happened());
        assert!(rendered.contains("user: hi"));
        assert!(rendered.contains("what did I do"));
        assert!(rendered.contains("<<<AFTERRAY_DATA kind=user>>>"));
    }

    /// Every part is fenced, and a trim can never leave a fence half open.
    #[test]
    fn trimming_never_breaks_a_fence() {
        let opening = Opening {
            seed: "clock ".repeat(4_000),
            history: "old turn. ".repeat(20_000),
            task: "what did I do".to_owned(),
        };
        let (rendered, trim) = opening.render(budget(), fence);
        assert!(trim.happened());
        assert_eq!(
            rendered.matches("<<<AFTERRAY_DATA").count(),
            rendered.matches("<<<END_AFTERRAY_DATA>>>").count(),
            "a fence was left unbalanced by trimming"
        );
        assert!(rendered.contains("what did I do"));
    }

    /// The wording has to name what went. "Dropped earlier tool results" —
    /// which is what the single-notice version said — is simply false when the
    /// casualty was the conversation.
    #[test]
    fn the_description_names_the_right_casualty() {
        let trim = OpeningTrim {
            history_dropped: 900,
            ..OpeningTrim::default()
        };
        let text = trim.describe();
        assert!(text.contains("earlier conversation"), "{text}");
        assert!(!text.contains("tool result"), "{text}");
    }
}
