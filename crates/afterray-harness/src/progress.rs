//! Reporting that a turn is alive while nothing is visible yet.
//!
//! There are three separate stretches where a chat window would otherwise sit
//! empty, and only the first is about thinking models:
//!
//! 1. **Reasoning.** A thinking model streams its scratch work on a separate
//!    field and leaves the answer empty until it is done. Measured on
//!    `qwen3.6:35b-mlx`: 131 reasoning deltas, then one content delta.
//! 2. **Before any output at all.** Loading a 22 GB model cold took 12.7 s
//!    before the first byte. Nothing is streaming; nothing is wrong.
//! 3. **While the round is a tool call.** [`crate::wire::AnswerGate`] hides
//!    `TOOL`/`ARGS` drafts so they never reach the user, and the `tool_call`
//!    event cannot be emitted until the round has finished and parsed. The
//!    whole generation of that draft is invisible.
//!
//! One heartbeat covers all three, which is why this is not a "thinking
//! indicator". Reporting only case 1 would have left the other two silent, and
//! the user cannot tell the three apart anyway — the question being asked is
//! "is this stuck?".

use std::time::Duration;

/// How often a turn says it is still alive, and how long it stays quiet first.
///
/// Fast enough that a stall is obvious within a beat, slow enough that a
/// reasoning burst does not turn into one event per delta: the 131 deltas above
/// arrived in about two seconds.
///
/// It is also the grace period. Nothing is reported until one interval has
/// passed, so a round that answers quickly never raises an indicator — showing
/// one for a few milliseconds is a flicker, not feedback.
pub const PROGRESS_INTERVAL: Duration = Duration::from_millis(400);

/// What a turn is doing while there is nothing to show.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// A round is running and has produced nothing yet.
    Generating,
    /// The model is streaming reasoning rather than an answer.
    Thinking,
}

impl Phase {
    /// Stable wire spelling.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Generating => "generating",
            Self::Thinking => "thinking",
        }
    }
}

/// One heartbeat.
///
/// Carries two independently moving numbers on purpose. `elapsed_ms` proves the
/// turn is alive when nothing at all is arriving; `reasoning_deltas` proves the
/// *model* is working rather than the connection merely being open. A client
/// that renders either as a changing number answers "is it stuck" without
/// needing an animation to be trusted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProgressReport {
    pub phase: Phase,
    pub reasoning_deltas: usize,
    pub elapsed_ms: u64,
    /// One-based round, so a client can tell a stale heartbeat from a current
    /// one after a tool call.
    pub round: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phases_have_stable_wire_names() {
        assert_eq!(Phase::Generating.as_str(), "generating");
        assert_eq!(Phase::Thinking.as_str(), "thinking");
    }

    /// Slow enough not to become one event per reasoning delta: the measured
    /// burst was ~131 deltas in ~2 s, so ~65/s against a 400 ms beat.
    #[test]
    fn the_interval_throttles_a_reasoning_burst() {
        // ~131 deltas over ~2 s, against beats of PROGRESS_INTERVAL.
        let deltas_per_10s: u128 = 131 * 5;
        let beats_per_10s = 10_000 / PROGRESS_INTERVAL.as_millis();
        assert!(beats_per_10s * 10 < deltas_per_10s);
    }
}
