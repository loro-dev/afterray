use crate::{AdapterError, Cancellation, ModelAdapter, ModelCapability, ModelInput, ModelOutput};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Mutex, Notify, Semaphore};
use uuid::Uuid;

pub type JobId = String;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Pending,
    Running,
    Done,
    Failed,
    Cancelled,
}

impl JobState {
    const fn terminal(self) -> bool {
        matches!(self, Self::Done | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobSnapshot {
    pub id: JobId,
    pub capability: ModelCapability,
    pub adapter: String,
    pub state: JobState,
    pub attempts: u32,
    pub max_attempts: u32,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    /// When the job last entered [`JobState::Running`]. `updated_at_ms` cannot
    /// answer "how long has this been going", because every retry and every
    /// completion moves it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at_ms: Option<i64>,
    pub output: Option<ModelOutput>,
    pub last_error: Option<String>,
}

/// A job executing right now.
#[derive(Debug, Clone)]
pub struct RunningJob {
    pub id: JobId,
    pub capability: ModelCapability,
    pub adapter: String,
    pub started_at_ms: i64,
}

/// What the queue is doing, without the history.
///
/// [`ModelQueue::list`] answers "every job this daemon has seen", which is the
/// wrong question for a live dashboard polling every two seconds.
#[derive(Debug, Clone, Default)]
pub struct QueueActivity {
    pub running: Vec<RunningJob>,
    pub pending: HashMap<ModelCapability, usize>,
}

impl QueueActivity {
    #[must_use]
    pub fn pending_for(&self, capability: ModelCapability) -> usize {
        self.pending.get(&capability).copied().unwrap_or(0)
    }
}

/// Terminal jobs kept for inspection. Enough to explain a recent failure,
/// bounded because nothing else ever removed them: a day of ten-second
/// captures alone leaves ~8600 finished OCR jobs in memory, and every
/// `JobsList` copied all of them.
const TERMINAL_JOB_HISTORY: usize = 200;

/// How long a finished job is kept regardless of the cap, so a `wait` that has
/// been notified but not yet polled always finds its own job.
const TERMINAL_JOB_GRACE_MS: i64 = 60_000;

#[derive(Debug, Clone, Copy)]
pub struct CapabilityConcurrency {
    pub ocr: usize,
    pub asr: usize,
    pub embedding: usize,
    pub llm: usize,
}

impl Default for CapabilityConcurrency {
    fn default() -> Self {
        Self {
            ocr: 1,
            asr: 1,
            embedding: 2,
            llm: 1,
        }
    }
}

impl CapabilityConcurrency {
    const fn for_capability(self, capability: ModelCapability) -> usize {
        match capability {
            ModelCapability::Ocr => self.ocr,
            ModelCapability::Asr => self.asr,
            ModelCapability::Embedding => self.embedding,
            ModelCapability::Llm => self.llm,
        }
    }
}

#[derive(Debug, Clone)]
pub struct QueueConfig {
    pub max_attempts: u32,
    pub retry_delay: Duration,
    pub concurrency: CapabilityConcurrency,
    /// Serialize background local-GPU work across capabilities, so an OCR
    /// pass, a transcription and a background LLM summary never run at the
    /// same time. Only interactive chat bypasses the lane.
    pub gpu_lane: bool,
}

impl Default for QueueConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            retry_delay: Duration::from_secs(2),
            concurrency: CapabilityConcurrency::default(),
            gpu_lane: true,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum QueueError {
    #[error("no model adapter is registered for {0:?}")]
    MissingAdapter(ModelCapability),
    #[error("model concurrency for {0:?} must be at least one")]
    InvalidConcurrency(ModelCapability),
    #[error("model job `{0}` does not exist")]
    MissingJob(String),
    #[error("model job `{0}` is not in a retryable state")]
    NotRetryable(String),
    #[error("model queue is shutting down")]
    ShuttingDown,
}

/// Scheduling class for LLM jobs. Interactive work (a user waiting on a chat
/// reply) must never sit behind a background summariser's 200-second pass.
///
/// `Background { lease }` carries an optional lease id: an agent loop's
/// rounds are separate queue jobs, and without the lease every round
/// re-queues behind whatever other background work arrived meanwhile — the
/// 8-minute waits measured on 2026-08-15 were exactly that.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum JobPriority {
    #[default]
    Interactive,
    Background {
        lease: Option<u64>,
    },
}

struct JobRecord {
    snapshot: JobSnapshot,
    input: ModelInput,
    cancellation: Cancellation,
    generation: u64,
    priority: JobPriority,
}

/// Priority admission for the LLM lane. Not a semaphore: release picks the
/// best waiter by (class, arrival), where class is
///   0 — interactive,
///   1 — background continuing the sticky lease,
///   2 — other background.
/// The lease is sticky rather than explicitly held: for a short window after
/// a leased job finishes, the same lease outranks other background work, so
/// an agent loop's next round goes first without an API that could leak a
/// lock if a loop dies mid-flight.
struct LlmGate {
    state: std::sync::Mutex<GateState>,
}

struct GateState {
    free: usize,
    next_seq: u64,
    waiters: Vec<GateWaiter>,
    /// Lease ids currently held open by a live agent loop. While any hold is
    /// active, plain background work is not admitted — the slot is reserved
    /// for interactive work and for the loops that hold it.
    holds: Vec<u64>,
}

struct GateWaiter {
    interactive: bool,
    lease: Option<u64>,
    seq: u64,
    admit: tokio::sync::oneshot::Sender<()>,
}

impl LlmGate {
    fn new(permits: usize) -> Self {
        Self {
            state: std::sync::Mutex::new(GateState {
                free: permits,
                next_seq: 0,
                waiters: Vec::new(),
                holds: Vec::new(),
            }),
        }
    }

    /// Whether a waiter of this shape may take a slot right now.
    fn admissible(state: &GateState, interactive: bool, lease: Option<u64>) -> bool {
        interactive || state.holds.is_empty() || lease.is_some_and(|id| state.holds.contains(&id))
    }

    async fn acquire(&self, priority: JobPriority) {
        let (interactive, lease) = match priority {
            JobPriority::Interactive => (true, None),
            JobPriority::Background { lease } => (false, lease),
        };
        let admitted = {
            let mut state = self.state.lock().unwrap();
            if state.free > 0
                && state.waiters.is_empty()
                && Self::admissible(&state, interactive, lease)
            {
                state.free -= 1;
                None // admitted immediately
            } else {
                let (tx, rx) = tokio::sync::oneshot::channel();
                let seq = state.next_seq;
                state.next_seq += 1;
                state.waiters.push(GateWaiter {
                    interactive,
                    lease,
                    seq,
                    admit: tx,
                });
                // The slot can be free even with waiters parked: a hold may
                // have kept plain background out while nothing admissible was
                // queued. A newly admissible arrival must trigger a hand-over
                // now — no later event will.
                if state.free > 0 {
                    state.free -= 1;
                    Self::hand_over(&mut state, true);
                }
                Some(rx)
            }
        };
        if let Some(rx) = admitted {
            // A dropped sender only happens on queue teardown; treat as admit
            // so shutdown never deadlocks a waiter.
            let _ = rx.await;
        }
    }

    fn release(&self) {
        let mut state = self.state.lock().unwrap();
        Self::hand_over(&mut state, true);
    }

    fn add_hold(&self, lease: u64) {
        self.state.lock().unwrap().holds.push(lease);
    }

    fn remove_hold(&self, lease: u64) {
        let mut state = self.state.lock().unwrap();
        if let Some(index) = state.holds.iter().position(|held| *held == lease) {
            state.holds.swap_remove(index);
        }
        // A slot may have been left free for this hold; offer it to whoever
        // is now admissible.
        if state.free > 0 {
            state.free -= 1;
            Self::hand_over(&mut state, true);
        }
    }

    /// Hands one slot to the best admissible waiter, or banks it as free.
    /// `slot_in_hand` is always true today; named for readability at calls.
    fn hand_over(state: &mut GateState, slot_in_hand: bool) {
        debug_assert!(slot_in_hand);
        loop {
            let best = state
                .waiters
                .iter()
                .enumerate()
                .filter(|(_, waiter)| Self::admissible(state, waiter.interactive, waiter.lease))
                .min_by_key(|(_, waiter)| {
                    let class: u8 = if waiter.interactive { 0 } else { 1 };
                    (class, waiter.seq)
                })
                .map(|(index, _)| index);
            let Some(index) = best else {
                state.free += 1;
                return;
            };
            let waiter = state.waiters.swap_remove(index);
            if waiter.admit.send(()).is_ok() {
                return; // slot handed over
            }
            // Waiter was cancelled while queued; pick the next one.
        }
    }
}

/// RAII reservation of the LLM lane for one agent loop. While alive, plain
/// background jobs are not admitted; the loop's own rounds (submitted with
/// this lease) and all interactive work are. Dropping — on any path,
/// including errors — reopens the lane.
pub struct LlmLeaseHold {
    inner: Arc<QueueInner>,
    lease: u64,
}

impl LlmLeaseHold {
    #[must_use]
    pub const fn id(&self) -> u64 {
        self.lease
    }
}

impl Drop for LlmLeaseHold {
    fn drop(&mut self) {
        self.inner.llm_gate.remove_hold(self.lease);
        self.inner.gpu_gate.remove_hold(self.lease);
    }
}

/// Scheduling class for the GPU lane. OCR is on the capture critical path —
/// short, and a frame that goes un-OCR'd is never indexed later — so it jumps
/// ahead of background work whose backlog is durable (audio rows, vault
/// counts). Within a class, admission is FIFO.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum GpuClass {
    Ocr,
    Background,
}

// @dec:gpu-lane-serialization — docs/decisions/active/architecture/2026-08-24-gpu-lane-serialization.md
/// Priority admission for the local-GPU lane: one permit, so at most one
/// background GPU job runs at a time across all capabilities. Same shape as
/// [`LlmGate`], holds included: while an LLM lease hold is active, plain
/// background work is not admitted — the slot is reserved for OCR and for
/// the rounds of the loop that holds the lease. That mirror is what lets a
/// leased background pass (the T2 summariser) ride the lane without
/// deadlocking against a plain background job the same hold keeps out of
/// the LLM gate: a waiter the holds exclude parks here holding nothing.
struct GpuGate {
    state: std::sync::Mutex<GpuGateState>,
}

struct GpuGateState {
    free: usize,
    next_seq: u64,
    waiters: Vec<GpuGateWaiter>,
    /// Lease ids held open by a live multi-round loop (the T2 summariser).
    /// Mirrored from `LlmGate` by `ModelQueue::hold_llm_lease`.
    holds: Vec<u64>,
}

struct GpuGateWaiter {
    class: GpuClass,
    lease: Option<u64>,
    seq: u64,
    admit: tokio::sync::oneshot::Sender<()>,
}

impl GpuGate {
    fn new() -> Self {
        Self {
            state: std::sync::Mutex::new(GpuGateState {
                free: 1,
                next_seq: 0,
                waiters: Vec::new(),
                holds: Vec::new(),
            }),
        }
    }

    /// Whether a waiter of this shape may take the slot right now. OCR is
    /// always admissible; background work only while no LLM lease hold is
    /// active, or when it is a round of the loop holding one.
    fn admissible(state: &GpuGateState, class: GpuClass, lease: Option<u64>) -> bool {
        class == GpuClass::Ocr
            || state.holds.is_empty()
            || lease.is_some_and(|id| state.holds.contains(&id))
    }

    async fn acquire(&self, class: GpuClass, lease: Option<u64>) {
        let waiting = {
            let mut state = self.state.lock().unwrap();
            if state.free > 0
                && state.waiters.is_empty()
                && Self::admissible(&state, class, lease)
            {
                state.free -= 1;
                None
            } else {
                let (tx, rx) = tokio::sync::oneshot::channel();
                let seq = state.next_seq;
                state.next_seq += 1;
                state.waiters.push(GpuGateWaiter {
                    class,
                    lease,
                    seq,
                    admit: tx,
                });
                // The slot can be free even with waiters parked: a hold may
                // have kept plain background out while nothing admissible was
                // queued. A newly admissible arrival must trigger a hand-over
                // now — no later event will.
                if state.free > 0 {
                    state.free -= 1;
                    Self::hand_over(&mut state);
                }
                Some(rx)
            }
        };
        if let Some(rx) = waiting {
            // A dropped sender only happens on queue teardown; treat as admit
            // so shutdown never deadlocks a waiter.
            let _ = rx.await;
        }
    }

    fn release(&self) {
        let mut state = self.state.lock().unwrap();
        Self::hand_over(&mut state);
    }

    fn add_hold(&self, lease: u64) {
        self.state.lock().unwrap().holds.push(lease);
    }

    fn remove_hold(&self, lease: u64) {
        let mut state = self.state.lock().unwrap();
        if let Some(index) = state.holds.iter().position(|held| *held == lease) {
            state.holds.swap_remove(index);
        }
        // A slot may have been left free for this hold; offer it to whoever
        // is now admissible.
        if state.free > 0 {
            state.free -= 1;
            Self::hand_over(&mut state);
        }
    }

    /// Hands one slot to the best admissible waiter, or banks it as free.
    fn hand_over(state: &mut GpuGateState) {
        loop {
            let best = state
                .waiters
                .iter()
                .enumerate()
                .filter(|(_, waiter)| Self::admissible(state, waiter.class, waiter.lease))
                .min_by_key(|(_, waiter)| (waiter.class, waiter.seq))
                .map(|(index, _)| index);
            let Some(index) = best else {
                state.free += 1;
                return;
            };
            let waiter = state.waiters.swap_remove(index);
            if waiter.admit.send(()).is_ok() {
                return; // slot handed over
            }
            // Waiter was cancelled while queued; pick the next one.
        }
    }
}

struct QueueInner {
    adapters: HashMap<ModelCapability, Arc<dyn ModelAdapter>>,
    semaphores: HashMap<ModelCapability, Arc<Semaphore>>,
    /// Priority admission, LLM only: the one capability where an interactive
    /// user and a multi-minute background pass share a single slot.
    llm_gate: LlmGate,
    /// Cross-capability admission for background local-GPU work.
    gpu_gate: GpuGate,
    lease_counter: std::sync::atomic::AtomicU64,
    jobs: Mutex<HashMap<JobId, JobRecord>>,
    changed: Notify,
    config: QueueConfig,
    draining: AtomicBool,
}

#[derive(Clone)]
pub struct ModelQueue {
    inner: Arc<QueueInner>,
}

impl ModelQueue {
    /// Creates a model queue with at most one adapter per capability.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::InvalidConcurrency`] when any capability is
    /// configured with zero execution slots.
    pub fn new(
        adapters: impl IntoIterator<Item = Arc<dyn ModelAdapter>>,
        config: QueueConfig,
    ) -> Result<Self, QueueError> {
        let mut by_capability = HashMap::new();
        for adapter in adapters {
            by_capability.insert(adapter.capability(), adapter);
        }

        let mut semaphores = HashMap::new();
        for capability in [
            ModelCapability::Ocr,
            ModelCapability::Asr,
            ModelCapability::Embedding,
            ModelCapability::Llm,
        ] {
            let count = config.concurrency.for_capability(capability);
            if count == 0 {
                return Err(QueueError::InvalidConcurrency(capability));
            }
            semaphores.insert(capability, Arc::new(Semaphore::new(count)));
        }

        let llm_permits = config.concurrency.llm;
        Ok(Self {
            inner: Arc::new(QueueInner {
                adapters: by_capability,
                semaphores,
                llm_gate: LlmGate::new(llm_permits),
                gpu_gate: GpuGate::new(),
                lease_counter: std::sync::atomic::AtomicU64::new(1),
                jobs: Mutex::new(HashMap::new()),
                changed: Notify::new(),
                config,
                draining: AtomicBool::new(false),
            }),
        })
    }

    /// Reserves the LLM lane for one background agent loop. Submit every
    /// round with `JobPriority::Background {{ lease: Some(hold.id()) }}`; the
    /// reservation dies with the returned guard.
    #[must_use]
    pub fn hold_llm_lease(&self) -> LlmLeaseHold {
        let lease = self
            .inner
            .lease_counter
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.inner.llm_gate.add_hold(lease);
        // Mirrored at the GPU lane: the loop's rounds keep their priority
        // there too, and a plain background job the hold excludes parks at
        // the lane holding nothing — never a permit the loop needs.
        self.inner.gpu_gate.add_hold(lease);
        LlmLeaseHold {
            inner: Arc::clone(&self.inner),
            lease,
        }
    }

    /// The adapter serving a capability, for callers that need to ask it
    /// something the queue does not model — currently only the worker pid
    /// behind a running job.
    #[must_use]
    pub fn adapter_for(&self, capability: ModelCapability) -> Option<Arc<dyn ModelAdapter>> {
        self.inner.adapters.get(&capability).map(Arc::clone)
    }

    #[must_use]
    pub fn ocr_in_flight(&self) -> bool {
        self.inner
            .semaphores
            .get(&ModelCapability::Ocr)
            .is_some_and(|semaphore| semaphore.available_permits() == 0)
    }

    /// Enqueues a typed inference job and starts processing it in the background.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingAdapter`] when no adapter handles the input.
    pub async fn submit(&self, input: ModelInput) -> Result<JobId, QueueError> {
        self.submit_with(input, JobPriority::Interactive).await
    }

    /// Enqueues with an explicit scheduling class. Background callers — the
    /// T2 sweeper, backfills — must say so; the default protects the user.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingAdapter`] when no adapter handles the input.
    pub async fn submit_with(
        &self,
        input: ModelInput,
        priority: JobPriority,
    ) -> Result<JobId, QueueError> {
        self.submit_prepared(input, priority, |_| {}).await
    }

    /// Submits a job, running `prepare` with its id **before** it can start.
    ///
    /// The one thing a caller cannot do from outside is act on a job id that
    /// does not exist yet. Arming a token outlet after `submit_with` returned
    /// is a race: the lane may be idle, the task already spawned, and the
    /// adapter past the point where it looks for an outlet — so the round
    /// silently does not stream. `prepare` closes that gap by running while the
    /// job is still pending.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingAdapter`] when nothing serves the input's
    /// capability.
    pub async fn submit_prepared(
        &self,
        input: ModelInput,
        priority: JobPriority,
        prepare: impl FnOnce(&str),
    ) -> Result<JobId, QueueError> {
        if self.inner.draining.load(Ordering::Acquire) {
            return Err(QueueError::ShuttingDown);
        }
        let capability = input.capability();
        let adapter = self
            .inner
            .adapters
            .get(&capability)
            .ok_or(QueueError::MissingAdapter(capability))?;
        let id = Uuid::now_v7().to_string();
        let now = unix_time_ms();
        let record = JobRecord {
            snapshot: JobSnapshot {
                id: id.clone(),
                capability,
                adapter: adapter.name().to_owned(),
                state: JobState::Pending,
                attempts: 0,
                max_attempts: self.inner.config.max_attempts.max(1),
                created_at_ms: now,
                updated_at_ms: now,
                started_at_ms: None,
                output: None,
                last_error: None,
            },
            input,
            cancellation: Cancellation::default(),
            generation: 0,
            priority,
        };
        let mut jobs = self.inner.jobs.lock().await;
        if self.inner.draining.load(Ordering::Acquire) {
            return Err(QueueError::ShuttingDown);
        }
        jobs.insert(id.clone(), record);
        drop(jobs);
        // Before the attempt is spawned, so an outlet armed here cannot be
        // missed by an adapter that starts immediately.
        prepare(&id);
        self.inner.changed.notify_waiters();
        spawn_attempt(Arc::clone(&self.inner), id.clone(), 0);
        Ok(id)
    }

    /// Reads the current immutable job snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown.
    pub async fn get(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        self.inner
            .jobs
            .lock()
            .await
            .get(id)
            .map(|record| record.snapshot.clone())
            .ok_or_else(|| QueueError::MissingJob(id.to_owned()))
    }

    /// What is running and what is waiting, per capability.
    ///
    /// Cheap by design: the dashboard polls this every couple of seconds, and
    /// it neither clones model outputs nor walks finished history.
    pub async fn activity(&self) -> QueueActivity {
        let jobs = self.inner.jobs.lock().await;
        let mut activity = QueueActivity::default();
        for record in jobs.values() {
            match record.snapshot.state {
                JobState::Running => activity.running.push(RunningJob {
                    id: record.snapshot.id.clone(),
                    capability: record.snapshot.capability,
                    adapter: record.snapshot.adapter.clone(),
                    started_at_ms: record
                        .snapshot
                        .started_at_ms
                        .unwrap_or(record.snapshot.updated_at_ms),
                }),
                JobState::Pending => {
                    *activity
                        .pending
                        .entry(record.snapshot.capability)
                        .or_default() += 1;
                }
                JobState::Done | JobState::Failed | JobState::Cancelled => {}
            }
        }
        drop(jobs);
        activity
            .running
            .sort_unstable_by_key(|job| job.started_at_ms);
        activity
    }

    pub async fn list(&self) -> Vec<JobSnapshot> {
        let mut jobs: Vec<_> = self
            .inner
            .jobs
            .lock()
            .await
            .values()
            .map(|record| record.snapshot.clone())
            .collect();
        jobs.sort_by_key(|job| job.created_at_ms);
        jobs
    }

    /// Waits until a job reaches a terminal state.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown.
    pub async fn wait(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        loop {
            let changed = self.inner.changed.notified();
            let snapshot = self.get(id).await?;
            if snapshot.state.terminal() {
                return Ok(snapshot);
            }
            changed.await;
        }
    }

    /// Cancels pending slot acquisition or a running adapter process.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown.
    pub async fn cancel(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        let mut jobs = self.inner.jobs.lock().await;
        let record = jobs
            .get_mut(id)
            .ok_or_else(|| QueueError::MissingJob(id.to_owned()))?;
        if !record.snapshot.state.terminal() {
            record.cancellation.cancel();
            record.generation = record.generation.wrapping_add(1);
            record.snapshot.state = JobState::Cancelled;
            record.snapshot.updated_at_ms = unix_time_ms();
            record.snapshot.last_error = Some("cancelled by caller".to_owned());
        }
        let snapshot = record.snapshot.clone();
        drop(jobs);
        self.inner.changed.notify_waiters();
        Ok(snapshot)
    }

    // @dec:bounded-shutdown — docs/decisions/active/architecture/2026-08-20-bounded-shutdown.md
    /// Stops admission and cooperatively cancels every pending/running worker.
    /// Terminal history stays available for the final diagnostic snapshot.
    pub async fn shutdown(&self) -> usize {
        self.inner.draining.store(true, Ordering::Release);
        let mut cancelled = 0;
        let mut jobs = self.inner.jobs.lock().await;
        for record in jobs.values_mut() {
            if record.snapshot.state.terminal() {
                continue;
            }
            record.cancellation.cancel();
            record.generation = record.generation.wrapping_add(1);
            record.snapshot.state = JobState::Cancelled;
            record.snapshot.updated_at_ms = unix_time_ms();
            record.snapshot.last_error = Some("cancelled during daemon shutdown".to_owned());
            cancelled += 1;
        }
        drop(jobs);
        self.inner.changed.notify_waiters();
        cancelled
    }

    /// Restarts a failed or cancelled job with a fresh retry budget.
    ///
    /// # Errors
    ///
    /// Returns [`QueueError::MissingJob`] when `id` is unknown, or
    /// [`QueueError::NotRetryable`] when it has not failed or been cancelled.
    /// Returns [`QueueError::ShuttingDown`] after queue draining begins.
    pub async fn retry(&self, id: &str) -> Result<JobSnapshot, QueueError> {
        self.retry_with_pre_lock_hook(id, || {}).await
    }

    async fn retry_with_pre_lock_hook(
        &self,
        id: &str,
        before_lock: impl FnOnce(),
    ) -> Result<JobSnapshot, QueueError> {
        if self.inner.draining.load(Ordering::Acquire) {
            return Err(QueueError::ShuttingDown);
        }
        before_lock();
        let generation;
        let snapshot;
        {
            let mut jobs = self.inner.jobs.lock().await;
            // Shutdown sets `draining` before taking this lock. A retry that
            // passed the optimistic check and then queued behind shutdown must
            // not turn a Cancelled job back into live model work.
            if self.inner.draining.load(Ordering::Acquire) {
                return Err(QueueError::ShuttingDown);
            }
            let record = jobs
                .get_mut(id)
                .ok_or_else(|| QueueError::MissingJob(id.to_owned()))?;
            if !matches!(
                record.snapshot.state,
                JobState::Failed | JobState::Cancelled
            ) {
                return Err(QueueError::NotRetryable(id.to_owned()));
            }
            record.cancellation.cancel();
            record.cancellation = Cancellation::default();
            record.generation = record.generation.wrapping_add(1);
            generation = record.generation;
            record.snapshot.state = JobState::Pending;
            record.snapshot.attempts = 0;
            record.snapshot.updated_at_ms = unix_time_ms();
            record.snapshot.output = None;
            record.snapshot.last_error = None;
            snapshot = record.snapshot.clone();
        }
        self.inner.changed.notify_waiters();
        spawn_attempt(Arc::clone(&self.inner), id.to_owned(), generation);
        Ok(snapshot)
    }
}

fn spawn_attempt(inner: Arc<QueueInner>, id: JobId, generation: u64) {
    tokio::spawn(async move {
        run_attempts(&inner, &id, generation).await;
    });
}

async fn run_attempts(inner: &Arc<QueueInner>, id: &str, generation: u64) {
    loop {
        let Some((input, capability, cancellation, attempt, max_attempts, priority)) =
            prepare_attempt(inner, id, generation).await
        else {
            return;
        };
        let Some(adapter) = inner.adapters.get(&capability).cloned() else {
            finish_failed(inner, id, generation, "adapter disappeared".to_owned()).await;
            return;
        };
        let Some(semaphore) = inner.semaphores.get(&capability).cloned() else {
            finish_failed(
                inner,
                id,
                generation,
                "concurrency slot disappeared".to_owned(),
            )
            .await;
            return;
        };

        // The GPU lane is taken *before* the capability slot: a background
        // LLM pass queued behind a transcription must not hold the LLM lane
        // hostage while it waits — interactive chat would be stuck behind it.
        // With one GPU permit, the capability slot of whoever holds the lane
        // is always free, so this ordering cannot deadlock.
        let gpu_acquired = match acquire_gpu_lane(
            inner,
            capability,
            priority,
            adapter.as_ref(),
            &input,
            &cancellation,
        )
        .await
        {
            GpuLaneOutcome::Cancelled => return,
            GpuLaneOutcome::NotNeeded => false,
            GpuLaneOutcome::Acquired => true,
        };

        let (llm_admitted, permit) = match acquire_capability_slot(
            inner,
            id,
            generation,
            capability,
            priority,
            semaphore,
            &cancellation,
        )
        .await
        {
            SlotOutcome::Acquired {
                llm_admitted,
                permit,
            } => (llm_admitted, permit),
            SlotOutcome::Cancelled | SlotOutcome::ShuttingDown => {
                if gpu_acquired {
                    inner.gpu_gate.release();
                }
                return;
            }
        };
        if !set_running(inner, id, generation).await {
            if llm_admitted {
                inner.llm_gate.release();
            }
            if gpu_acquired {
                inner.gpu_gate.release();
            }
            return;
        }
        let result = adapter.execute(id, &input, cancellation.clone()).await;
        drop(permit);
        if llm_admitted {
            inner.llm_gate.release();
        }
        if gpu_acquired {
            inner.gpu_gate.release();
        }

        match result {
            Ok(output) => {
                finish_done(inner, id, generation, output).await;
                return;
            }
            Err(AdapterError::Cancelled) => return,
            Err(error) if error.retryable() && attempt < max_attempts => {
                if !set_pending_error(inner, id, generation, error.to_string()).await {
                    return;
                }
                tokio::select! {
                    () = cancellation.cancelled() => return,
                    () = tokio::time::sleep(inner.config.retry_delay) => {}
                }
            }
            Err(error) => {
                finish_failed(inner, id, generation, error.to_string()).await;
                return;
            }
        }
    }
}

enum GpuLaneOutcome {
    Cancelled,
    NotNeeded,
    Acquired,
}

enum SlotOutcome {
    Cancelled,
    ShuttingDown,
    Acquired {
        llm_admitted: bool,
        permit: Option<tokio::sync::OwnedSemaphorePermit>,
    },
}

/// Takes the capability slot: priority admission for the LLM lane, the plain
/// FIFO semaphore everywhere else — OCR frames and embeddings are short and
/// homogeneous, ordering games would buy nothing there.
async fn acquire_capability_slot(
    inner: &Arc<QueueInner>,
    id: &str,
    generation: u64,
    capability: ModelCapability,
    priority: JobPriority,
    semaphore: Arc<Semaphore>,
    cancellation: &Cancellation,
) -> SlotOutcome {
    if capability == ModelCapability::Llm {
        tokio::select! {
            () = cancellation.cancelled() => SlotOutcome::Cancelled,
            () = inner.llm_gate.acquire(priority) => {
                SlotOutcome::Acquired { llm_admitted: true, permit: None }
            }
        }
    } else {
        tokio::select! {
            () = cancellation.cancelled() => SlotOutcome::Cancelled,
            result = semaphore.acquire_owned() => {
                if let Ok(permit) = result {
                    SlotOutcome::Acquired { llm_admitted: false, permit: Some(permit) }
                } else {
                    finish_failed(inner, id, generation, "model queue is shutting down".to_owned()).await;
                    SlotOutcome::ShuttingDown
                }
            }
        }
    }
}

/// Takes the GPU lane for this attempt when it needs one.
async fn acquire_gpu_lane(
    inner: &Arc<QueueInner>,
    capability: ModelCapability,
    priority: JobPriority,
    adapter: &dyn ModelAdapter,
    input: &ModelInput,
    cancellation: &Cancellation,
) -> GpuLaneOutcome {
    let Some(class) = gpu_lane_class(inner, capability, priority, adapter, input) else {
        return GpuLaneOutcome::NotNeeded;
    };
    let lease = match priority {
        JobPriority::Background { lease } => lease,
        JobPriority::Interactive => None,
    };
    // Biased: a completed admission wins the tie against cancellation. Losing
    // that race would strand the one GPU permit — the waiter is already
    // admitted and nothing would release it. Winning it is safe: `cancel`
    // marks the job Cancelled, `set_running` in the caller fails, and the
    // permit is released there.
    tokio::select! {
        biased;
        () = inner.gpu_gate.acquire(class, lease) => GpuLaneOutcome::Acquired,
        () = cancellation.cancelled() => GpuLaneOutcome::Cancelled,
    }
}

/// Whether this attempt must hold the GPU lane, and in which class.
///
/// OCR always rides the lane in its own class: it is on the capture critical
/// path and a skipped frame is never indexed later. ASR, embeddings and all
/// background LLM work share the background class — their backlogs are
/// durable, so waiting costs latency, never data. Only interactive chat
/// bypasses the lane; leased background rounds (the T2 summariser's real
/// shape) ride it, kept deadlock-free by the gate's hold-aware admission.
/// Remote endpoints bypass it too.
fn gpu_lane_class(
    inner: &QueueInner,
    capability: ModelCapability,
    priority: JobPriority,
    adapter: &dyn ModelAdapter,
    input: &ModelInput,
) -> Option<GpuClass> {
    if !inner.config.gpu_lane || !adapter.uses_local_gpu(input) {
        return None;
    }
    match capability {
        ModelCapability::Ocr => Some(GpuClass::Ocr),
        ModelCapability::Asr | ModelCapability::Embedding => Some(GpuClass::Background),
        ModelCapability::Llm => match priority {
            JobPriority::Interactive => None,
            JobPriority::Background { .. } => Some(GpuClass::Background),
        },
    }
}

async fn prepare_attempt(
    inner: &QueueInner,
    id: &str,
    generation: u64,
) -> Option<(
    ModelInput,
    ModelCapability,
    Cancellation,
    u32,
    u32,
    JobPriority,
)> {
    let mut jobs = inner.jobs.lock().await;
    let record = jobs.get_mut(id)?;
    if record.generation != generation || record.snapshot.state != JobState::Pending {
        return None;
    }
    record.snapshot.attempts += 1;
    record.snapshot.updated_at_ms = unix_time_ms();
    let value = (
        record.input.clone(),
        record.snapshot.capability,
        record.cancellation.clone(),
        record.snapshot.attempts,
        record.snapshot.max_attempts,
        record.priority,
    );
    drop(jobs);
    inner.changed.notify_waiters();
    Some(value)
}

async fn set_running(inner: &QueueInner, id: &str, generation: u64) -> bool {
    update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Running;
        snapshot.started_at_ms = Some(unix_time_ms());
    })
    .await
}

async fn set_pending_error(inner: &QueueInner, id: &str, generation: u64, error: String) -> bool {
    update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Pending;
        snapshot.last_error = Some(error);
    })
    .await
}

async fn finish_done(inner: &QueueInner, id: &str, generation: u64, output: ModelOutput) {
    let summary = output_summary(&output);
    let logged = update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Done;
        snapshot.output = Some(output);
        snapshot.last_error = None;
    })
    .await;
    if logged {
        eprintln!("model job {id} done ({summary})");
    }
}

async fn finish_failed(inner: &QueueInner, id: &str, generation: u64, error: String) {
    let logged = update_job(inner, id, generation, |snapshot| {
        snapshot.state = JobState::Failed;
        snapshot.last_error = Some(error.clone());
    })
    .await;
    if logged {
        eprintln!("model job {id} failed: {error}");
    }
}

fn output_summary(output: &ModelOutput) -> String {
    match output {
        ModelOutput::Ocr { text, regions } => {
            format!(
                "ocr, {} chars, {} regions",
                text.chars().count(),
                regions.len()
            )
        }
        ModelOutput::Asr { text, language } => match language {
            Some(language) if !language.is_empty() => {
                format!("asr/{language}, {} chars", text.chars().count())
            }
            _ => format!("asr, {} chars", text.chars().count()),
        },
        ModelOutput::Alignment { cues } => format!("alignment, {} cues", cues.len()),
        ModelOutput::Embedding { vector } => format!("embedding, {} dims", vector.len()),
        ModelOutput::Llm { text, .. } => format!("llm, {} chars", text.chars().count()),
    }
}

async fn update_job(
    inner: &QueueInner,
    id: &str,
    generation: u64,
    update: impl FnOnce(&mut JobSnapshot),
) -> bool {
    let mut jobs = inner.jobs.lock().await;
    let Some(record) = jobs.get_mut(id) else {
        return false;
    };
    if record.generation != generation || record.snapshot.state == JobState::Cancelled {
        return false;
    }
    update(&mut record.snapshot);
    record.snapshot.updated_at_ms = unix_time_ms();
    if record.snapshot.state.terminal() {
        prune_terminal(&mut jobs);
    }
    drop(jobs);
    inner.changed.notify_waiters();
    true
}

/// Drops the oldest finished jobs once there are more than the cap, leaving
/// anything that finished within the grace window alone.
///
/// The grace window is what keeps this safe next to [`ModelQueue::wait`]: a
/// waiter is woken by `changed` and then re-reads its job by id, so a job
/// pruned in that gap would surface as `MissingJob` — a completed inference
/// reported as a lost one.
fn prune_terminal(jobs: &mut HashMap<JobId, JobRecord>) {
    let now = unix_time_ms();
    let mut finished: Vec<(i64, JobId)> = jobs
        .values()
        .filter(|record| record.snapshot.state.terminal())
        .filter(|record| now.saturating_sub(record.snapshot.updated_at_ms) > TERMINAL_JOB_GRACE_MS)
        .map(|record| (record.snapshot.updated_at_ms, record.snapshot.id.clone()))
        .collect();
    if finished.len() <= TERMINAL_JOB_HISTORY {
        return;
    }
    // Newest first, then drop everything past the cap.
    finished.sort_unstable_by(|left, right| right.0.cmp(&left.0));
    for (_, id) in finished.into_iter().skip(TERMINAL_JOB_HISTORY) {
        jobs.remove(&id);
    }
}

fn unix_time_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// LLM-lane adapter that records completion order, for gate tests.
    struct OrderedLlmAdapter {
        order: std::sync::Mutex<Vec<String>>,
        delay: Duration,
    }

    #[async_trait]
    impl ModelAdapter for OrderedLlmAdapter {
        fn capability(&self) -> ModelCapability {
            ModelCapability::Llm
        }

        fn name(&self) -> &'static str {
            "ordered-llm"
        }

        async fn execute(
            &self,
            _job_id: &str,
            input: &ModelInput,
            _cancellation: Cancellation,
        ) -> Result<ModelOutput, AdapterError> {
            tokio::time::sleep(self.delay).await;
            let ModelInput::Llm { prompt, .. } = input else {
                return Err(AdapterError::Process("wrong input".into()));
            };
            self.order.lock().unwrap().push(prompt.clone());
            Ok(ModelOutput::llm(prompt.clone()))
        }
    }

    fn llm_job(label: &str) -> ModelInput {
        ModelInput::Llm {
            messages: Vec::new(),
            prompt: label.to_owned(),
            system: None,
            temperature: None,
        }
    }

    /// The reason the gate exists: with one LLM slot occupied by background
    /// work, an interactive job must run before background jobs that were
    /// queued ahead of it.
    #[tokio::test]
    async fn interactive_overtakes_queued_background_work() {
        let adapter = Arc::new(OrderedLlmAdapter {
            order: std::sync::Mutex::new(Vec::new()),
            delay: Duration::from_millis(30),
        });
        let queue = ModelQueue::new(
            vec![Arc::clone(&adapter) as Arc<dyn ModelAdapter>],
            QueueConfig::default(),
        )
        .unwrap();

        let background = JobPriority::Background { lease: None };
        let first = queue
            .submit_with(llm_job("bg-running"), background)
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await; // let it start
        let second = queue
            .submit_with(llm_job("bg-queued"), background)
            .await
            .unwrap();
        let urgent = queue
            .submit_with(llm_job("interactive"), JobPriority::Interactive)
            .await
            .unwrap();

        for id in [&first, &second, &urgent] {
            queue.wait(id).await.unwrap();
        }
        let order = adapter.order.lock().unwrap().clone();
        assert_eq!(
            order,
            vec!["bg-running", "interactive", "bg-queued"],
            "interactive must overtake queued background work"
        );
    }

    /// The gap the hold closes: between an agent loop's rounds the slot is
    /// briefly free, and the next round has not been submitted yet. A queued
    /// rival must not slip in during that gap — but interactive work must.
    #[tokio::test]
    async fn lease_hold_reserves_the_gap_between_rounds() {
        let adapter = Arc::new(OrderedLlmAdapter {
            order: std::sync::Mutex::new(Vec::new()),
            delay: Duration::from_millis(30),
        });
        let queue = ModelQueue::new(
            vec![Arc::clone(&adapter) as Arc<dyn ModelAdapter>],
            QueueConfig::default(),
        )
        .unwrap();

        let hold = queue.hold_llm_lease();
        let leased = JobPriority::Background {
            lease: Some(hold.id()),
        };
        let plain = JobPriority::Background { lease: None };

        // Round 1 runs; a rival queues while it is busy.
        let round1 = queue.submit_with(llm_job("round-1"), leased).await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await;
        let rival = queue.submit_with(llm_job("rival"), plain).await.unwrap();
        queue.wait(&round1).await.unwrap();

        // The slot is free now, the loop is "thinking" (running tools);
        // round 2 arrives only after that pause.
        tokio::time::sleep(Duration::from_millis(10)).await;
        let round2 = queue.submit_with(llm_job("round-2"), leased).await.unwrap();
        queue.wait(&round2).await.unwrap();

        // Loop finished: dropping the hold lets the rival in.
        drop(hold);
        queue.wait(&rival).await.unwrap();

        let order = adapter.order.lock().unwrap().clone();
        assert_eq!(
            order,
            vec!["round-1", "round-2", "rival"],
            "the rival slipped into the loop's between-rounds gap"
        );
    }

    /// Interactive work ignores holds entirely — the reservation is against
    /// other background work, never against the user.
    #[tokio::test]
    async fn interactive_ignores_an_active_hold() {
        let adapter = Arc::new(OrderedLlmAdapter {
            order: std::sync::Mutex::new(Vec::new()),
            delay: Duration::from_millis(10),
        });
        let queue = ModelQueue::new(
            vec![Arc::clone(&adapter) as Arc<dyn ModelAdapter>],
            QueueConfig::default(),
        )
        .unwrap();

        let hold = queue.hold_llm_lease();
        let urgent = queue
            .submit_with(llm_job("interactive"), JobPriority::Interactive)
            .await
            .unwrap();
        queue.wait(&urgent).await.unwrap();
        drop(hold);
        assert_eq!(adapter.order.lock().unwrap().clone(), vec!["interactive"]);
    }

    struct TestAdapter {
        failures_left: AtomicUsize,
        running: AtomicUsize,
        peak: AtomicUsize,
        delay: Duration,
    }

    #[async_trait]
    impl ModelAdapter for TestAdapter {
        fn capability(&self) -> ModelCapability {
            ModelCapability::Embedding
        }

        fn name(&self) -> &'static str {
            "test"
        }

        async fn execute(
            &self,
            _job_id: &str,
            _input: &ModelInput,
            cancellation: Cancellation,
        ) -> Result<ModelOutput, AdapterError> {
            let running = self.running.fetch_add(1, Ordering::SeqCst) + 1;
            self.peak.fetch_max(running, Ordering::SeqCst);
            tokio::select! {
                () = cancellation.cancelled() => {
                    self.running.fetch_sub(1, Ordering::SeqCst);
                    return Err(AdapterError::Cancelled);
                }
                () = tokio::time::sleep(self.delay) => {}
            }
            self.running.fetch_sub(1, Ordering::SeqCst);
            if self
                .failures_left
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |value| {
                    value.checked_sub(1)
                })
                .is_ok()
            {
                return Err(AdapterError::Process("transient".to_owned()));
            }
            Ok(ModelOutput::Embedding { vector: vec![1.0] })
        }
    }

    fn queue(adapter: Arc<TestAdapter>, concurrency: usize, max_attempts: u32) -> ModelQueue {
        ModelQueue::new(
            vec![adapter as Arc<dyn ModelAdapter>],
            QueueConfig {
                max_attempts,
                retry_delay: Duration::from_millis(1),
                concurrency: CapabilityConcurrency {
                    embedding: concurrency,
                    ..CapabilityConcurrency::default()
                },
                // These tests pin per-capability semaphore semantics; the GPU
                // lane would serialize the very overlap they measure.
                gpu_lane: false,
            },
        )
        .unwrap()
    }

    fn embedding_input() -> ModelInput {
        ModelInput::Embedding {
            text: "hello".to_owned(),
        }
    }

    #[tokio::test]
    async fn shutdown_cancels_active_jobs_and_rejects_new_work() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_secs(30),
        });
        let queue = queue(Arc::clone(&adapter), 1, 1);
        let id = queue.submit(embedding_input()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            while adapter.running.load(Ordering::SeqCst) != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the model job starts");

        assert_eq!(queue.shutdown().await, 1);
        assert_eq!(queue.get(&id).await.unwrap().state, JobState::Cancelled);
        assert!(matches!(
            queue.submit(embedding_input()).await,
            Err(QueueError::ShuttingDown)
        ));
        tokio::time::timeout(Duration::from_secs(1), async {
            while adapter.running.load(Ordering::SeqCst) != 0 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("the adapter observes shutdown cancellation");
    }

    #[tokio::test]
    async fn retry_waiting_on_jobs_lock_is_rejected_once_shutdown_starts() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_secs(30),
        });
        let queue = queue(adapter, 1, 1);
        let id = queue.submit(embedding_input()).await.unwrap();
        assert_eq!(queue.cancel(&id).await.unwrap().state, JobState::Cancelled);

        let jobs_guard = queue.inner.jobs.lock().await;
        let (reached_tx, reached_rx) = tokio::sync::oneshot::channel();
        let retry_queue = queue.clone();
        let retry_id = id.clone();
        let retry = tokio::spawn(async move {
            retry_queue
                .retry_with_pre_lock_hook(&retry_id, || {
                    let _ = reached_tx.send(());
                })
                .await
        });
        reached_rx
            .await
            .expect("retry must pass its optimistic check before blocking on jobs");

        let shutdown_queue = queue.clone();
        let shutdown = tokio::spawn(async move { shutdown_queue.shutdown().await });
        tokio::time::timeout(Duration::from_secs(1), async {
            while !queue.inner.draining.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("shutdown must close admission before waiting for jobs");
        drop(jobs_guard);

        assert!(matches!(
            retry.await.expect("retry task should not panic"),
            Err(QueueError::ShuttingDown)
        ));
        shutdown.await.expect("shutdown task should not panic");
        assert_eq!(queue.get(&id).await.unwrap().state, JobState::Cancelled);
    }

    #[tokio::test]
    async fn retries_transient_failure_until_done() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(1),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(1),
        });
        let queue = queue(adapter, 1, 3);
        let id = queue.submit(embedding_input()).await.unwrap();
        let job = queue.wait(&id).await.unwrap();
        assert_eq!(job.state, JobState::Done);
        assert_eq!(job.attempts, 2);
    }

    #[tokio::test]
    async fn respects_capability_concurrency() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(30),
        });
        let queue = queue(Arc::clone(&adapter), 2, 1);
        let mut ids = Vec::new();
        for _ in 0..6 {
            ids.push(queue.submit(embedding_input()).await.unwrap());
        }
        for id in ids {
            assert_eq!(queue.wait(&id).await.unwrap().state, JobState::Done);
        }
        assert_eq!(adapter.peak.load(Ordering::SeqCst), 2);
    }

    /// `prepare` must run before the attempt is spawned.
    ///
    /// Arming a token outlet after `submit_with` returned is a race an idle
    /// lane wins: the adapter starts, finds no outlet, and the round does not
    /// stream. Whether streaming happened came down to scheduling.
    #[tokio::test]
    async fn prepare_runs_before_the_job_can_start() {
        let queue = ModelQueue::new(
            vec![Arc::new(crate::ProcessAdapter::new(
                crate::ProcessAdapterConfig::new("echo-llm", ModelCapability::Llm, "/bin/false"),
            )) as Arc<dyn ModelAdapter>],
            QueueConfig::default(),
        )
        .unwrap();

        let prepared = Arc::new(std::sync::Mutex::new(None::<String>));
        let seen = Arc::clone(&prepared);
        let id = queue
            .submit_prepared(
                ModelInput::Llm {
                    messages: Vec::new(),
                    prompt: "hi".into(),
                    system: None,
                    temperature: None,
                },
                JobPriority::Interactive,
                move |job_id| {
                    *seen.lock().unwrap() = Some(job_id.to_owned());
                },
            )
            .await
            .unwrap();

        assert_eq!(
            prepared.lock().unwrap().as_deref(),
            Some(id.as_str()),
            "prepare must see the job id it will run under"
        );
    }

    #[tokio::test]
    async fn activity_separates_running_from_queued_work() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(80),
        });
        let queue = queue(adapter, 1, 1);
        let first = queue.submit(embedding_input()).await.unwrap();
        let second = queue.submit(embedding_input()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(10)).await;

        let activity = queue.activity().await;
        assert_eq!(activity.running.len(), 1, "one slot, one running job");
        assert_eq!(activity.running[0].adapter, "test");
        assert!(
            activity.running[0].started_at_ms > 0,
            "a running job knows when it started"
        );
        assert_eq!(activity.pending_for(ModelCapability::Embedding), 1);

        for id in [&first, &second] {
            queue.wait(id).await.unwrap();
        }
        let drained = queue.activity().await;
        assert!(drained.running.is_empty());
        assert_eq!(drained.pending_for(ModelCapability::Embedding), 0);
    }

    /// Nothing used to remove finished jobs, so a day of captures left
    /// thousands of them in memory and every `JobsList` copied the lot.
    #[tokio::test]
    async fn finished_jobs_beyond_the_cap_are_dropped() {
        let queue = queue(
            Arc::new(TestAdapter {
                failures_left: AtomicUsize::new(0),
                running: AtomicUsize::new(0),
                peak: AtomicUsize::new(0),
                delay: Duration::from_millis(0),
            }),
            4,
            1,
        );
        let mut jobs = queue.inner.jobs.lock().await;
        let stale = unix_time_ms() - TERMINAL_JOB_GRACE_MS - 1_000;
        for index in 0..(TERMINAL_JOB_HISTORY + 50) {
            let id = format!("job-{index}");
            jobs.insert(
                id.clone(),
                JobRecord {
                    snapshot: JobSnapshot {
                        id,
                        capability: ModelCapability::Embedding,
                        adapter: "test".to_owned(),
                        state: JobState::Done,
                        attempts: 1,
                        max_attempts: 1,
                        created_at_ms: stale,
                        updated_at_ms: stale + i64::try_from(index).unwrap_or(0),
                        started_at_ms: Some(stale),
                        output: None,
                        last_error: None,
                    },
                    input: embedding_input(),
                    cancellation: Cancellation::default(),
                    generation: 0,
                    priority: JobPriority::Interactive,
                },
            );
        }
        prune_terminal(&mut jobs);
        assert_eq!(jobs.len(), TERMINAL_JOB_HISTORY);
        assert!(
            jobs.contains_key(&format!("job-{}", TERMINAL_JOB_HISTORY + 49)),
            "the newest finished jobs are the ones worth keeping"
        );
        assert!(
            !jobs.contains_key("job-0"),
            "the oldest finished job should have been dropped"
        );
    }

    /// The grace window is load-bearing: `wait` re-reads its job by id after
    /// being woken, and a job pruned in that gap reads as a lost inference.
    #[tokio::test]
    async fn a_just_finished_job_survives_pruning_so_wait_can_read_it() {
        let queue = queue(
            Arc::new(TestAdapter {
                failures_left: AtomicUsize::new(0),
                running: AtomicUsize::new(0),
                peak: AtomicUsize::new(0),
                delay: Duration::from_millis(0),
            }),
            4,
            1,
        );
        let mut ids = Vec::new();
        for _ in 0..(TERMINAL_JOB_HISTORY + 20) {
            ids.push(queue.submit(embedding_input()).await.unwrap());
        }
        for id in &ids {
            assert_eq!(
                queue.wait(id).await.unwrap().state,
                JobState::Done,
                "every job that finished must still be readable"
            );
        }
    }

    #[tokio::test]
    async fn cancels_a_running_job_and_can_retry_it() {
        let adapter = Arc::new(TestAdapter {
            failures_left: AtomicUsize::new(0),
            running: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            delay: Duration::from_millis(100),
        });
        let queue = queue(adapter, 1, 1);
        let id = queue.submit(embedding_input()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert_eq!(queue.cancel(&id).await.unwrap().state, JobState::Cancelled);
        assert_eq!(queue.retry(&id).await.unwrap().state, JobState::Pending);
        assert_eq!(queue.wait(&id).await.unwrap().state, JobState::Done);
    }

    /// One adapter per capability sharing start-order and concurrency
    /// counters, so GPU-lane tests measure overlap *across* capabilities.
    struct GpuTrackingAdapter {
        capability: ModelCapability,
        label: &'static str,
        local_gpu: bool,
        starts: Arc<std::sync::Mutex<Vec<String>>>,
        running: Arc<AtomicUsize>,
        peak: Arc<AtomicUsize>,
        delay: Duration,
    }

    #[async_trait]
    impl ModelAdapter for GpuTrackingAdapter {
        fn capability(&self) -> ModelCapability {
            self.capability
        }

        fn name(&self) -> &'static str {
            "gpu-tracking"
        }

        fn uses_local_gpu(&self, _input: &ModelInput) -> bool {
            self.local_gpu
        }

        async fn execute(
            &self,
            _job_id: &str,
            input: &ModelInput,
            cancellation: Cancellation,
        ) -> Result<ModelOutput, AdapterError> {
            let running = self.running.fetch_add(1, Ordering::SeqCst) + 1;
            self.peak.fetch_max(running, Ordering::SeqCst);
            let label = match input {
                ModelInput::Llm { prompt, .. } => prompt.clone(),
                _ => self.label.to_owned(),
            };
            self.starts.lock().unwrap().push(label);
            tokio::select! {
                () = cancellation.cancelled() => {
                    self.running.fetch_sub(1, Ordering::SeqCst);
                    return Err(AdapterError::Cancelled);
                }
                () = tokio::time::sleep(self.delay) => {}
            }
            self.running.fetch_sub(1, Ordering::SeqCst);
            Ok(match self.capability {
                ModelCapability::Ocr => ModelOutput::Ocr {
                    text: String::new(),
                    regions: Vec::new(),
                },
                ModelCapability::Asr => ModelOutput::Asr {
                    text: String::new(),
                    language: None,
                },
                ModelCapability::Embedding => ModelOutput::Embedding { vector: vec![1.0] },
                ModelCapability::Llm => ModelOutput::llm(String::new()),
            })
        }
    }

    struct GpuRig {
        starts: Arc<std::sync::Mutex<Vec<String>>>,
        running: Arc<AtomicUsize>,
        peak: Arc<AtomicUsize>,
    }

    impl GpuRig {
        fn new() -> Self {
            Self {
                starts: Arc::new(std::sync::Mutex::new(Vec::new())),
                running: Arc::new(AtomicUsize::new(0)),
                peak: Arc::new(AtomicUsize::new(0)),
            }
        }

        fn adapter(
            &self,
            capability: ModelCapability,
            label: &'static str,
            delay: Duration,
        ) -> Arc<GpuTrackingAdapter> {
            self.adapter_with_gpu(capability, label, true, delay)
        }

        fn adapter_with_gpu(
            &self,
            capability: ModelCapability,
            label: &'static str,
            local_gpu: bool,
            delay: Duration,
        ) -> Arc<GpuTrackingAdapter> {
            Arc::new(GpuTrackingAdapter {
                capability,
                label,
                local_gpu,
                starts: Arc::clone(&self.starts),
                running: Arc::clone(&self.running),
                peak: Arc::clone(&self.peak),
                delay,
            })
        }

        fn queue(adapters: Vec<Arc<GpuTrackingAdapter>>, gpu_lane: bool) -> ModelQueue {
            ModelQueue::new(
                adapters
                    .into_iter()
                    .map(|adapter| adapter as Arc<dyn ModelAdapter>)
                    .collect::<Vec<_>>(),
                QueueConfig {
                    gpu_lane,
                    ..QueueConfig::default()
                },
            )
            .unwrap()
        }

        /// Waits until one job is actually executing, so a later submission is
        /// guaranteed to find the lane taken rather than racing the spawn.
        async fn wait_running(&self) {
            tokio::time::timeout(Duration::from_secs(1), async {
                while self.running.load(Ordering::SeqCst) != 1 {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .expect("the first job starts");
        }
    }

    fn ocr_input() -> ModelInput {
        ModelInput::Ocr {
            image_path: std::path::PathBuf::from("/tmp/frame.jpg"),
            prompt: None,
        }
    }

    fn asr_input() -> ModelInput {
        ModelInput::Asr {
            audio_path: std::path::PathBuf::from("/tmp/audio.m4a"),
            language: None,
        }
    }

    /// The invariant: a background OCR pass, a transcription and a background
    /// LLM summary never run at the same time.
    #[tokio::test]
    async fn gpu_lane_serializes_background_work_across_capabilities() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(40)),
                rig.adapter(ModelCapability::Asr, "asr", Duration::from_millis(40)),
            ],
            true,
        );

        let first = queue.submit(ocr_input()).await.unwrap();
        let second = queue.submit(asr_input()).await.unwrap();
        for id in [&first, &second] {
            assert_eq!(queue.wait(id).await.unwrap().state, JobState::Done);
        }
        assert_eq!(rig.peak.load(Ordering::SeqCst), 1, "GPU jobs overlapped");
    }

    /// The T2 summariser's case: a background local-LLM pass rides the lane
    /// like any other background GPU work.
    #[tokio::test]
    async fn background_local_llm_takes_the_gpu_lane() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(40)),
                rig.adapter(ModelCapability::Llm, "llm", Duration::from_millis(40)),
            ],
            true,
        );

        let frame = queue.submit(ocr_input()).await.unwrap();
        let summary = queue
            .submit_with(llm_job("t2"), JobPriority::Background { lease: None })
            .await
            .unwrap();
        for id in [&frame, &summary] {
            assert_eq!(queue.wait(id).await.unwrap().state, JobState::Done);
        }
        assert_eq!(rig.peak.load(Ordering::SeqCst), 1, "GPU jobs overlapped");
    }

    /// OCR is on the capture critical path; work with a durable backlog must
    /// not go ahead of it even when it queued first.
    #[tokio::test]
    async fn ocr_overtakes_queued_background_gpu_work() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Asr, "asr", Duration::from_millis(60)),
                rig.adapter(ModelCapability::Embedding, "embedding", Duration::from_millis(10)),
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(10)),
            ],
            true,
        );

        let holder = queue.submit(asr_input()).await.unwrap();
        rig.wait_running().await;
        let background = queue.submit(embedding_input()).await.unwrap();
        let frame = queue.submit(ocr_input()).await.unwrap();

        for id in [&holder, &background, &frame] {
            queue.wait(id).await.unwrap();
        }
        assert_eq!(
            *rig.starts.lock().unwrap(),
            vec!["asr", "ocr", "embedding"],
            "OCR must win the lane over earlier-queued background work"
        );
    }

    /// Interactive work is never governed: a chat reply does not queue behind
    /// background GPU work.
    #[tokio::test]
    async fn interactive_llm_bypasses_the_gpu_lane() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(60)),
                rig.adapter(ModelCapability::Llm, "llm", Duration::from_millis(10)),
            ],
            true,
        );

        let frame = queue.submit(ocr_input()).await.unwrap();
        rig.wait_running().await;
        let chat = queue
            .submit_with(llm_job("chat"), JobPriority::Interactive)
            .await
            .unwrap();
        for id in [&frame, &chat] {
            queue.wait(id).await.unwrap();
        }
        assert_eq!(
            rig.peak.load(Ordering::SeqCst),
            2,
            "interactive chat must overlap background GPU work"
        );
    }

    /// The T2 summariser's real submission shape: `run_slot_t2` holds a lease
    /// and submits every round as `Background { lease: Some(id) }`. Those
    /// rounds must still ride the lane — a summary overlapping a running OCR
    /// or ASR job is exactly what the lane exists to prevent.
    #[tokio::test]
    async fn leased_background_llm_rides_the_gpu_lane() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(60)),
                rig.adapter(ModelCapability::Llm, "llm", Duration::from_millis(10)),
            ],
            true,
        );

        let hold = queue.hold_llm_lease();
        let frame = queue.submit(ocr_input()).await.unwrap();
        rig.wait_running().await;
        let round = queue
            .submit_with(
                llm_job("t2-round"),
                JobPriority::Background {
                    lease: Some(hold.id()),
                },
            )
            .await
            .unwrap();
        for id in [&frame, &round] {
            queue.wait(id).await.unwrap();
        }
        drop(hold);
        assert_eq!(
            rig.peak.load(Ordering::SeqCst),
            1,
            "a leased background pass must wait for the lane"
        );
    }

    /// While a loop holds its lease, its rounds win the lane over plain
    /// background work — and the excluded rival parks at the lane holding
    /// nothing, so it cannot deadlock the loop at the LLM gate.
    #[tokio::test]
    async fn lease_hold_reserves_the_gpu_lane_between_rounds() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Asr, "asr", Duration::from_millis(50)),
                rig.adapter(ModelCapability::Llm, "llm", Duration::from_millis(10)),
            ],
            true,
        );

        let holder = queue.submit(asr_input()).await.unwrap();
        rig.wait_running().await;
        let hold = queue.hold_llm_lease();
        // The rival queues first but is plain background: the hold excludes it.
        let rival = queue
            .submit_with(llm_job("rival"), JobPriority::Background { lease: None })
            .await
            .unwrap();
        let round = queue
            .submit_with(
                llm_job("round"),
                JobPriority::Background {
                    lease: Some(hold.id()),
                },
            )
            .await
            .unwrap();
        queue.wait(&holder).await.unwrap();
        queue.wait(&round).await.unwrap();
        // The rival cannot run until the hold drops.
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(queue.get(&rival).await.unwrap().state, JobState::Pending);
        drop(hold);
        assert_eq!(queue.wait(&rival).await.unwrap().state, JobState::Done);
        assert_eq!(
            *rig.starts.lock().unwrap(),
            vec!["asr", "round", "rival"],
            "the loop's round must win the lane over the excluded rival"
        );
    }

    /// A remote endpoint does not touch the local GPU, so its jobs neither
    /// hold the lane nor are held by it.
    #[tokio::test]
    async fn remote_llm_does_not_take_the_gpu_lane() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(60)),
                rig.adapter_with_gpu(
                    ModelCapability::Llm,
                    "remote-llm",
                    false,
                    Duration::from_millis(10),
                ),
            ],
            true,
        );

        let frame = queue.submit(ocr_input()).await.unwrap();
        rig.wait_running().await;
        let summary = queue
            .submit_with(llm_job("remote-t2"), JobPriority::Background { lease: None })
            .await
            .unwrap();
        for id in [&frame, &summary] {
            queue.wait(id).await.unwrap();
        }
        assert_eq!(
            rig.peak.load(Ordering::SeqCst),
            2,
            "a remote LLM job must overlap local GPU work"
        );
    }

    /// A waiter cancelled at the lane must neither run nor strand the permit.
    #[tokio::test]
    async fn cancelling_a_gpu_lane_waiter_does_not_leak_the_permit() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(40)),
                rig.adapter(ModelCapability::Asr, "asr", Duration::from_millis(10)),
            ],
            true,
        );

        let first = queue.submit(ocr_input()).await.unwrap();
        rig.wait_running().await;
        let cancelled = queue.submit(asr_input()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(5)).await; // park on the lane
        assert_eq!(
            queue.cancel(&cancelled).await.unwrap().state,
            JobState::Cancelled
        );

        let next = queue.submit(ocr_input()).await.unwrap();
        for id in [&first, &next] {
            assert_eq!(queue.wait(id).await.unwrap().state, JobState::Done);
        }
        assert_eq!(
            *rig.starts.lock().unwrap(),
            vec!["ocr", "ocr"],
            "the cancelled waiter must neither run nor block the lane"
        );
    }

    /// `AFTERRAY_GPU_LANE=0` restores the old free-for-all scheduling.
    #[tokio::test]
    async fn gpu_lane_disabled_restores_overlap() {
        let rig = GpuRig::new();
        let queue = GpuRig::queue(
            vec![
                rig.adapter(ModelCapability::Ocr, "ocr", Duration::from_millis(40)),
                rig.adapter(ModelCapability::Asr, "asr", Duration::from_millis(40)),
            ],
            false,
        );

        let first = queue.submit(ocr_input()).await.unwrap();
        let second = queue.submit(asr_input()).await.unwrap();
        for id in [&first, &second] {
            assert_eq!(queue.wait(id).await.unwrap().state, JobState::Done);
        }
        assert_eq!(
            rig.peak.load(Ordering::SeqCst),
            2,
            "with the lane off, GPU jobs of different capabilities overlap"
        );
    }
}
