//! What one piece of a streaming completion is.
//!
//! Reasoning and answer text arrive on the same stream and must not be
//! confused. A thinking model spends most of a turn emitting reasoning — 131
//! reasoning deltas against a single content delta, measured on
//! `qwen3.6:35b-mlx` answering a two-character question — and folding that into
//! the answer would put the model's scratch work in the user's chat window and
//! into `parse_final`.
//!
//! Dropping it silently, which is what the parsers did before this existed, is
//! the other failure: the user then watches an empty window for the whole
//! thinking phase with nothing to say the turn is alive.
//!
//! So it is carried, and labelled.

/// Which stream a delta belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LlmDeltaKind {
    /// Part of the user-visible answer, and of the text the loop parses.
    Content,
    /// Part of the model's reasoning. Never assembled into the answer, and not
    /// shown by default — it is long, unedited, and rarely what was asked for.
    Reasoning,
}

/// One piece of a streaming completion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LlmDelta {
    pub kind: LlmDeltaKind,
    pub text: String,
}

impl LlmDelta {
    #[must_use]
    pub fn content(text: impl Into<String>) -> Self {
        Self {
            kind: LlmDeltaKind::Content,
            text: text.into(),
        }
    }

    #[must_use]
    pub fn reasoning(text: impl Into<String>) -> Self {
        Self {
            kind: LlmDeltaKind::Reasoning,
            text: text.into(),
        }
    }

    #[must_use]
    pub fn is_content(&self) -> bool {
        self.kind == LlmDeltaKind::Content
    }
}
