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

    /// A budget for a real window, rather than the default's guess.
    ///
    /// The three derived numbers do not scale by the same rule, because they
    /// are not the same kind of thing:
    ///
    /// * **Reserve** is what an answer costs, which barely grows with the
    ///   window — an eighth of it, floored so a 4k window still gets a reply
    ///   out and capped so a 256k one does not hold back 32k for a paragraph.
    /// * **System** is a measurement, not a share: the prompt and the tool
    ///   catalog cost what they cost. Shrinking the figure on a small window
    ///   would not shrink the text, it would only make the budget wrong.
    /// * **Rounds** fall on a narrow window, because six rounds of a 4k window
    ///   means each tool result is cut to a few hundred tokens — below the size
    ///   of a single useful answer. Fewer, larger results beat more, emptier
    ///   ones.
    #[must_use]
    pub const fn for_window(window_tokens: usize) -> Self {
        let window_tokens = if window_tokens < MINIMUM_WINDOW_TOKENS {
            MINIMUM_WINDOW_TOKENS
        } else {
            window_tokens
        };
        let reserve_tokens = clamp(window_tokens / 8, 512, 4_096);
        let system_tokens = Self::DEFAULT.system_tokens;
        let transcript = window_tokens
            .saturating_sub(reserve_tokens)
            .saturating_sub(system_tokens);
        let max_rounds = if transcript >= 8_192 {
            6
        } else if transcript >= 2_048 {
            4
        } else {
            2
        };
        Self {
            window_tokens,
            reserve_tokens,
            system_tokens,
            max_rounds,
        }
    }

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

/// A window smaller than this cannot hold the system prompt, one tool result
/// and a question at once, so honouring it would only mean failing differently.
pub const MINIMUM_WINDOW_TOKENS: usize = 2_048;

/// `usize::clamp` is not `const`, and `for_window` needs to be.
const fn clamp(value: usize, low: usize, high: usize) -> usize {
    if value < low {
        low
    } else if value > high {
        high
    } else {
        value
    }
}

/// The property the three old constants violated, enforced where it cannot be
/// skipped: changing any default so a full turn no longer fits fails the build.
const _: () = assert!(ContextBudget::DEFAULT.is_coherent());
/// The default is not a special case: it is what the rule produces for the
/// window it was written for. If they ever diverge, one of them is wrong.
const _: () = assert!(matches!(
    ContextBudget::for_window(16_384),
    ContextBudget {
        window_tokens: 16_384,
        reserve_tokens: 2_048,
        system_tokens: 1_024,
        max_rounds: 6,
    }
));

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

    /// Every window a real provider can hand us must produce a budget that
    /// holds a full turn. The tiers are the ones the machine probe reports;
    /// the rest are windows an OpenAI-compatible endpoint might have.
    #[test]
    fn every_plausible_window_produces_a_coherent_budget() {
        for window in [
            0, 1, 512, 2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072, 262_144, 1_048_576,
        ] {
            let budget = ContextBudget::for_window(window);
            assert!(budget.is_coherent(), "{window} produced {budget:?}");
            let used = budget.system_tokens
                + budget.tool_result_tokens() * budget.max_rounds
                + budget.reserve_tokens;
            assert!(
                used <= budget.window_tokens,
                "{window}: {used} tokens over a {} window",
                budget.window_tokens
            );
        }
    }

    /// A 16 GB Mac gets 4 096 from Ollama, and that is not enough room to run
    /// six rounds of anything useful. It should buy fewer, bigger results.
    #[test]
    fn a_small_machine_trades_rounds_for_room() {
        let small = ContextBudget::for_window(4_096);
        let large = ContextBudget::for_window(262_144);
        assert!(small.max_rounds < large.max_rounds);
        assert!(
            small.tool_result_tokens() > ContextBudget::for_window(4_096).transcript_tokens() / 7,
            "fewer rounds should mean a larger share each"
        );
        // The reserve is an answer, not a proportion: it does not grow 64x.
        assert_eq!(large.reserve_tokens, 4_096);
        assert!(small.reserve_tokens >= 512);
    }

    /// Below this a window cannot hold its own overheads, so the budget stops
    /// pretending and plans against the floor instead.
    #[test]
    fn an_impossible_window_is_floored_rather_than_honoured() {
        let budget = ContextBudget::for_window(256);
        assert_eq!(budget.window_tokens, MINIMUM_WINDOW_TOKENS);
        assert!(budget.is_coherent());
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
