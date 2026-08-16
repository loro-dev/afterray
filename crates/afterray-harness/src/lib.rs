//! The agent harness: a tool-calling loop that knows nothing about `AfterRay`.
//!
//! Everything here is about running a model against a transcript within a
//! budget. It has no idea what a moment, a vault or a model queue is — bind it
//! to those in `afterray-agent`.
//!
//! The shape is borrowed from two places. The plugin surface is pi's
//! `AgentLoopConfig`: a handful of seams and nothing else, expressed here as
//! trait parameters so unused ones cost nothing. The compaction split is
//! deepseek-harness's: a tiny contract, with policy in a replaceable type.
//!
//! Where a decision could make the model quietly worse rather than visibly
//! broken — truncation seams, compaction boundaries, token estimates — the
//! reasoning is written down next to it.

pub mod budget;
pub mod history;
pub mod message;
pub mod cancel;
pub mod compaction;
pub mod fence;
pub mod opening;
pub mod progress;
pub mod tokens;
pub mod transcript;
pub mod truncate;
pub mod wire;

mod run;

pub use budget::ContextBudget;
pub use history::History;
pub use message::{Kind, Message, Role, first_divergence, flatten, is_prefix_of};
pub use cancel::CancelToken;
pub use compaction::{CompactionNotice, CompactionStrategy, PruneToolResults};
pub use opening::{Opening, OpeningTrim};
pub use progress::{Phase, ProgressReport};
pub use run::{
    DeltaKind, Discard, EventSink, GenerateRequest, HarnessEvent, LoopConfig, LoopError,
    ModelError, ModelSurface, RoundReasoning, StreamDelta, ToolCallRecord, ToolSurface, Turn,
    TurnUsage, run_turn,
};
pub use transcript::{Pruned, Transcript};
pub use truncate::{Budgeted, truncate_head, truncate_tail};
