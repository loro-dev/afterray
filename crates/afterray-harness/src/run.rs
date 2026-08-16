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
use std::time::Instant;
use serde_json::Value;
use tokio::sync::mpsc;

use crate::budget::ContextBudget;
use crate::cancel::CancelToken;
use crate::compaction::{CompactionNotice, CompactionStrategy};
use crate::fence;
use crate::message::Message;
use crate::opening::Opening;
use crate::progress::{PROGRESS_INTERVAL, Phase, ProgressReport};
use crate::tokens::estimate_tokens;
use crate::transcript::Transcript;
use crate::truncate::Budgeted;
use crate::wire::{AnswerGate, Step, classify};

/// One round's request to the model.
#[derive(Debug, Clone, Copy)]
pub struct GenerateRequest<'a> {
    pub system: &'a str,
    /// The conversation, flattened. For a runtime that takes one string.
    pub prompt: &'a str,
    /// The same conversation as messages, for a runtime that takes an array.
    ///
    /// Both are handed over because the two runtimes want different shapes and
    /// neither should have to reconstruct the other's — a flattening done in
    /// two places is a flattening that will disagree in one of them.
    pub messages: &'a [Message],
    /// One-based, for logs and the `usage` event.
    pub round: usize,
    /// Implementations must race their wait against this and stop the
    /// underlying job when it fires. The loop also checks it, but by then the
    /// round has already been paid for — a model call is the longest thing a
    /// turn does, and cancelling it is most of what "stop" means.
    pub cancel: &'a CancelToken,
}

/// One piece of a streaming round.
///
/// The harness defines its own rather than borrowing the model layer's, because
/// it must not depend on one. `afterray-agent` converts at the seam.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamDelta {
    pub kind: DeltaKind,
    pub text: String,
}

impl StreamDelta {
    #[must_use]
    pub fn content(text: impl Into<String>) -> Self {
        Self {
            kind: DeltaKind::Content,
            text: text.into(),
        }
    }

    #[must_use]
    pub fn reasoning(text: impl Into<String>) -> Self {
        Self {
            kind: DeltaKind::Reasoning,
            text: text.into(),
        }
    }
}

/// Which stream a delta belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeltaKind {
    /// Part of the answer. Goes through the gate and, if it survives, to the
    /// user.
    Content,
    /// The model's reasoning. Counted as proof of life, never shown, and never
    /// parsed — a "FINAL" inside a reasoning block must not end the turn.
    Reasoning,
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
        tokens: mpsc::Sender<StreamDelta>,
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
        /// The result as the transcript received it, already capped.
        ///
        /// Carried on the event, not just returned in [`Turn`], because a host
        /// persists the turn *as it runs*: a turn that is interrupted still has
        /// to keep what it already looked up, and by then there is no `Turn` to
        /// read it from.
        text: String,
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
    /// The turn is alive but has nothing to show yet. See [`crate::progress`]
    /// for the three stretches this covers.
    Progress(ProgressReport),
    /// A piece of the model's reasoning.
    ///
    /// Emitted so a host can keep it; **not** meant for a chat window. The
    /// daemon accumulates these and never puts them on the wire.
    Reasoning {
        text: String,
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
    /// How the transcript and the conversation are kept inside the window.
    ///
    /// `None` means nothing removes anything: the turn runs append-only, and a
    /// caller choosing it is asserting that its conversation fits. Nothing else
    /// bounds the history — the renderer deliberately cannot, because a
    /// renderer that drops "whatever does not fit" keeps a different subset
    /// every turn and never says which.
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
    /// The model's reasoning, one entry per round that produced any.
    pub reasoning: Vec<RoundReasoning>,
    pub usage: TurnUsage,
}

/// One round's reasoning, kept whole.
///
/// Per round rather than concatenated because the one API that demands it back
/// — `DeepSeek`'s `reasoning_content`, which 400s on multi-turn without it —
/// wants it verbatim per assistant message. `signature` is the slot for the
/// opaque payload the `OpenAI` Responses API returns; no provider we speak to
/// today sends one.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoundReasoning {
    pub round: usize,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
}

/// One tool the model invoked.
///
/// Serialized as-is into the assistant message's `tool_log`, so the chat panel
/// can show what a past answer was built from.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCallRecord {
    pub name: String,
    pub args: Value,
    /// What the call returned — **the bytes that went to the model**, after
    /// truncation, not the original.
    ///
    /// This is the whole point. Storing the raw result and re-truncating it on
    /// replay would make the same past render differently on a machine with a
    /// different window, or after the user changes a setting: the budget
    /// changes, `tool_result_tokens` changes, the cut lands elsewhere, and the
    /// append-only prefix is gone. What was sent is what is kept, and it is
    /// replayed byte for byte with no budget logic anywhere near it.
    ///
    /// `None` on rows written before results were stored.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
    /// Characters in `result`. Redundant with it, and written anyway: the chat
    /// panel reads this field to caption the call, and it predates the result
    /// being stored at all.
    #[serde(default, rename = "chars", skip_serializing_if = "Option::is_none")]
    pub chars: Option<usize>,
    /// Whether that result had already been cut when it was sent.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub dropped_tokens: usize,
}

#[allow(clippy::trivially_copy_pass_by_ref)] // serde's `skip_serializing_if` shape
fn is_zero(value: &usize) -> bool {
    *value == 0
}

impl ToolCallRecord {
    /// A call and the result exactly as the transcript received it.
    #[must_use]
    pub fn new(name: String, args: Value, result: &Budgeted) -> Self {
        Self {
            name,
            args,
            chars: Some(result.text.chars().count()),
            result: Some(result.text.clone()),
            truncated: result.truncated,
            dropped_tokens: result.dropped_tokens,
        }
    }
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
// Keeping the state transitions in one function makes the round budget,
// cancellation checks, tool execution, and answer-only final round auditable
// as one loop. Splitting it would hide transitions behind helper side effects.
#[allow(clippy::too_many_lines)]
pub async fn run_turn<M, T, S>(
    model: &M,
    tools: &T,
    sink: &mut S,
    config: &LoopConfig<'_>,
    system: &str,
    opening: Opening,
) -> Result<Turn, LoopError>
where
    M: ModelSurface + Sync,
    T: ToolSurface + Sync,
    S: EventSink,
{
    // Each part of the opening against its own budget. Trimming the whole
    // block from the head kept the clock and a stale conversation and deleted
    // the question the user had just asked — see `opening`.
    let mut turn_compactions = Vec::new();
    // The conversation is brought inside its share before anything is
    // rendered, by the same policy that prunes inside a turn. Doing it here
    // rather than inside `render_messages` is what lets it be announced: the
    // caller hears a `Compaction` event and can write the same row it writes
    // for an in-turn pass.
    let mut opening = opening;
    if let Some(strategy) = config.compaction {
        let limit = config.budget.opening_allowance();
        for notice in strategy.compact_history(&mut opening.history, limit) {
            emit(sink, HarnessEvent::Compaction(notice.clone())).await?;
            turn_compactions.push(notice);
        }
    }
    let (opening_messages, trim) = opening.render_messages(config.budget, fence::untrusted);
    let rendered = format!("{}\n", crate::message::flatten(&opening_messages));
    if trim.happened() {
        let after = estimate_tokens(&rendered);
        emit(
            sink,
            HarnessEvent::Compaction(CompactionNotice {
                strategy: "trim_opening",
                from_round: 0,
                to_round: 0,
                tokens_before: after + trim.seed_dropped + trim.task_dropped,
                tokens_after: after,
            }),
        )
        .await?;
    }
    let mut transcript = Transcript::new(rendered, fence::untrusted);
    let mut turn = Turn {
        compactions: turn_compactions,
        ..Turn::default()
    };

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
        // The same conversation twice, from one source: the opening's messages
        // plus this turn's rounds. `prompt` is their flattening, so a runtime
        // that takes one string and one that takes an array see the same thing.
        let mut messages = opening_messages.clone();
        messages.extend(transcript.messages());
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
            messages: &messages,
            round: round + 1,
            cancel: &config.cancel,
        };
        let (text, mut gate, reasoning) = generate_gated(model, sink, request).await?;
        if !reasoning.trim().is_empty() {
            turn.reasoning.push(RoundReasoning {
                round: round + 1,
                text: reasoning,
                signature: None,
            });
        }

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
            // A tool call whose arguments do not parse is a mistake to correct,
            // not an answer. Handing the model its own error and spending a
            // round is what a person would do; the alternative — which is what
            // happened before — is that the raw `TOOL …` text goes down the
            // answer path, the gate hides it for starting with `TOOL`, and the
            // turn reports success having stored nothing.
            Step::Malformed { name, reason } => {
                // A control entry, not a tool result: results are fenced as
                // untrusted data and the system prompt tells the model to
                // ignore instructions inside that fence, so a correction
                // delivered that way asks to be disregarded.
                transcript.push_control(format!(
                    "Your last reply looked like a call to `{name}` but {reason}. \
                     Reply again with exactly two lines: TOOL <name>, then ARGS \
                     <one JSON object>."
                ));
                if round + 1 == config.budget.max_rounds {
                    return Err(LoopError::Model(ModelError::Failed(
                        "the model never produced a usable tool call or answer".into(),
                    )));
                }
            }
            Step::Call { name, args } => {
                // The last round is for answering, and saying so is not enough
                // on its own: a model that ignores it would otherwise have its
                // tool actually run, and the turn would fail anyway — paying
                // for a lookup nobody reads.
                if round + 1 == config.budget.max_rounds {
                    transcript.push_control(format!(
                        "`{name}` was not run: no rounds remain for this turn."
                    ));
                    break;
                }
                let result = call_tool(tools, sink, &config.cancel, &name, &args).await?;
                turn
                    .tool_calls
                    .push(ToolCallRecord::new(name.clone(), args.clone(), &result));
                turn.tool_results.push(result.text.clone());
                transcript.push(name.clone(), args, result);

                if round + 2 == config.budget.max_rounds {
                    transcript.push_control(
                        "No tool calls remain for this turn. Answer now with FINAL, from \
                         the evidence above, and say what you could not check.",
                    );
                }
            }
        }
    }
    // The model was given a round to answer in and used it on something else.
    Err(LoopError::Exhausted)
}

/// Runs one round, forwarding gated token deltas to the sink as they arrive.
async fn generate_gated<M, S>(
    model: &M,
    sink: &mut S,
    request: GenerateRequest<'_>,
) -> Result<(String, AnswerGate, String), LoopError>
where
    M: ModelSurface + Sync,
    S: EventSink,
{
    let (sender, mut receiver) = mpsc::channel::<StreamDelta>(64);
    let mut gate = AnswerGate::default();
    let round = request.round;
    let generating = model.generate(request, sender);
    tokio::pin!(generating);

    let cancel = request.cancel.clone();
    let started = Instant::now();
    let mut reasoning_deltas = 0_usize;
    let mut reasoning = String::new();
    let mut shown_anything = false;
    let mut heartbeat = tokio::time::interval(PROGRESS_INTERVAL);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // `interval` fires its first tick immediately; drop it so the first beat
    // lands one interval in. A round that finishes faster than that needs no
    // indicator, and showing one for a few milliseconds is a flicker, not
    // feedback.
    heartbeat.tick().await;

    let text = loop {
        tokio::select! {
            // Bias towards draining tokens: a finished generate that leaves
            // deltas queued would otherwise emit them all after the fact.
            biased;
            Some(delta) = receiver.recv() => {
                match delta.kind {
                    DeltaKind::Reasoning => {
                        reasoning_deltas += 1;
                        reasoning.push_str(&delta.text);
                        emit(sink, HarnessEvent::Reasoning {
                            text: delta.text,
                            round,
                        }).await?;
                    }
                    DeltaKind::Content => {
                        for text in gate.push(&delta.text) {
                            shown_anything = true;
                            emit(sink, HarnessEvent::Token { text }).await?;
                        }
                    }
                }
            }
            result = &mut generating => break result?,
            _ = heartbeat.tick() => {
                // Silent once the answer is on screen: the text itself is then
                // the proof of life, and a second indicator beside it only
                // competes with the caret.
                if !shown_anything {
                    emit(sink, HarnessEvent::Progress(ProgressReport {
                        phase: if reasoning_deltas > 0 { Phase::Thinking } else { Phase::Generating },
                        reasoning_deltas,
                        elapsed_ms: elapsed_ms(started),
                        round,
                    })).await?;
                }
            }
            // Backstop. A well-behaved ModelSurface stops its own job and
            // returns ModelError::Cancelled; this covers one that does not, so
            // "stop" is never worse than one round late.
            () = cancel.cancelled() => return Err(LoopError::Cancelled),
        }
    };
    while let Ok(delta) = receiver.try_recv() {
        if delta.kind == DeltaKind::Content {
            for text in gate.push(&delta.text) {
                emit(sink, HarnessEvent::Token { text }).await?;
            }
        }
    }
    Ok((text, gate, reasoning))
}

fn elapsed_ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
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
            text: result.text.clone(),
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
    use std::time::Duration;

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
            tokens: mpsc::Sender<StreamDelta>,
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
                    let _ = tokens.send(StreamDelta::content(piece)).await;
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

    /// Counts how many times a tool was actually invoked.
    #[derive(Default)]
    struct CountingTools {
        calls: std::sync::atomic::AtomicUsize,
    }

    impl ToolSurface for CountingTools {
        async fn invoke(&self, _name: &str, _args: &Value) -> Result<Budgeted, String> {
            self.calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(Budgeted::verbatim("{}".to_owned()))
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

    /// A plain opening: just the question.
    fn task(text: &str) -> Opening {
        Opening {
            task: text.to_owned(),
            ..Opening::default()
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
            task("what did I do"),
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

    /// The last round is held back for an answer, and the model is told so.
    ///
    /// Printing the final raw tool result as the reply — which is what happened
    /// before — hands the user unsynthesised tool output with no citation, and
    /// slips text that arrived inside a data fence out of it.
    #[tokio::test]
    async fn the_round_cap_reserves_a_round_to_answer_in() {
        let mut script: Vec<&str> = (0..ContextBudget::DEFAULT.max_rounds - 1)
            .map(|_| "TOOL get_now\nARGS {}")
            .collect();
        script.push("FINAL\nAs far as I got: you were reading.");
        let model = ScriptedModel::new(&script, false);
        let tools = EchoTools {
            body: "{\"now_ms\":42}".to_owned(),
        };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();

        assert_eq!(turn.answer, "As far as I got: you were reading.");
        assert!(
            !turn.answer.contains("now_ms"),
            "raw tool output reached the answer: {}",
            turn.answer
        );
        // The model was warned before its last round.
        let prompts = model.seen.lock().unwrap().clone();
        assert!(
            prompts.last().unwrap().contains("No tool calls remain"),
            "{}",
            prompts.last().unwrap()
        );
    }

    /// The reservation is enforced, not merely announced. A model that ignores
    /// it must not have its tool actually run: the turn is going to fail, and
    /// the lookup would be paid for and never read.
    #[tokio::test]
    async fn the_final_round_refuses_to_run_a_tool() {
        let script: Vec<&str> = (0..ContextBudget::DEFAULT.max_rounds)
            .map(|_| "TOOL get_now\nARGS {}")
            .collect();
        let model = ScriptedModel::new(&script, false);
        let tools = CountingTools::default();
        let mut sink = Recorder::default();
        let error = run_turn(&model, &tools, &mut sink, &config(), "system", task("go"))
            .await
            .unwrap_err();

        assert_eq!(error, LoopError::Exhausted);
        assert_eq!(
            tools.calls.load(std::sync::atomic::Ordering::SeqCst),
            ContextBudget::DEFAULT.max_rounds - 1,
            "the last round's tool was executed anyway"
        );
    }

    /// A model that ignores the warning fails the turn instead of having a raw
    /// tool result printed for it.
    #[tokio::test]
    async fn a_turn_that_never_answers_is_exhausted_not_dumped() {
        let script: Vec<&str> = (0..ContextBudget::DEFAULT.max_rounds)
            .map(|_| "TOOL get_now\nARGS {}")
            .collect();
        let model = ScriptedModel::new(&script, false);
        let tools = EchoTools {
            body: "{\"now_ms\":42}".to_owned(),
        };
        let mut sink = Recorder::default();
        let error = run(&model, &tools, &mut sink).await.unwrap_err();
        assert_eq!(error, LoopError::Exhausted);
        let streamed: String = sink
            .events
            .iter()
            .filter_map(|event| match event {
                HarnessEvent::Token { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert!(!streamed.contains("now_ms"), "raw tool output was streamed");
    }

    #[tokio::test]
    async fn a_missing_model_is_distinguishable() {
        struct NoModel;
        impl ModelSurface for NoModel {
            async fn generate(
                &self,
                _request: GenerateRequest<'_>,
                _tokens: mpsc::Sender<StreamDelta>,
            ) -> Result<String, ModelError> {
                Err(ModelError::Missing)
            }
        }
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let error = run_turn(&NoModel, &tools, &mut sink, &config(), "s", task("t"))
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
            task("task"),
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
        let turn = run_turn(&model, &tools, &mut sink, &config, "system", task("task"))
            .await
            .unwrap();

        assert!(!turn.compactions.is_empty(), "nothing was compacted");
        assert!(sink.events.iter().any(|event| matches!(event, HarnessEvent::Compaction(_))));
        assert!(turn.usage.prompt_tokens <= ContextBudget::DEFAULT.window_tokens);
    }

    /// The reason the window has to be a real number: what we send has to fit
    /// inside it.
    ///
    /// Runs a turn whose tool results dwarf the window, at each of the three
    /// tiers a machine actually reports, and checks every prompt that reached
    /// the model against the window the server was told to allocate. Going over
    /// that line is not an error anywhere — Ollama drops the front of the
    /// prompt and answers from what is left — so this assertion is the only
    /// place the failure is visible at all.
    #[tokio::test]
    async fn every_prompt_fits_the_window_it_was_budgeted_for() {
        for window in [4_096, 32_768, 262_144] {
            let budget = ContextBudget::for_window(window);
            let strategy = PruneToolResults;
            let config = LoopConfig {
                budget,
                cancel: CancelToken::new(),
                compaction: Some(&strategy),
            };
            let calls: Vec<&str> = vec![
                "TOOL get_slot_card\nARGS {\"at_ms\":1}",
                "TOOL get_slot_card\nARGS {\"at_ms\":2}",
                "FINAL\ndone",
            ];
            let model = ScriptedModel::new(&calls, false);
            // Far larger than any window here, so the cut has to come from us.
            let tools = EchoTools {
                body: "y".repeat(400_000),
            };
            let mut sink = Recorder::default();
            let turn = run_turn(&model, &tools, &mut sink, &config, "system", task("task"))
                .await
                .unwrap();

            for (round, prompt) in model.seen.lock().unwrap().iter().enumerate() {
                let tokens = estimate_tokens(prompt);
                assert!(
                    tokens + budget.system_tokens + budget.reserve_tokens <= window,
                    "{window} window: round {round} sent {tokens} tokens, \
                     leaving nothing for the system prompt or the answer"
                );
            }
            assert!(
                turn.usage.prompt_tokens <= window,
                "{window} window: reported {} prompt tokens",
                turn.usage.prompt_tokens
            );
        }
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
            task("task"),
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
            task("task"),
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
                task("task"),
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
                _tokens: mpsc::Sender<StreamDelta>,
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
                task("task"),
            ),
        )
        .await
        .expect("the loop waited for a model that ignored the token")
        .unwrap_err();
        assert_eq!(error, LoopError::Cancelled);
    }

    /// Streams reasoning deltas, then an answer — a thinking model's shape.
    struct ThinkingModel {
        reasoning_deltas: usize,
        answer: &'static str,
    }

    impl ModelSurface for ThinkingModel {
        async fn generate(
            &self,
            _request: GenerateRequest<'_>,
            tokens: mpsc::Sender<StreamDelta>,
        ) -> Result<String, ModelError> {
            for index in 0..self.reasoning_deltas {
                let _ = tokens
                    .send(StreamDelta::reasoning(format!("step{index} ")))
                    .await;
                tokio::time::sleep(Duration::from_millis(30)).await;
            }
            let _ = tokens.send(StreamDelta::content(self.answer)).await;
            Ok(self.answer.to_owned())
        }
    }

    fn progress_reports(sink: &Recorder) -> Vec<ProgressReport> {
        sink.events
            .iter()
            .filter_map(|event| match event {
                HarnessEvent::Progress(report) => Some(*report),
                _ => None,
            })
            .collect()
    }

    /// The bug this exists for. `qwen3.6:35b-mlx` sends its whole answer as one
    /// content delta after ~131 reasoning deltas; without a heartbeat the window
    /// is empty for that entire stretch.
    #[tokio::test]
    async fn a_thinking_model_reports_that_it_is_thinking() {
        // Long enough to span several beats past the grace period, so the
        // count is observed actually advancing rather than merely being set.
        let model = ThinkingModel {
            reasoning_deltas: 40,
            answer: "FINAL\nOK",
        };
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let turn = run_turn(
            &model,
            &tools,
            &mut sink,
            &config(),
            "system",
            task("task"),
        )
        .await
        .unwrap();
        assert_eq!(turn.answer, "OK");

        let reports = progress_reports(&sink);
        assert!(!reports.is_empty(), "no heartbeat during the thinking phase");
        assert!(
            reports.iter().any(|report| report.phase == Phase::Thinking),
            "{reports:?}"
        );
        // The proof-of-life numbers have to actually move, or the indicator
        // cannot answer "is it stuck".
        let counts: Vec<usize> = reports.iter().map(|r| r.reasoning_deltas).collect();
        assert!(
            counts.last() > counts.first(),
            "reasoning count never advanced: {counts:?}"
        );
        assert!(reports.iter().all(|report| report.round == 1));
        // Reasoning is never shown, and never reaches the answer.
        let streamed: String = sink
            .events
            .iter()
            .filter_map(|event| match event {
                HarnessEvent::Token { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert!(!streamed.contains("step"), "reasoning leaked: {streamed}");
    }

    /// The general case, which matters more than thinking: a model that has not
    /// produced anything yet. Loading a 22 GB model cold took 12.7 s.
    #[tokio::test]
    async fn a_slow_first_token_reports_before_it_arrives() {
        struct SlowModel;
        impl ModelSurface for SlowModel {
            async fn generate(
                &self,
                _request: GenerateRequest<'_>,
                _tokens: mpsc::Sender<StreamDelta>,
            ) -> Result<String, ModelError> {
                tokio::time::sleep(Duration::from_millis(900)).await;
                Ok("FINAL\nloaded".to_owned())
            }
        }
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        run_turn(&SlowModel, &tools, &mut sink, &config(), "s", task("t"))
            .await
            .unwrap();

        let reports = progress_reports(&sink);
        assert!(reports.len() >= 2, "{reports:?}");
        assert!(
            reports.iter().all(|report| report.phase == Phase::Generating),
            "nothing was streaming, so nothing was thinking: {reports:?}"
        );
        let elapsed: Vec<u64> = reports.iter().map(|r| r.elapsed_ms).collect();
        assert!(
            elapsed.last() > elapsed.first(),
            "elapsed never advanced: {elapsed:?}"
        );
    }

    /// The third stretch, and the one nothing else covers: while a round is
    /// generating a `TOOL` draft the gate hides every delta, and `tool_call`
    /// cannot be emitted until the round has finished and parsed.
    #[tokio::test]
    async fn a_hidden_tool_draft_still_reports() {
        struct SlowToolDraft;
        impl ModelSurface for SlowToolDraft {
            async fn generate(
                &self,
                request: GenerateRequest<'_>,
                tokens: mpsc::Sender<StreamDelta>,
            ) -> Result<String, ModelError> {
                if request.round == 1 {
                    let _ = tokens.send(StreamDelta::content("TOOL get_now")).await;
                    tokio::time::sleep(Duration::from_millis(700)).await;
                    let _ = tokens.send(StreamDelta::content("\nARGS {}")).await;
                    return Ok("TOOL get_now\nARGS {}".to_owned());
                }
                Ok("FINAL\ndone".to_owned())
            }
        }
        let tools = EchoTools {
            body: "{\"now_ms\":1}".to_owned(),
        };
        let mut sink = Recorder::default();
        run_turn(
            &SlowToolDraft,
            &tools,
            &mut sink,
            &config(),
            "s",
            task("t"),
        )
        .await
        .unwrap();

        let first_round: Vec<ProgressReport> = progress_reports(&sink)
            .into_iter()
            .filter(|report| report.round == 1)
            .collect();
        assert!(
            !first_round.is_empty(),
            "the hidden TOOL draft reported nothing"
        );
    }

    /// Once the answer is on screen the text is its own proof of life, and a
    /// second indicator beside it only competes with the caret.
    #[tokio::test]
    async fn the_heartbeat_stops_once_the_answer_is_streaming() {
        struct TalkThenPause;
        impl ModelSurface for TalkThenPause {
            async fn generate(
                &self,
                _request: GenerateRequest<'_>,
                tokens: mpsc::Sender<StreamDelta>,
            ) -> Result<String, ModelError> {
                let _ = tokens.send(StreamDelta::content("FINAL\nhere")).await;
                tokio::time::sleep(Duration::from_millis(900)).await;
                Ok("FINAL\nhere".to_owned())
            }
        }
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        run_turn(
            &TalkThenPause,
            &tools,
            &mut sink,
            &config(),
            "s",
            task("t"),
        )
        .await
        .unwrap();
        assert!(
            progress_reports(&sink).is_empty(),
            "{:?}",
            progress_reports(&sink)
        );
    }

    /// A non-streaming adapter must not be reported as silent forever, nor
    /// flicker: it simply gets heartbeats until its one-shot text lands.
    #[tokio::test]
    async fn a_non_streaming_adapter_still_reports_then_answers() {
        let model = ScriptedModel::new(&["FINAL\nhello"], false);
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();
        assert_eq!(turn.answer, "hello");
        // Faster than one interval, so it must report nothing at all: an
        // indicator that appears for a few milliseconds is a flicker.
        assert!(
            progress_reports(&sink).is_empty(),
            "{:?}",
            progress_reports(&sink)
        );
    }

    /// The end-to-end shape of the parser fix: a model that mangles its first
    /// call is told, tries again, and the turn produces a real answer — instead
    /// of reporting success with nothing in it.
    #[tokio::test]
    async fn a_malformed_call_is_corrected_rather_than_answered() {
        let model = ScriptedModel::new(
            &[
                // Pretty-printed args used to parse as `"{"`.
                "TOOL get_now\nARGS {\n  \"unclosed\": true",
                "TOOL get_now\nARGS {}",
                "FINAL\nIt is Tuesday.",
            ],
            false,
        );
        let tools = EchoTools {
            body: "{\"now_ms\":1}".to_owned(),
        };
        let mut sink = Recorder::default();
        let turn = run(&model, &tools, &mut sink).await.unwrap();

        assert_eq!(turn.answer, "It is Tuesday.");
        // The model was handed its own mistake.
        let prompts = model.seen.lock().unwrap().clone();
        assert!(
            prompts[1].contains("looked like a call to `get_now`"),
            "{}",
            prompts[1]
        );
        assert!(prompts[1].contains("ARGS is not a complete JSON object"));
    }

    /// A model that never gets it right fails the turn loudly rather than
    /// storing a blank answer.
    #[tokio::test]
    async fn a_turn_of_only_malformed_calls_fails() {
        let calls: Vec<&str> = (0..ContextBudget::DEFAULT.max_rounds)
            .map(|_| "TOOL get_now\nARGS {broken")
            .collect();
        let model = ScriptedModel::new(&calls, false);
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let error = run(&model, &tools, &mut sink).await.unwrap_err();
        assert!(
            matches!(error, LoopError::Model(ModelError::Failed(ref m)) if m.contains("never produced")),
            "{error:?}"
        );
    }

    /// An opening larger than the window must be cut before the first round,
    /// the question must survive it, and the cut must be announced.
    #[tokio::test]
    async fn an_oversized_opening_is_trimmed_before_the_first_round() {
        let model = ScriptedModel::new(&["FINAL\nok"], false);
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let strategy = PruneToolResults;
        let config = LoopConfig {
            budget: ContextBudget::DEFAULT,
            cancel: CancelToken::new(),
            compaction: Some(&strategy),
        };
        let huge = Opening {
            seed: "clock".to_owned(),
            history: crate::history::History::from_stored(
                (0..4_000)
                    .map(|index| Message::user(format!("a long folded turn {index}")))
                    .collect(),
            ),
            task: "CURRENT_TASK_SENTINEL".to_owned(),
        };
        let turn = run_turn(&model, &tools, &mut sink, &config, "system", huge)
            .await
            .unwrap();
        let prompt = model.seen.lock().unwrap()[0].clone();
        assert!(
            prompt.contains("CURRENT_TASK_SENTINEL"),
            "the question the user just asked was trimmed away"
        );

        assert!(
            turn.usage.prompt_tokens <= ContextBudget::DEFAULT.window_tokens,
            "round one still exceeded the window: {}",
            turn.usage.prompt_tokens
        );
        assert!(
            sink.events.iter().any(|event| matches!(
                event,
                HarnessEvent::Compaction(notice)
                    if notice.strategy == PruneToolResults::HISTORY_NAME
            )),
            "the conversation was cut without a word: {:?}",
            sink.events
        );
    }

    /// The other half of "only compaction may remove": without a strategy,
    /// nothing does. The prompt then overflows, which is the caller's
    /// declaration that it would fit — and is still better than the renderer
    /// quietly keeping a different subset of the conversation every turn.
    #[tokio::test]
    async fn without_a_strategy_the_conversation_is_left_whole() {
        let model = ScriptedModel::new(&["FINAL\nok"], false);
        let tools = EchoTools { body: String::new() };
        let mut sink = Recorder::default();
        let stored: Vec<Message> = (0..2_000)
            .map(|index| Message::user(format!("turn {index}")))
            .collect();
        let opening = Opening {
            seed: "clock".to_owned(),
            history: crate::history::History::from_stored(stored.clone()),
            task: "and then?".to_owned(),
        };
        run_turn(&model, &tools, &mut sink, &config(), "system", opening)
            .await
            .unwrap();

        let prompt = model.seen.lock().unwrap()[0].clone();
        assert!(prompt.contains("turn 0"), "the oldest turn went silently");
        assert!(prompt.contains("turn 1999"));
        assert!(
            !sink.events.iter().any(|event| matches!(
                event,
                HarnessEvent::Compaction(_)
            )),
            "nothing was configured to compact, so nothing should have"
        );
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
