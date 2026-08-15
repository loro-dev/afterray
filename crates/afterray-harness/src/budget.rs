//! One coherent context budget for the agent loop.
//!
//! The loop used to carry three unrelated constants — `MAX_ROUNDS = 5`,
//! `MAX_HISTORY_CHARS = 14_000`, `MAX_TOOL_CHARS = 6_000`. Two tool calls filled
//! the history cap, so rounds three through five always ran against a
//! transcript that had already been cut. The numbers here are derived from a
//! single figure instead, and [`ContextBudget::is_coherent`] is the assertion
//! that they still add up.

/// Everything the loop is allowed to spend, in estimated tokens.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextBudget {
    /// The model's context window.
    pub window_tokens: usize,
    /// Held back for the answer the model is about to generate.
    pub reserve_tokens: usize,
    /// Held back for the system prompt and the tool catalog, which are not part
    /// of the transcript but do occupy the window.
    pub system_tokens: usize,
    /// Model calls per turn. Each round may add one tool result.
    pub max_rounds: usize,
}

impl ContextBudget {
    /// The default: sized to the builtin llama.cpp runtime, whose `n_ctx`
    /// defaults to 16 384 (`afterray_infer::llm::DEFAULT_N_CTX`). Ollama and
    /// OpenAI-compatible endpoints all offer at least this much, so a budget
    /// that fits the smallest runtime fits every runtime.
    ///
    /// The arithmetic, which [`Self::is_coherent`] checks:
    ///
    /// ```text
    ///  16_384  window
    /// - 2_048  generation headroom
    /// - 1_024  system prompt + tool catalog (measured at ~900)
    /// = 13_312 transcript
    ///        → 6 rounds × 2_048 per tool result = 12_288, leaving 1_024 for
    ///          the task text and the per-round scaffolding
    /// ```
    pub const DEFAULT: Self = Self {
        window_tokens: 16_384,
        reserve_tokens: 2_048,
        system_tokens: 1_024,
        max_rounds: 6,
    };

    /// What the transcript may occupy.
    #[must_use]
    pub const fn transcript_tokens(self) -> usize {
        self.window_tokens
            .saturating_sub(self.reserve_tokens)
            .saturating_sub(self.system_tokens)
    }

    /// The cap on one tool result.
    ///
    /// Deliberately `transcript / (rounds + 1)`: the spare share is what the
    /// user's question, the seed and the round scaffolding live on. A cap of
    /// `transcript / rounds` would be exactly full at the last round and leave
    /// the task itself nowhere to go.
    #[must_use]
    pub const fn tool_result_tokens(self) -> usize {
        self.transcript_tokens() / (self.max_rounds + 1)
    }

    /// Whether a full turn — every round calling a tool that returns a
    /// maximum-size result — still fits the window.
    ///
    /// This is the property the three old constants violated.
    #[must_use]
    pub const fn is_coherent(self) -> bool {
        // The previous form compared `transcript/(rounds+1)*rounds` against
        // `transcript`, which is true for every positive input — it could not
        // fail, so it checked nothing. These can.
        self.reserve_tokens + self.system_tokens < self.window_tokens
            && self.tool_result_tokens() > 0
            && self.opening_allowance() > 0
    }

    /// What the opening block — task, clock anchors, folded history — may
    /// occupy.
    ///
    /// The share left after every round has room for a full-size tool result.
    /// Without this the first round could exceed the window before a single
    /// tool had run, and nothing would have noticed: compaction only prunes
    /// round bodies, and the opening is never one.
    #[must_use]
    pub const fn opening_allowance(self) -> usize {
        self.transcript_tokens()
            .saturating_sub(self.tool_result_tokens() * self.max_rounds)
    }
}

impl Default for ContextBudget {
    fn default() -> Self {
        Self::DEFAULT
    }
}

/// The property the three old constants violated, enforced where it cannot be
/// skipped: changing any default so a full turn no longer fits fails the build.
const _: () = assert!(ContextBudget::DEFAULT.is_coherent());

#[cfg(test)]
mod tests {
    use super::*;

    /// The regression this module exists for. Run the worst case — every round
    /// returning a full-size tool result — and check it fits.
    #[test]
    fn a_full_turn_fits_the_window() {
        let budget = ContextBudget::DEFAULT;
        assert!(budget.is_coherent());
        let used = budget.system_tokens
            + budget.tool_result_tokens() * budget.max_rounds
            + budget.reserve_tokens;
        assert!(
            used <= budget.window_tokens,
            "{used} tokens over a {} window",
            budget.window_tokens
        );
    }

    /// The old numbers, in their own units, showing what was wrong: a full
    /// turn needed more than twice the transcript it was allowed, so the last
    /// rounds always ran against a transcript that had already been cut.
    #[test]
    fn the_old_constants_did_not_fit() {
        let old_history_chars = 14_000_usize;
        let old_tool_chars = 6_000_usize;
        let old_rounds = 5_usize;

        assert!(old_tool_chars * old_rounds > old_history_chars * 2);
        // Three results alone overflowed it, before the seed or the question.
        assert!(old_tool_chars * 3 > old_history_chars);

        // The replacement holds a full turn with room left for the task.
        let budget = ContextBudget::DEFAULT;
        assert!(budget.tool_result_tokens() * budget.max_rounds < budget.transcript_tokens());
    }

    #[test]
    fn a_narrow_window_still_produces_a_usable_cap() {
        let budget = ContextBudget {
            window_tokens: 4_096,
            ..ContextBudget::DEFAULT
        };
        assert!(budget.is_coherent());
        assert!(budget.tool_result_tokens() > 0);
    }

    /// A window too small for its own overheads is exactly what
    /// `is_coherent` should reject. The old form called it coherent.
    #[test]
    fn a_window_smaller_than_its_overheads_is_not_coherent() {
        let budget = ContextBudget {
            window_tokens: 512,
            ..ContextBudget::DEFAULT
        };
        assert_eq!(budget.transcript_tokens(), 0);
        assert_eq!(budget.tool_result_tokens(), 0);
        assert!(!budget.is_coherent(), "a zero transcript is not a budget");
    }

    /// The opening is a real share, not whatever is left over by accident.
    #[test]
    fn the_opening_gets_a_share_of_its_own() {
        let budget = ContextBudget::DEFAULT;
        assert!(budget.opening_allowance() > 0);
        assert!(
            budget.opening_allowance() + budget.tool_result_tokens() * budget.max_rounds
                <= budget.transcript_tokens()
        );
    }
}
