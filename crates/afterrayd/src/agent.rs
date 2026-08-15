//! `AfterRay`'s binding to the agent harness.
//!
//! The loop, the budgets, the transcript and the wire format live in
//! `afterray-harness`; the model-queue binding lives in `afterray-agent`. What
//! is left here is what is specific to this daemon: which system prompt, which
//! tools, and how a finished turn is shaped for storage.

use afterray_agent::QueueModel;
use afterray_harness::{
    Budgeted, Opening, CancelToken, CompactionNotice, ContextBudget, Discard, LoopConfig, LoopError,
    ModelError, PruneToolResults, ToolCallRecord, ToolSurface, Turn, TurnUsage, run_turn,
};
use afterray_models::{JobPriority, ModelQueue};
use serde_json::Value;

use crate::tools::{ToolHost, tool_catalog_text};

/// The fence that marks untrusted text.
///
/// `run_turn` fences the current question and each tool result as it renders;
/// the daemon fences stored user messages when it replays them, so the same
/// boundary applies whether a message is from this turn or a month ago.
pub(crate) use afterray_harness::fence::untrusted as fence_untrusted;

#[derive(Debug)]
pub enum AgentError {
    MissingModel,
    Failed(String),
}

impl std::fmt::Display for AgentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingModel => write!(f, "language model is not available"),
            Self::Failed(message) => write!(f, "{message}"),
        }
    }
}

impl From<LoopError> for AgentError {
    fn from(error: LoopError) -> Self {
        match error {
            LoopError::Model(ModelError::Missing) => Self::MissingModel,
            other => Self::Failed(other.to_string()),
        }
    }
}

/// Final answer plus every tool call from this turn, for `tool_log`.
#[derive(Debug, Clone)]
pub struct AgentTurn {
    pub answer: String,
    pub tool_calls: Vec<ToolCallRecord>,
    /// Passes that dropped an earlier result to make room.
    pub compactions: Vec<CompactionNotice>,
    pub usage: TurnUsage,
}

impl From<Turn> for AgentTurn {
    fn from(turn: Turn) -> Self {
        Self {
            answer: turn.answer,
            tool_calls: turn.tool_calls,
            compactions: turn.compactions,
            usage: turn.usage,
        }
    }
}

/// Runs a short tool-using loop. The model must answer with TOOL/ARGS or FINAL.
pub async fn run_readonly_agent(
    models: &ModelQueue,
    tools: &ToolHost<'_>,
    system: &str,
    opening: Opening,
) -> Result<String, AgentError> {
    Ok(run_readonly_agent_traced(models, tools, system, opening)
        .await?
        .answer)
}

/// Same loop as [`run_readonly_agent`], but keeps every tool call for storage.
pub async fn run_readonly_agent_traced(
    models: &ModelQueue,
    tools: &ToolHost<'_>,
    system: &str,
    opening: Opening,
) -> Result<AgentTurn, AgentError> {
    let system = format!("{system}\n\n{}", tool_catalog_text());
    let model = QueueModel {
        models,
        priority: JobPriority::Interactive,
        token_sink: None,
    };
    let strategy = PruneToolResults;
    let turn = run_turn(
        &model,
        tools,
        &mut Discard,
        &LoopConfig {
            budget: ContextBudget::DEFAULT,
            // The unary RPCs have no channel a stop could arrive on: the
            // caller is blocked on one response.
            cancel: CancelToken::new(),
            compaction: Some(&strategy),
        },
        &system,
        opening,
    )
    .await?;
    Ok(turn.into())
}

impl ToolSurface for ToolHost<'_> {
    async fn invoke(&self, name: &str, args: &Value) -> Result<Budgeted, String> {
        Self::invoke(self, name, args).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_harness::fence::DATA_FENCE_END;

    /// Both call paths render through the harness's one transcript, so the
    /// fence cannot be present in one and missing in the other — which is
    /// exactly how it was: `stream.rs` carried its own unfenced renderer.
    #[test]
    fn the_daemon_fences_untrusted_text_through_the_harness() {
        let fenced = fence_untrusted("tool_result", "SECRET_SCREEN");
        assert!(fenced.starts_with("<<<AFTERRAY_DATA kind=tool_result>>>"));
        assert!(fenced.contains("SECRET_SCREEN"));
        assert!(fenced.ends_with(DATA_FENCE_END));
    }

    #[test]
    fn a_missing_model_survives_the_error_conversion() {
        let error: AgentError = LoopError::Model(ModelError::Missing).into();
        assert!(matches!(error, AgentError::MissingModel));
        let error: AgentError = LoopError::Exhausted.into();
        assert!(matches!(error, AgentError::Failed(_)));
    }
}
