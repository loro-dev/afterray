//! The agent loop.
//!
//! One loop, not two. The daemon used to run a plain loop for Ask and the T2
//! summariser and a second, streaming one for chat; they drifted in three
//! separate ways (fencing, argument parsing, budgets) before this was written.
//!
//! The plugin surface is pi's `AgentLoopConfig` idea in Rust: everything the
//! loop does not decide for itself is a trait parameter, and a caller that does
//! not want a seam supplies the no-op. Generic rather than boxed closures, so
//! the unused seams cost nothing.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::mpsc;

use crate::budget::ContextBudget;
use crate::cancel::CancelToken;
use crate::compaction::{CompactionNotice, CompactionStrategy};
use crate::fence;
use crate::tokens::estimate_tokens;
use crate::transcript::Transcript;
use crate::truncate::Budgeted;
use crate::wire::{AnswerGate, Step, classify};

/// One round's request to the model.
#[derive(Debug, Clone, Copy)]
pub struct GenerateRequest<'a> {
    pub system: &'a str,
    pub prompt: &'a str,
    /// One-based, for logs and the `usage` event.
    pub round: usize,
    /// Implementations must race their wait against this and stop the
    /// underlying job when it fires. The loop also checks it, but by then the
    /// round has already been paid for — a model call is the longest thing a
    /// turn does, and cancelling it is most of what "stop" means.
    pub cancel: &'a CancelToken,
}

/// Something that can run one model round.
///
/// An implementation that can stream pushes deltas into `tokens` as they
/// arrive and still returns the complete text; one that cannot simply never
/// sends. The loop gates whatever arrives, so a `TOOL` draft never reaches a
/// client either way.
pub trait ModelSurface {
    fn generate(
        &self,
        request: GenerateRequest<'_>,
        tokens: mpsc::Sender<String>,
    ) -> impl Future<Output = Result<String, ModelError>> + Send;
}

/// Why a round could not produce text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelError {
    /// No model is configured, or its asset is missing. Callers turn this into
    /// a "open Settings" message rather than an error.
    Missing,
    Failed(String),
    /// The caller asked for the turn to stop.
    Cancelled,
}

impl std::fmt::Display for ModelError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Missing => write!(f, "language model is not available"),
            Self::Failed(message) => write!(f, "{message}"),
            Self::Cancelled => write!(f, "stopped"),
        }
    }
}

/// Anything that can answer the loop's TOOL calls.
pub trait ToolSurface {
    fn invoke(
        &self,
        name: &str,
        args: &Value,
    ) -> impl Future<Output = Result<Budgeted, String>> + Send;
}

/// What the loop wants the outside world to know as it happens.
#[derive(Debug, Clone, PartialEq)]
pub enum HarnessEvent {
    ToolCall {
        name: String,
        args: Value,
    },
    ToolResult {
        name: String,
        chars: usize,
        truncated: bool,
        dropped: usize,
    },
    Token {
        text: String,
    },
    Usage {
        prompt_tokens: usize,
        window_tokens: usize,
        round: usize,
    },
    Compaction(CompactionNotice),
}

/// Where [`HarnessEvent`]s go. [`Discard`] is the no-op for callers that only
/// want the final answer.
pub trait EventSink {
    /// An error here means the client is gone; the loop stops the turn.
    fn emit(&mut self, event: HarnessEvent) -> impl Future<Output = Result<(), String>> + Send;
}

/// The sink for callers with nobody to tell.
#[derive(Debug, Default, Clone, Copy)]
pub struct Discard;

impl EventSink for Discard {
    async fn emit(&mut self, _event: HarnessEvent) -> Result<(), String> {
        Ok(())
    }
}

/// Loop shape.
pub struct LoopConfig<'a> {
    /// Rounds and token caps as one coherent set.
    pub budget: ContextBudget,
    /// Stops the turn. [`CancelToken::new`] for a caller that never cancels.
    pub cancel: CancelToken,
    /// How the transcript is kept inside the window. `None` runs append-only:
    /// a prefix-caching runtime then re-prefills only each round's delta, and
    /// rewriting an earlier round would invalidate the whole cached prefix.
    pub compaction: Option<&'a dyn CompactionStrategy>,
}

/// A finished turn.
#[derive(Debug, Clone, Default)]
pub struct Turn {
    pub answer: String,
    pub tool_calls: Vec<ToolCallRecord>,
    /// Tool outputs, parallel to `tool_calls`. Grounding checks need them: a
    /// claim counts as evidenced if it appears in the prompt *or* in something
    /// a tool returned during the turn.
    pub tool_results: Vec<String>,
    pub compactions: Vec<CompactionNotice>,
    pub usage: TurnUsage,
}

/// One tool the model invoked.
///
/// Serialized as-is into the assistant message's `tool_log`, so the chat panel
/// can show what a past answer was built from.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCallRecord {
    pub name: String,
    pub args: Value,
}

/// How full the window got on the last round.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TurnUsage {
    pub prompt_tokens: usize,
    pub window_tokens: usize,
    pub rounds: usize,
}

impl TurnUsage {
    /// Occupancy as a fraction, for a meter. Zero when no window is known.
    #[must_use]
    pub fn fraction(self) -> f32 {
        if self.window_tokens == 0 {
            return 0.0;
        }
        #[expect(
            clippy::cast_precision_loss,
            reason = "token counts are far below f32's exact-integer range"
        )]
        let fraction = self.prompt_tokens as f32 / self.window_tokens as f32;
        fraction.min(1.0)
    }
}

/// Why a turn ended without an answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoopError {
    Model(ModelError),
    /// The sink refused an event — the client hung up.
    SinkClosed(String),
    /// Every round was spent without the model finishing.
    Exhausted,
    /// The caller asked the turn to stop.
    Cancelled,
}

impl std::fmt::Display for LoopError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Model(error) => write!(f, "{error}"),
            Self::SinkClosed(message) => write!(f, "{message}"),
            Self::Exhausted => write!(f, "agent loop exhausted"),
            Self::Cancelled => write!(f, "stopped"),
        }
    }
}

impl From<ModelError> for LoopError {
    fn from(error: ModelError) -> Self {
        match error {
            ModelError::Cancelled => Self::Cancelled,
            other => Self::Model(other),
        }
    }
}

/// Runs one turn: rounds of model call, tool call, until `FINAL` or the cap.
///
/// `opening` is the transcript's first block — the task, the clock anchors and
/// any seed. It is never dropped; without it the model has no epoch numbers and
/// no question.
///
/// # Errors
///
/// [`LoopError::Model`] when a round could not produce text,
/// [`LoopError::SinkClosed`] when the client hung up, and
/// [`LoopError::Exhausted`] when every round was spent without an answer.
pub async fn run_turn<M, T, S>(
    model: &M,
    tools: &T,
    sink: &mut S,
    config: &LoopConfig<'_>,
    system: &str,
    opening: String,
) -> Result<Turn, LoopError>
where
    M: ModelSurface + Sync,
    T: ToolSurface + Sync,
    S: EventSink,
{
    let mut transcript = Transcript::new(opening, fence::untrusted);
    let mut turn = Turn::default();

    for round in 0..config.budget.max_rounds {
        if config.cancel.is_cancelled() {
            return Err(LoopError::Cancelled);
        }
        if let Some(strategy) = config.compaction {
            for notice in strategy.compact(&mut transcript, config.budget) {
                emit(sink, HarnessEvent::Compaction(notice.clone())).await?;
                turn.compactions.push(notice);
            }
        }

        let prompt = transcript.render();
        turn.usage = TurnUsage {
            prompt_tokens: estimate_tokens(&prompt),
            window_tokens: config.budget.window_tokens,
            rounds: round + 1,
        };
        emit(
            sink,
            HarnessEvent::Usage {
                prompt_tokens: turn.usage.prompt_tokens,
                window_tokens: turn.usage.window_tokens,
                round: round + 1,
            },
        )
        .await?;

        let request = GenerateRequest {
            system,
            prompt: &prompt,
            round: round + 1,
            cancel: &config.cancel,
        };
        let (text, mut gate) = generate_gated(model, sink, request).await?;

        match classify(&text) {
            Step::Answer(answer) => {
                if let Some(text) = gate.leftover_answer(&answer) {
                    emit(sink, HarnessEvent::Token { text }).await?;
                }
                turn.answer = answer;
                return Ok(turn);
            }
            Step::Empty => {
                return Err(LoopError::Model(ModelError::Failed(
                    "model returned empty output".into(),
                )));
            }
            Step::Call { name, args } => {
                let result = call_tool(tools, sink, &config.cancel, &name, &args).await?;
                turn.tool_calls.push(ToolCallRecord {
                    name: name.clone(),
                    args: args.clone(),
                });
                turn.tool_results.push(result.text.clone());
                let body = result.text.clone();
                transcript.push(name.clone(), args, result);

                if round + 1 == config.budget.max_rounds {
                    // Out of rounds mid-investigation. Handing back the last
                    // result beats an apology: it is the evidence the model was
                    // about to reason over, and the user can read it.
                    let answer = format!(
                        "I reached the tool limit before finishing. Last tool `{name}` returned:\n{body}"
                    );
                    emit(
                        sink,
                        HarnessEvent::Token {
                            text: answer.clone(),
                        },
                    )
                    .await?;
                    turn.answer = answer;
                    return Ok(turn);
                }
            }
        }
    }
    Err(LoopError::Exhausted)
}

/// Runs one round, forwarding gated token deltas to the sink as they arrive.
async fn generate_gated<M, S>(
    model: &M,
    sink: &mut S,
    request: GenerateRequest<'_>,
) -> Result<(String, AnswerGate), LoopError>
where
    M: ModelSurface + Sync,
    S: EventSink,
{
    let (sender, mut receiver) = mpsc::channel::<String>(64);
    let mut gate = AnswerGate::default();
    let generating = model.generate(request, sender);
    tokio::pin!(generating);

    let cancel = request.cancel.clone();
    let text = loop {
        tokio::select! {
            // Bias towards draining tokens: a finished generate that leaves
            // deltas queued would otherwise emit them all after the fact.
            biased;
            Some(delta) = receiver.recv() => {
                for text in gate.push(&delta) {
                    emit(sink, HarnessEvent::Token { text }).await?;
                }
            }
            result = &mut generating => break result?,
            // Backstop. A well-behaved ModelSurface stops its own job and
            // returns ModelError::Cancelled; this covers one that does not, so
            // "stop" is never worse than one round late.
            () = cancel.cancelled() => return Err(LoopError::Cancelled),
        }
    };
    while let Ok(delta) = receiver.try_recv() {
        for text in gate.push(&delta) {
            emit(sink, HarnessEvent::Token { text }).await?;
        }
    }
    Ok((text, gate))
}

async fn call_tool<T, S>(
    tools: &T,
    sink: &mut S,
    cancel: &CancelToken,
    name: &str,
    args: &Value,
) -> Result<Budgeted, LoopError>
where
    T: ToolSurface + Sync,
    S: EventSink,
{
    if cancel.is_cancelled() {
        return Err(LoopError::Cancelled);
    }
    emit(
        sink,
        HarnessEvent::ToolCall {
            name: name.to_owned(),
            args: args.clone(),
        },
    )
    .await?;
    // A tool error is evidence, not a turn failure: the model can read "the
    // requested window is outside the recorded history" and try another one.
    //
    // Racing the invocation rather than awaiting it: a vault query runs on a
    // blocking thread and cannot be interrupted mid-statement, but the turn
    // does not have to wait for one it has been told to abandon. The query
    // finishes into a dropped future.
    let invoking = tools.invoke(name, args);
    tokio::pin!(invoking);
    let result = tokio::select! {
        outcome = &mut invoking => match outcome {
            Ok(result) => result,
            Err(error) => Budgeted::verbatim(format!("ERROR: {error}")),
        },
        () = cancel.cancelled() => return Err(LoopError::Cancelled),
    };
    emit(
        sink,
        HarnessEvent::ToolResult {
            name: name.to_owned(),
            chars: result.text.chars().count(),
            truncated: result.truncated,
            dropped: result.dropped_tokens,
        },
    )
    .await?;
    Ok(result)
}

async fn emit<S: EventSink>(sink: &mut S, event: HarnessEvent) -> Result<(), LoopError> {
    sink.emit(event).await.map_err(LoopError::SinkClosed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compaction::PruneToolResults;
    use std::sync::Mutex;

    /// Replays a script of round outputs, optionally as token deltas.
    struct ScriptedModel {
        rounds: Mutex<Vec<String>>,
        stream: bool,
        seen: Mutex<Vec<String>>,
    }

    impl ScriptedModel {
        fn new(rounds: &[&str], stream: bool) -> Self {
            Self {
                rounds: Mutex::new(rounds.iter().rev().map(|text| (*text).to_owned()).collect()),
                stream,
                seen: Mutex::new(Vec::new()),
            }
        }
    }

    impl ModelSurface for ScriptedModel {
        async fn generate(
            &self,
            request: GenerateRequest<'_>,
            tokens: mpsc::Sender<String>,
        ) -> Result<String, ModelError> {
            if request.cancel.is_cancelled() {
                return Err(ModelError::Cancelled);
            }
            self.seen.lock().unwrap().push(request.prompt.to_owned());
            let text = self
                .rounds
                .lock()
                .unwrap()
                .pop()
                .ok_or_else(|| ModelError::Failed("script ran out".into()))?;
            if self.stream {
                for chunk in text.as_bytes().chunks(3) {
                    let piece = String::from_utf8_lossy(chunk).into_owned();
                    let _ = tokens.send(piece).await;
                }
            }
            Ok(text)
        }
    }

    struct EchoTools {
        body: String,
    }

    impl ToolSurface for EchoTools {
        async fn invoke(&self, name: &str, _args: &Value) -> Result<Budgeted, String> {
            if name == "boom" {
                return Err("no such window".into());
            }
            Ok(Budgeted::verbatim(self.body.clone()))
        }
    }

    #[derive(Default)]
    struct Recorder {
        events: Vec<HarnessEvent>,
    }

    /// Fires the token once it has seen `after` events, so a test can cancel
    /// from inside a running turn rather than racing a timer.
    struct CancelAfter {
        cancel: CancelToken,
        after: usize,
        seen: usize,
    }

    impl EventSink for CancelAfter {
        async fn emit(&mut self, _event: HarnessEvent) -> Result<(), String> {
            self.seen += 1;
            if self.seen >= self.after {
                self.cancel.cancel();
            }
            Ok(())
        }
    }

    impl EventSink for Recorder {
        async fn emit(&mut self, event: HarnessEvent) -> Result<(), String> {
            self.events.push(event);
            Ok(())
        }
    }

    fn config() -> LoopConfig<'static> {
        LoopConfig {
            budget: ContextBudget::DEFAULT,
            cancel: CancelToken::new(),
            compaction: None,
        }
    }

    async fn run(
        model: &ScriptedModel,
        tools: &EchoTools,
        sink: &mut Recorder,
    ) -> Result<Turn, LoopError> {
        run_turn(
            model,
            tools,
            sink,
            &config(),
            "system",
            "User task:\nwhat did I do\n".to_owned(),
        )
        .await
    }

    #[tokio::test]
    async fn answers_without_calling_anything() {
        let model = ScriptedModel::new(&["FINAL\nYou used Safari."], false);
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();
        assert_eq!(turn.answer, "You used Safari.");
        assert!(turn.tool_calls.is_empty());
        assert_eq!(turn.usage.rounds, 1);
        assert!(turn.usage.prompt_tokens > 0);
    }

    #[tokio::test]
    async fn calls_a_tool_then_answers_and_reports_both() {
        let model = ScriptedModel::new(
            &["TOOL list_activity\nARGS {\"from_ms\":1,\"to_ms\":2}", "FINAL\nZed, mostly."],
            false,
        );
        let tools = EchoTools {
            body: "[{\"app\":\"Zed\"}]".to_owned(),
        };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();

        assert_eq!(turn.answer, "Zed, mostly.");
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.tool_calls[0].name, "list_activity");
        assert_eq!(turn.tool_results[0], "[{\"app\":\"Zed\"}]");
        assert!(sink.events.iter().any(|event| matches!(
            event,
            HarnessEvent::ToolCall { name, .. } if name == "list_activity"
        )));
        assert!(sink.events.iter().any(|event| matches!(
            event,
            HarnessEvent::ToolResult { name, truncated: false, .. } if name == "list_activity"
        )));
        // The second round must have seen the first round's result.
        let prompts = model.seen.lock().unwrap().clone();
        assert!(prompts[1].contains("\"app\":\"Zed\""), "{}", prompts[1]);
    }

    /// A tool that refuses is evidence the model can act on, not a dead turn.
    #[tokio::test]
    async fn a_tool_error_goes_back_to_the_model() {
        let model = ScriptedModel::new(&["TOOL boom\nARGS {}", "FINAL\nI tried elsewhere."], false);
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();
        assert_eq!(turn.answer, "I tried elsewhere.");
        assert!(turn.tool_results[0].starts_with("ERROR: no such window"));
        let prompts = model.seen.lock().unwrap().clone();
        assert!(prompts[1].contains("no such window"));
    }

    /// The gate's whole job: a round that turns out to be a tool call must not
    /// have leaked its first characters into the chat window.
    #[tokio::test]
    async fn streaming_hides_tool_drafts_and_shows_answers() {
        let model = ScriptedModel::new(
            &["TOOL get_now\nARGS {}", "FINAL\nIt is Tuesday afternoon."],
            true,
        );
        let tools = EchoTools {
            body: "{\"now_ms\":1}".to_owned(),
        };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();

        let streamed: String = sink
            .events
            .iter()
            .filter_map(|event| match event {
                HarnessEvent::Token { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(streamed, "It is Tuesday afternoon.");
        assert!(!streamed.contains("TOOL"));
        assert!(!streamed.contains("get_now"));
        assert_eq!(turn.answer, "It is Tuesday afternoon.");
    }

    /// Every round reports occupancy, so context pressure is never invisible.
    #[tokio::test]
    async fn every_round_reports_usage() {
        let model = ScriptedModel::new(&["TOOL get_now\nARGS {}", "FINAL\ndone"], false);
        let tools = EchoTools { body: "{}".to_owned() };
        let mut sink = Recorder::default();
        run(&model, &tools, &mut sink).await.unwrap();
        let rounds: Vec<usize> = sink
            .events
            .iter()
            .filter_map(|event| match event {
                HarnessEvent::Usage { round, .. } => Some(*round),
                _ => None,
            })
            .collect();
        assert_eq!(rounds, [1, 2]);
    }

    /// Running out of rounds hands back the last evidence rather than an
    /// apology with nothing in it.
    #[tokio::test]
    async fn the_round_cap_returns_the_last_result() {
        let calls: Vec<&str> = (0..ContextBudget::DEFAULT.max_rounds)
            .map(|_| "TOOL get_now\nARGS {}")
            .collect();
        let model = ScriptedModel::new(&calls, false);
        let tools = EchoTools {
            body: "{\"now_ms\":42}".to_owned(),
        };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();
        assert!(turn.answer.contains("reached the tool limit"));
        assert!(turn.answer.contains("\"now_ms\":42"));
        assert_eq!(turn.tool_calls.len(), ContextBudget::DEFAULT.max_rounds);
    }

    #[tokio::test]
    async fn a_missing_model_is_distinguishable() {
        struct NoModel;
        impl ModelSurface for NoModel {
            async fn generate(
                &self,
                _request: GenerateRequest<'_>,
                _tokens: mpsc::Sender<String>,
            ) -> Result<String, ModelError> {
                Err(ModelError::Missing)
            }
        }
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let error = run_turn(&NoModel, &tools, &mut sink, &config(), "s", "t".to_owned())
            .await
            .unwrap_err();
        assert_eq!(error, LoopError::Model(ModelError::Missing));
    }

    /// A client that hangs up stops the turn instead of being written to for
    /// another five rounds.
    #[tokio::test]
    async fn a_closed_sink_stops_the_turn() {
        struct Closed;
        impl EventSink for Closed {
            async fn emit(&mut self, _event: HarnessEvent) -> Result<(), String> {
                Err("client gone".into())
            }
        }
        let model = ScriptedModel::new(&["FINAL\nhello"], false);
        let tools = EchoTools { body: String::new() };
        let error = run_turn(
            &model,
            &tools,
            &mut Closed,
            &config(),
            "system",
            "task".to_owned(),
        )
        .await
        .unwrap_err();
        assert_eq!(error, LoopError::SinkClosed("client gone".into()));
        // It stopped before the model was even asked.
        assert!(model.seen.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn compaction_is_announced_before_it_takes_effect() {
        let strategy = PruneToolResults;
        let config = LoopConfig {
            budget: ContextBudget::DEFAULT,
            cancel: CancelToken::new(),
            compaction: Some(&strategy),
        };
        let calls: Vec<&str> = vec![
            "TOOL get_slot_card\nARGS {\"at_ms\":1}",
            "TOOL get_slot_card\nARGS {\"at_ms\":2}",
            "FINAL\ndone",
        ];
        let model = ScriptedModel::new(&calls, false);
        let tools = EchoTools {
            body: "y".repeat(60_000),
        };
        let mut sink = Recorder::default();
        let turn = run_turn(&model, &tools, &mut sink, &config, "system", "task".to_owned())
            .await
            .unwrap();

        assert!(!turn.compactions.is_empty(), "nothing was compacted");
        assert!(sink.events.iter().any(|event| matches!(event, HarnessEvent::Compaction(_))));
        assert!(turn.usage.prompt_tokens <= ContextBudget::DEFAULT.window_tokens);
    }

    /// Stop must land before the next model call, not after it. A round is
    /// the most expensive thing a turn does; noticing one round late is what
    /// "stop" used to mean.
    #[tokio::test]
    async fn cancelling_between_rounds_stops_before_the_next_model_call() {
        let model = ScriptedModel::new(&["TOOL get_now\nARGS {}", "FINAL\nnever reached"], false);
        let tools = EchoTools { body: "{}".to_owned() };
        let cancel = CancelToken::new();
        // Cancelled while the first round's tool result is being folded in.
        let mut sink = CancelAfter {
            cancel: cancel.clone(),
            after: 3,
            seen: 0,
        };
        let error = run_turn(
            &model,
            &tools,
            &mut sink,
            &LoopConfig {
                budget: ContextBudget::DEFAULT,
                cancel,
                compaction: None,
            },
            "system",
            "task".to_owned(),
        )
        .await
        .unwrap_err();
        assert_eq!(error, LoopError::Cancelled);
        assert_eq!(
            model.seen.lock().unwrap().len(),
            1,
            "a second round was started after the cancel"
        );
    }

    /// A turn cancelled before it starts must not reach the model at all.
    #[tokio::test]
    async fn an_already_cancelled_turn_never_calls_the_model() {
        let model = ScriptedModel::new(&["FINAL\nhello"], false);
        let tools = EchoTools { body: String::new() };
        let error = run_turn(
            &model,
            &tools,
            &mut Recorder::default(),
            &LoopConfig {
                budget: ContextBudget::DEFAULT,
                cancel: CancelToken::cancelled_now(),
                compaction: None,
            },
            "system",
            "task".to_owned(),
        )
        .await
        .unwrap_err();
        assert_eq!(error, LoopError::Cancelled);
        assert!(model.seen.lock().unwrap().is_empty());
    }

    /// The case the old code could not handle at all: a tool call that takes
    /// seconds. The turn returns on the cancel rather than waiting it out.
    #[tokio::test]
    async fn cancelling_during_a_slow_tool_returns_without_waiting_for_it() {
        struct SlowTools;
        impl ToolSurface for SlowTools {
            async fn invoke(&self, _name: &str, _args: &Value) -> Result<Budgeted, String> {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                Ok(Budgeted::verbatim("far too late".to_owned()))
            }
        }
        let model = ScriptedModel::new(&["TOOL get_slot_card\nARGS {\"at_ms\":1}"], false);
        let cancel = CancelToken::new();
        let fired = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            fired.cancel();
        });
        let error = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_turn(
                &model,
                &SlowTools,
                &mut Recorder::default(),
                &LoopConfig {
                    budget: ContextBudget::DEFAULT,
                    cancel,
                    compaction: None,
                },
                "system",
                "task".to_owned(),
            ),
        )
        .await
        .expect("the turn waited for the tool instead of stopping")
        .unwrap_err();
        assert_eq!(error, LoopError::Cancelled);
    }

    /// A model that ignores the token is still stopped, one round late at worst.
    #[tokio::test]
    async fn a_model_that_ignores_the_token_is_still_cut_off() {
        struct Stubborn;
        impl ModelSurface for Stubborn {
            async fn generate(
                &self,
                _request: GenerateRequest<'_>,
                _tokens: mpsc::Sender<String>,
            ) -> Result<String, ModelError> {
                tokio::time::sleep(std::time::Duration::from_secs(30)).await;
                Ok("FINAL\ntoo late".to_owned())
            }
        }
        let cancel = CancelToken::new();
        let fired = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            fired.cancel();
        });
        let error = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_turn(
                &Stubborn,
                &EchoTools { body: String::new() },
                &mut Recorder::default(),
                &LoopConfig {
                    budget: ContextBudget::DEFAULT,
                    cancel,
                    compaction: None,
                },
                "system",
                "task".to_owned(),
            ),
        )
        .await
        .expect("the loop waited for a model that ignored the token")
        .unwrap_err();
        assert_eq!(error, LoopError::Cancelled);
    }

    #[test]
    fn usage_fraction_is_clamped() {
        let usage = TurnUsage {
            prompt_tokens: 8_192,
            window_tokens: 16_384,
            rounds: 1,
        };
        assert!((usage.fraction() - 0.5).abs() < f32::EPSILON);
        assert!(TurnUsage::default().fraction().abs() < f32::EPSILON);
        let over = TurnUsage {
            prompt_tokens: 99_999,
            window_tokens: 1_000,
            rounds: 1,
        };
        assert!((over.fraction() - 1.0).abs() < f32::EPSILON);
    }
}
