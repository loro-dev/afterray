//! Binds the agent harness to `AfterRay`'s model queue.
//!
//! The harness knows how to run a tool-calling loop; it does not know what a
//! `ModelQueue`, a job priority or a lease is. This crate is the seam: one
//! [`ModelSurface`] implementation, and the error classification that turns a
//! queue failure into something a handler can act on.
//!
//! Tools stay in the daemon, where the vault is.

use afterray_harness::{GenerateRequest, Message, ModelError, ModelSurface, StreamDelta};
use afterray_models::{
    ChatMessage, JobPriority, JobState, LlmDelta, LlmDeltaKind, LlmTokenSink, ModelInput,
    ModelOutput, ModelQueue, QueueError,
};
use tokio::sync::mpsc;

pub use afterray_harness as harness;

/// One round of the loop, run through the queue.
///
/// Every path — interactive chat, Ask, the background T2 summariser — goes
/// through the same queue, so switching between the builtin llama.cpp worker,
/// Ollama and an OpenAI-compatible endpoint is a settings change and nothing
/// more.
pub struct QueueModel<'a> {
    pub models: &'a ModelQueue,
    /// Scheduling class. Chat is interactive; the T2 summariser runs background
    /// under a lease so its rounds do not re-queue behind other background work.
    pub priority: JobPriority,
    /// When present, the adapter's token deltas are wired straight into the
    /// harness's channel for the duration of each round.
    ///
    /// The outlet is chat-only and single-slot, so it is installed per round and
    /// released as soon as the round settles — a queued summary must not inherit
    /// a chat window's outlet.
    pub token_sink: Option<&'a LlmTokenSink>,
}

impl ModelSurface for QueueModel<'_> {
    async fn generate(
        &self,
        request: GenerateRequest<'_>,
        tokens: mpsc::Sender<StreamDelta>,
    ) -> Result<String, ModelError> {
        self.run_round(request, tokens).await
    }
}

/// The harness's message type into the model layer's.
///
/// Two types on purpose: the harness must not depend on the model layer, and
/// the model layer must not depend on the harness. This crate is the only place
/// that knows both, exactly as it already is for token deltas.
fn to_model_message(message: &Message) -> ChatMessage {
    ChatMessage {
        role: message.role.wire_name().to_owned(),
        content: message.content().to_owned(),
    }
}

fn convert(delta: LlmDelta) -> StreamDelta {
    match delta.kind {
        LlmDeltaKind::Content => StreamDelta::content(delta.text),
        LlmDeltaKind::Reasoning => StreamDelta::reasoning(delta.text),
    }
}

impl QueueModel<'_> {
    /// Runs one job, forwarding adapter deltas to the harness as they arrive.
    ///
    /// The forwarding lives inside the same `select!` as the wait rather than in
    /// a spawned task: the adapter's channel is bounded, so a producer that
    /// outruns an undrained receiver blocks the generation itself.
    async fn run_round(
        &self,
        request: GenerateRequest<'_>,
        tokens: mpsc::Sender<StreamDelta>,
    ) -> Result<String, ModelError> {
        // The outlet is armed inside the submit, while the job is still
        // pending. Arming afterwards left a gap in which an idle lane could
        // start the adapter first, so whether a round streamed at all came down
        // to scheduling.
        let mut relay = None;
        let job_id = match self
            .models
            .submit_prepared(
                ModelInput::Llm {
                    prompt: request.prompt.to_owned(),
                    system: Some(request.system.to_owned()),
                    messages: request.messages.iter().map(to_model_message).collect(),
                },
                self.priority,
                |job_id| {
                    if let Some(sink) = self.token_sink {
                        let (adapter_tx, adapter_rx) = mpsc::channel::<LlmDelta>(64);
                        let guard = sink.install(job_id, adapter_tx);
                        relay = Some((adapter_rx, tokens.clone(), guard));
                    }
                },
            )
            .await
        {
            Ok(id) => id,
            Err(QueueError::MissingAdapter(_)) => return Err(ModelError::Missing),
            Err(error) => return Err(ModelError::Failed(error.to_string())),
        };

        // Race the wait against the stop signal, and take the job down with it.
        // Without this the queue keeps generating for a window nobody is
        // reading, and — worse on a single-lane local runtime — holds the LLM
        // lane against the next thing the user asks.
        let waiting = self.models.wait(&job_id);
        tokio::pin!(waiting);
        let snapshot = loop {
            tokio::select! {
                biased;
                Some(delta) = async {
                    match relay.as_mut() {
                        Some((rx, _, _)) => rx.recv().await,
                        None => std::future::pending().await,
                    }
                } => {
                    if let Some((_, tx, _)) = relay.as_ref()
                        && tx.send(convert(delta)).await.is_err()
                    {
                        // The harness stopped listening. Keep generating so the
                        // completed text still comes back, just unwatched.
                        relay = None;
                    }
                }
                settled = &mut waiting => {
                    break settled.map_err(|error| ModelError::Failed(error.to_string()))?;
                }
                () = request.cancel.cancelled() => {
                    let _ = self.models.cancel(&job_id).await;
                    return Err(ModelError::Cancelled);
                }
            }
        };

        if snapshot.state != JobState::Done {
            let error = snapshot
                .last_error
                .unwrap_or_else(|| format!("llm job ended as {:?}", snapshot.state));
            return Err(classify(&error));
        }
        match snapshot.output {
            Some(ModelOutput::Llm { text }) if !text.trim().is_empty() => Ok(text),
            Some(ModelOutput::Llm { .. }) => Err(ModelError::Failed("empty llm text".into())),
            _ => Err(ModelError::Failed("wrong llm output type".into())),
        }
    }
}

/// Turns an adapter's error text into a [`ModelError`].
///
/// The distinction matters at the surface: "no model is configured" is an
/// invitation to open Settings, while anything else is a failure the user can
/// only retry. Adapters phrase the first case several ways, so the check lives
/// here rather than being re-guessed in each handler — which is what it was.
#[must_use]
pub fn classify(error: &str) -> ModelError {
    if is_missing_model(error) {
        ModelError::Missing
    } else {
        ModelError::Failed(error.to_owned())
    }
}

/// Whether `message` means "nothing is configured to answer this".
#[must_use]
pub fn is_missing_model(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    [
        "missing",
        "not configured",
        "model asset is missing",
        "download the llm",
        "set afterray_llm_model",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_harness::{CancelToken, ContextBudget, Discard, LoopConfig, ToolSurface, run_turn};
    use afterray_models::{
        ModelAdapter, ModelCapability, ProcessAdapter, ProcessAdapterConfig, QueueConfig,
    };
    use std::sync::Arc;

    struct NoTools;

    impl ToolSurface for NoTools {
        async fn invoke(
            &self,
            name: &str,
            _args: &serde_json::Value,
        ) -> Result<afterray_harness::Budgeted, String> {
            Err(format!("unknown tool `{name}`"))
        }
    }

    fn queue(adapters: Vec<Arc<dyn ModelAdapter>>) -> ModelQueue {
        ModelQueue::new(adapters, QueueConfig::default()).unwrap()
    }

    fn scripted(script: &str) -> ModelQueue {
        let mut config =
            ProcessAdapterConfig::new("test-llm", ModelCapability::Llm, "/usr/bin/python3");
        config.args = vec!["-c".to_owned(), script.to_owned()];
        queue(vec![Arc::new(ProcessAdapter::new(config))])
    }

    #[test]
    fn missing_model_is_recognised_however_the_adapter_phrases_it() {
        for message in [
            "the model asset is missing",
            "LLM is not configured",
            "download the LLM pack first",
            "set AFTERRAY_LLM_MODEL to continue",
        ] {
            assert_eq!(classify(message), ModelError::Missing, "{message}");
        }
        assert!(matches!(
            classify("connection reset by peer"),
            ModelError::Failed(_)
        ));
    }

    /// No adapter at all must read as "open Settings", not as a crash.
    #[tokio::test]
    async fn an_empty_queue_reports_a_missing_model() {
        let models = queue(Vec::new());
        let model = QueueModel {
            models: &models,
            priority: JobPriority::Interactive,
            token_sink: None,
        };
        let error = run_turn(
            &model,
            &NoTools,
            &mut Discard,
            &LoopConfig {
                budget: ContextBudget::DEFAULT,
                cancel: CancelToken::new(),
                compaction: None,
            },
            "system",
            afterray_harness::Opening { task: "hello".into(), ..Default::default() },
        )
        .await
        .unwrap_err();
        assert_eq!(
            error,
            afterray_harness::LoopError::Model(ModelError::Missing)
        );
    }

    /// The whole binding, end to end against a real worker process: the loop's
    /// prompt reaches the adapter and the adapter's text comes back as an
    /// answer.
    #[tokio::test]
    async fn a_real_worker_round_trips_through_the_queue() {
        let script = r#"
import json, sys
req = json.load(sys.stdin)
prompt = ((req.get("input") or {}).get("prompt") or "")
assert "what did I do" in prompt, prompt
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "llm", "text": "FINAL\nYou read a design doc."},
  "retryable": False
}))
"#;
        let models = scripted(script);
        let model = QueueModel {
            models: &models,
            priority: JobPriority::Interactive,
            token_sink: None,
        };
        let turn = run_turn(
            &model,
            &NoTools,
            &mut Discard,
            &LoopConfig {
                budget: ContextBudget::DEFAULT,
                cancel: CancelToken::new(),
                compaction: None,
            },
            "system",
            afterray_harness::Opening { task: "what did I do".into(), ..Default::default() },
        )
        .await
        .unwrap();
        assert_eq!(turn.answer, "You read a design doc.");
        assert_eq!(turn.usage.rounds, 1);
    }

    /// The point of Phase 3: a running worker process is actually stopped, not
    /// merely abandoned. Before this, closing the chat window left the model
    /// generating — and on a single-lane local runtime, holding the LLM lane
    /// against whatever the user asked next.
    #[tokio::test]
    async fn cancelling_stops_the_running_job() {
        let script = r#"
import json, sys, time
json.load(sys.stdin)
time.sleep(60)
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "llm", "text": "FINAL\nfar too late"},
  "retryable": False
}))
"#;
        let models = scripted(script);
        let model = QueueModel {
            models: &models,
            priority: JobPriority::Interactive,
            token_sink: None,
        };
        let cancel = CancelToken::new();
        let fired = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            fired.cancel();
        });

        let error = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            run_turn(
                &model,
                &NoTools,
                &mut Discard,
                &LoopConfig {
                    budget: ContextBudget::DEFAULT,
                    cancel,
                    compaction: None,
                },
                "system",
                afterray_harness::Opening { task: "hello".into(), ..Default::default() },
            ),
        )
        .await
        .expect("the turn waited out a 60-second worker instead of stopping")
        .unwrap_err();
        assert_eq!(error, afterray_harness::LoopError::Cancelled);

        // And the job itself was taken down, not left running.
        let jobs = models.list().await;
        assert!(
            jobs.iter().all(|job| job.state != JobState::Running),
            "a job was left running: {jobs:?}"
        );
    }
}
