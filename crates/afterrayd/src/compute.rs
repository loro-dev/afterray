//! One place that decides whether background computation may run, and one
//! place that can describe that decision to the user.
//!
//! Before this module the answer was scattered: the T2 sweeper had a careful
//! fail-closed gate, the GOP packer had an opt-in `AFTERRAY_GOP_REQUIRE_AC`
//! that defaulted to *off*, and `OCR`, transcription and embeddings had no gate
//! at all. So "`AfterRay` stops computing on battery" was true of exactly one of
//! the five things it computes, and the user had no way to see or change any of
//! it.
//!
//! Two rules shape everything here:
//!
//! - **Interactive work is never governed.** A chat turn the user is watching
//!   stream is not background computation. A switch that silenced it would read
//!   as a broken app, not as a power setting.
//! - **Suspending is draining, not killing.** Pausing stops the daemon taking
//!   new work; whatever is mid-flight finishes. Killing a running OCR pass
//!   throws away the compute already spent and loses the only chance to index
//!   that frame.

use afterray_platform_macos::ProcessUsage;
use afterray_protocol::{
    ComputeGate, ComputeGateCode, ComputeMachine, ComputeMode, ComputeRun, ComputeThresholds,
    ComputeWorkload,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::{Duration, Instant};

/// Charge below which summaries wait even on AC — a laptop plugged in at 8% is
/// still recovering, and a local model is the last thing it needs.
pub(crate) const T2_MIN_BATTERY: f64 = 0.30;
// @dec:mlx-idle-lifetime — docs/decisions/active/architecture/2026-08-24-mlx-idle-lifetime.md
/// How long the machine must have been untouched before an automatic summary
/// may load the local model. This keeps ordinary pauses in active work from
/// turning into several gigabytes of resident model memory.
pub(crate) const T2_MIN_IDLE_SECONDS: f64 = 120.0;
/// One-minute load average per core. Above this something else already wants
/// the machine, and the user will feel a local model piling on.
pub(crate) const T2_MAX_LOAD_PER_CORE: f64 = 0.7;
/// Machine-wide GPU utilization above which summaries wait. The load average
/// sees only CPU: a game, a local LLM, or a video export elsewhere on the
/// machine is exactly what it misses, and a 200-second model pass piling on
/// is what the user feels.
pub(crate) const T2_MAX_GPU_UTILIZATION: f64 = 0.5;
/// How fresh the newest GPU reading must be, and the span the gate averages
/// over — the daemon samples at 1 Hz, so this is the last fifteen samples.
const GPU_WINDOW_MS: i64 = 15_000;
/// GPU readings kept. A few more than fit the window, so a sample landing
/// just after a gate check never shortens the average's span.
const GPU_SAMPLES: usize = 15;

/// Summary passes kept for the dashboard's "how much longer?" estimate.
///
/// Wide enough that a median means something, narrow enough that it tracks the
/// machine's current state — a laptop that got slower this week should not be
/// estimated from last week's numbers.
pub(crate) const SUMMARY_HISTORY: usize = 12;

/// How long a "run now" override lasts.
///
/// Long enough to drain a real backlog — a dozen slots at a few minutes each —
/// and short enough that a machine does not stay overridden all afternoon
/// because somebody pressed a button once. The override also ends by itself as
/// soon as the backlog is empty.
pub(crate) const FORCE_WINDOW: Duration = Duration::from_secs(30 * 60);

/// Longest suspension the daemon will honour. The panel offers an hour; this
/// only exists so a malformed request cannot mute capture-adjacent work for a
/// week.
pub(crate) const MAX_PAUSE_SECONDS: u64 = 24 * 60 * 60;

/// What the machine looked like when the gate was asked.
#[derive(Debug, Clone, Copy)]
pub(crate) struct MachineConditions {
    pub(crate) on_ac: bool,
    /// `None` on a desktop, which has no battery to conserve.
    pub(crate) battery: Option<f64>,
    pub(crate) idle_seconds: f64,
    /// `None` when the load average could not be read.
    pub(crate) load_per_core: Option<f64>,
    /// `None` when the platform reports no thermal level.
    pub(crate) thermal_level: Option<u32>,
}

impl MachineConditions {
    pub(crate) fn probe() -> Self {
        Self {
            on_ac: afterray_platform_macos::on_ac_power(),
            battery: afterray_platform_macos::battery_fraction(),
            idle_seconds: afterray_platform_macos::seconds_since_user_input(),
            load_per_core: afterray_platform_macos::load_per_core(),
            thermal_level: afterray_platform_macos::thermal_pressure(),
        }
    }
}

/// Why a workload may not run, ready to hand to the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GateRefusal {
    pub(crate) code: ComputeGateCode,
    /// Names the measurement, not the policy: "battery at 18% is below 30%",
    /// never "conditions not met". This string is the whole reason the panel is
    /// worth opening.
    pub(crate) reason: String,
}

impl GateRefusal {
    fn new(code: ComputeGateCode, reason: impl Into<String>) -> Self {
        Self {
            code,
            reason: reason.into(),
        }
    }
}

pub(crate) type GateDecision = Result<(), GateRefusal>;

/// Whether a T2 pass may run under these conditions, or the reason it may not.
///
/// T2 is the most expensive thing this daemon does — a local model over a
/// 16k-character prompt — and it is never urgent. Every check here fails
/// closed: an unreadable probe means wait, because the cost of waiting is a
/// summary arriving late and the cost of guessing wrong is the user's machine
/// stuttering while they work.
pub(crate) fn t2_may_run(conditions: MachineConditions) -> GateDecision {
    if !conditions.on_ac {
        return Err(GateRefusal::new(
            ComputeGateCode::OnBattery,
            "on battery — summaries wait for power",
        ));
    }
    // A desktop reports no battery; nothing to conserve, so nothing to check.
    if let Some(battery) = conditions.battery
        && battery < T2_MIN_BATTERY
    {
        return Err(GateRefusal::new(
            ComputeGateCode::BatteryLow,
            format!(
                "battery at {:.0}% is below {:.0}%",
                battery * 100.0,
                T2_MIN_BATTERY * 100.0
            ),
        ));
    }
    if conditions.idle_seconds < T2_MIN_IDLE_SECONDS {
        return Err(GateRefusal::new(
            ComputeGateCode::InUse,
            format!(
                "in use {:.0}s ago, needs {T2_MIN_IDLE_SECONDS:.0}s",
                conditions.idle_seconds
            ),
        ));
    }
    match conditions.load_per_core {
        Some(load) if load > T2_MAX_LOAD_PER_CORE => Err(GateRefusal::new(
            ComputeGateCode::MachineBusy,
            format!("load {load:.2}/core is above {T2_MAX_LOAD_PER_CORE:.2}"),
        )),
        // An unreadable load average is not permission to add to it.
        None => Err(GateRefusal::new(
            ComputeGateCode::Unavailable,
            "load average unavailable",
        )),
        Some(_) => Ok(()),
    }
}

/// How much work each workload has waiting, in the two forms that differ.
///
/// `pending` is what reached the in-memory job queue — seconds of it. `backlog`
/// is counted from the vault and survives restarts. Keyed by workload rather
/// than passed as a positional pair, so a caller cannot silently transpose them.
#[derive(Debug, Clone, Default)]
pub(crate) struct WorkloadCounts {
    pending: HashMap<ComputeWorkload, usize>,
    backlog: HashMap<ComputeWorkload, usize>,
}

impl WorkloadCounts {
    pub(crate) fn set(&mut self, workload: ComputeWorkload, pending: usize, backlog: usize) {
        self.pending.insert(workload, pending);
        self.backlog.insert(workload, backlog);
    }

    fn pending(&self, workload: ComputeWorkload) -> usize {
        self.pending.get(&workload).copied().unwrap_or(0)
    }

    fn backlog(&self, workload: ComputeWorkload) -> usize {
        self.backlog.get(&workload).copied().unwrap_or(0)
    }
}

/// Launch-time facts the governor cannot change, so the panel can say
/// "disabled at launch" instead of showing a switch that does nothing.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct ComputeLimits {
    /// `AFTERRAY_T2_SWEEP_SECONDS=0`.
    pub(crate) summaries_disabled_by_env: bool,
    /// `AFTERRAY_GOP_ARCHIVE=0`.
    pub(crate) archive_disabled_by_env: bool,
    /// `AFTERRAY_GPU_PROBE=0` — the GPU gate on summaries is skipped, and the
    /// daemon never started its sampler.
    pub(crate) gpu_probe_disabled_by_env: bool,
}

/// The live decision-maker. Cheap to consult: a gate check is a few uncontended
/// lock acquisitions plus the probes the caller already needed — no I/O.
pub(crate) struct ComputeGovernor {
    mode: std::sync::Mutex<ComputeMode>,
    /// Epoch-ms the current suspension lifts; `0` means nothing is suspended.
    paused_until_ms: AtomicI64,
    limits: ComputeLimits,
    /// Previous CPU readings per pid, so a percentage can be a rate rather
    /// than a lifetime average — a worker that ran hot an hour ago and is idle
    /// now must not still read as busy.
    samples: std::sync::Mutex<HashMap<u32, (Instant, ProcessUsage)>>,
    /// Per-workload override deadlines, epoch-ms. While one is live, the machine
    /// conditions are bypassed for that workload: the user has said "now",
    /// which is newer information than "the load average looks busy".
    forced_until_ms: std::sync::Mutex<HashMap<ComputeWorkload, i64>>,
    /// Recent summary passes, newest first. Seeded from the vault at startup so
    /// the estimate is available immediately after a restart — which is exactly
    /// when a user who just updated the app might be wondering why their fans
    /// are up.
    summaries: std::sync::Mutex<std::collections::VecDeque<ComputeRun>>,
    /// Recent machine GPU readings, oldest first, as `(epoch_ms, fraction)`.
    /// Fed at 1 Hz by the daemon's sampler task; the summary gate averages
    /// the newest window of them. Nothing records a reading the probe could
    /// not produce — an unanswered probe lets the window go stale, which the
    /// gate reads as "unknown", not "idle".
    gpu_samples: std::sync::Mutex<std::collections::VecDeque<(i64, f64)>>,
}

impl ComputeGovernor {
    pub(crate) fn new(mode: ComputeMode, paused_until_ms: i64, limits: ComputeLimits) -> Self {
        Self {
            mode: std::sync::Mutex::new(mode),
            paused_until_ms: AtomicI64::new(paused_until_ms.max(0)),
            limits,
            samples: std::sync::Mutex::new(HashMap::new()),
            forced_until_ms: std::sync::Mutex::new(HashMap::new()),
            summaries: std::sync::Mutex::new(std::collections::VecDeque::new()),
            gpu_samples: std::sync::Mutex::new(std::collections::VecDeque::new()),
        }
    }

    /// Starts a "run now" override for `workload`, returning its deadline.
    ///
    /// Also lifts an active suspension: pressing start while paused is a newer
    /// instruction from the same person, and honouring the pause instead would
    /// leave the panel showing a button that visibly did nothing.
    pub(crate) fn force_now(&self, workload: ComputeWorkload, now_ms: i64) -> i64 {
        let until = now_ms
            .saturating_add(i64::try_from(FORCE_WINDOW.as_millis()).unwrap_or(30 * 60 * 1_000));
        self.paused_until_ms.store(0, Ordering::SeqCst);
        self.forced_until_ms
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(workload, until);
        until
    }

    pub(crate) fn forced_until_ms(&self, workload: ComputeWorkload, now_ms: i64) -> Option<i64> {
        self.forced_until_ms
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&workload)
            .copied()
            .filter(|until| *until > now_ms)
    }

    /// Ends an override early. The loops call this the moment their backlog is
    /// empty, so an override does not sit open for half an hour after the work
    /// it was requested for is done.
    /// Returns whether an override was actually running, so a caller can log
    /// the transition without asking a second time.
    pub(crate) fn clear_force(&self, workload: ComputeWorkload) -> bool {
        self.forced_until_ms
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&workload)
            .is_some()
    }

    /// The numbers the automatic triggers compare against, for the panel's
    /// "why isn't this running?" explanation.
    pub(crate) const fn thresholds() -> ComputeThresholds {
        ComputeThresholds {
            summary_min_battery_fraction: T2_MIN_BATTERY,
            summary_min_idle_seconds: T2_MIN_IDLE_SECONDS,
            summary_max_load_per_core: T2_MAX_LOAD_PER_CORE,
            force_window_seconds: FORCE_WINDOW.as_secs(),
        }
    }

    /// Records a finished summary pass. `duration` is wall clock around the
    /// whole pass, queue wait included — that is what the user actually waited
    /// through, and it is the number the estimate has to be built from.
    pub(crate) fn record_summary(
        &self,
        slot_start_ms: i64,
        finished_at_ms: i64,
        duration: Duration,
        ok: bool,
    ) {
        let run = ComputeRun {
            slot_start_ms,
            finished_at_ms,
            duration_ms: i64::try_from(duration.as_millis()).unwrap_or(i64::MAX),
            ok,
        };
        let mut summaries = self
            .summaries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        summaries.push_front(run);
        summaries.truncate(SUMMARY_HISTORY);
    }

    /// Fills the window from persisted history, newest first. Ignored once the
    /// daemon has recorded a pass of its own, so a seed can never displace a
    /// live measurement.
    pub(crate) fn seed_summaries(&self, runs: impl IntoIterator<Item = ComputeRun>) {
        let mut summaries = self
            .summaries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !summaries.is_empty() {
            return;
        }
        summaries.extend(runs.into_iter().take(SUMMARY_HISTORY));
    }

    pub(crate) fn recent_summaries(&self) -> Vec<ComputeRun> {
        self.summaries
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .copied()
            .collect()
    }

    /// Records one machine GPU reading from the sampler. Call only with a
    /// value the probe actually returned — a failed probe records nothing, so
    /// the window ages out and the gate falls back to "unavailable" instead
    /// of trusting a stale or invented number.
    pub(crate) fn record_gpu_utilization(&self, now_ms: i64, value: f64) {
        let mut samples = self
            .gpu_samples
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        samples.push_back((now_ms, value));
        while samples.len() > GPU_SAMPLES {
            samples.pop_front();
        }
    }

    pub(crate) fn mode(&self) -> ComputeMode {
        *self
            .mode
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub(crate) fn set_mode(&self, mode: ComputeMode) {
        *self
            .mode
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = mode;
    }

    /// The deadline of the active suspension, or `None` when nothing is
    /// suspended. Resolved against `now` so an expired deadline reads as
    /// "not paused" without anyone having to clear it.
    pub(crate) fn paused_until_ms(&self, now_ms: i64) -> Option<i64> {
        let until = self.paused_until_ms.load(Ordering::SeqCst);
        (until > now_ms).then_some(until)
    }

    /// Suspends background work for `seconds`, or resumes now when `0`.
    /// Returns the resulting deadline.
    pub(crate) fn pause_for(&self, now_ms: i64, seconds: u64) -> Option<i64> {
        if seconds == 0 {
            self.paused_until_ms.store(0, Ordering::SeqCst);
            return None;
        }
        let seconds = seconds.min(MAX_PAUSE_SECONDS);
        let until = now_ms.saturating_add(i64::try_from(seconds).unwrap_or(0) * 1_000);
        self.paused_until_ms.store(until, Ordering::SeqCst);
        Some(until)
    }

    /// The value to persist, so an hour-long suspension survives the restart
    /// that happens when the app updates itself mid-pause.
    pub(crate) fn persisted_pause_ms(&self) -> i64 {
        self.paused_until_ms.load(Ordering::SeqCst)
    }

    /// The refusals that come from a standing choice rather than a reading of
    /// the machine: an env switch at launch, the mode, or an active suspension.
    ///
    /// Split out because two callers need it and only one of them cares about
    /// the machine: `decide` checks these first, and `can_force` needs to know
    /// whether a "run now" could possibly help. Keeping the wording here means
    /// the panel's gate row and the "start now" refusal cannot say different
    /// things about the same rule.
    fn standing_refusal(&self, workload: ComputeWorkload, now_ms: i64) -> Option<GateRefusal> {
        let disabled_by = match workload {
            ComputeWorkload::Summary if self.limits.summaries_disabled_by_env => {
                Some("AFTERRAY_T2_SWEEP_SECONDS=0")
            }
            ComputeWorkload::Archive if self.limits.archive_disabled_by_env => {
                Some("AFTERRAY_GOP_ARCHIVE=0")
            }
            _ => None,
        };
        if let Some(switch) = disabled_by {
            return Some(GateRefusal::new(
                ComputeGateCode::DisabledByEnv,
                format!("disabled at launch by {switch}"),
            ));
        }

        let mode = self.mode();
        if mode == ComputeMode::Off {
            return Some(GateRefusal::new(
                ComputeGateCode::ModeOff,
                "local computation is switched off",
            ));
        }

        // Screen text is the one workload a suspension does not touch. There is
        // no OCR backlog in the vault — a frame that goes un-OCR'd is never
        // indexed by anything later — so pausing it would quietly cost the user
        // an hour of searchable history to save a fraction of a core. Only the
        // explicit "off" switch above, whose copy says so, stops it.
        if workload != ComputeWorkload::Ocr
            && let Some(until) = self.paused_until_ms(now_ms)
        {
            let minutes = (until.saturating_sub(now_ms) + 59_999) / 60_000;
            return Some(GateRefusal::new(
                ComputeGateCode::Paused,
                format!("suspended by you for another {minutes} min"),
            ));
        }

        if mode == ComputeMode::Essential
            && matches!(
                workload,
                ComputeWorkload::Summary | ComputeWorkload::Archive
            )
        {
            return Some(GateRefusal::new(
                ComputeGateCode::ModeEssential,
                "only essential work runs in this mode",
            ));
        }
        None
    }

    // @dec:gpu-utilization-gate — docs/decisions/active/architecture/2026-08-24-gpu-utilization-gate.md
    /// The machine-GPU check summaries run after the CPU gate. The load
    /// average sees only CPU work; a game, a local LLM, or a video export
    /// elsewhere on the machine is exactly what it misses.
    ///
    /// Fail-closed like the load average: the newest reading must be no older
    /// than the window, and the average over the window must sit under the
    /// threshold. An empty or stale window means the probe is not answering,
    /// which is not permission.
    fn summary_gpu_may_run(&self, now_ms: i64) -> GateDecision {
        if self.limits.gpu_probe_disabled_by_env {
            return Ok(());
        }
        let samples = self
            .gpu_samples
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let newest_is_fresh = samples
            .back()
            .is_some_and(|(at, _)| now_ms.saturating_sub(*at) <= GPU_WINDOW_MS);
        if !newest_is_fresh {
            return Err(GateRefusal::new(
                ComputeGateCode::Unavailable,
                "GPU utilization unavailable",
            ));
        }
        let mut total = 0.0;
        let mut count = 0_usize;
        for (at, value) in samples.iter().rev() {
            if now_ms.saturating_sub(*at) > GPU_WINDOW_MS {
                break;
            }
            total += value;
            count += 1;
        }
        #[expect(clippy::cast_precision_loss, reason = "sample counts are tiny")]
        let average = total / count as f64;
        if average > T2_MAX_GPU_UTILIZATION {
            return Err(GateRefusal::new(
                ComputeGateCode::MachineBusy,
                format!(
                    "GPU at {:.0}% (15s avg) is above {:.0}%",
                    average * 100.0,
                    T2_MAX_GPU_UTILIZATION * 100.0
                ),
            ));
        }
        Ok(())
    }

    /// Whether `workload` may start right now.
    ///
    /// `conditions` is passed in rather than probed here so one report can
    /// describe every workload against the same instant — a panel where OCR
    /// says "on battery" and summaries say "on AC" would be its own bug.
    pub(crate) fn decide(
        &self,
        workload: ComputeWorkload,
        conditions: MachineConditions,
        now_ms: i64,
    ) -> GateDecision {
        if let Some(refusal) = self.standing_refusal(workload, now_ms) {
            return Err(refusal);
        }

        // The user pressed start. That is newer information than "the load
        // average looks busy", so the machine conditions below are skipped —
        // but the standing choices above are not.
        if self.forced_until_ms(workload, now_ms).is_some() {
            return Ok(());
        }

        match workload {
            // Both of these are the reason a machine feels slow: a 200-second
            // local model pass, and an all-core AV1 encode.
            ComputeWorkload::Summary => t2_may_run(conditions)
                .and_then(|()| self.summary_gpu_may_run(now_ms)),
            ComputeWorkload::Archive => {
                if conditions.on_ac {
                    Ok(())
                } else {
                    Err(GateRefusal::new(
                        ComputeGateCode::OnBattery,
                        "on battery — compression waits for power",
                    ))
                }
            }
            // Cheap, and each one is the only chance to index what was just
            // captured. Transcription slows down on battery instead of
            // stopping — the audio rows are a durable backlog, so late is fine
            // and never is not.
            ComputeWorkload::Ocr | ComputeWorkload::Asr | ComputeWorkload::Embedding => Ok(()),
        }
    }

    /// How long the transcription sweeper should wait between claims.
    ///
    /// Throttling rather than stopping: the backlog is durable, so on battery
    /// the work still drains, just five times slower. An override has to reach
    /// this too — ASR has no machine gate, so bypassing the gate alone would
    /// leave "run now" doing nothing but redraw the row.
    pub(crate) fn asr_sweep_interval(
        &self,
        conditions: MachineConditions,
        now_ms: i64,
    ) -> Duration {
        let forced = self.forced_until_ms(ComputeWorkload::Asr, now_ms).is_some();
        if conditions.on_ac || forced {
            Duration::from_secs(60)
        } else {
            Duration::from_secs(300)
        }
    }

    /// Samples one process, returning its cost since the previous sample.
    ///
    /// The first call for a pid can only report memory: a percentage needs two
    /// readings, and inventing one from the process's lifetime average would
    /// show a long-resident model worker as permanently busy.
    pub(crate) fn sample(&self, pid: u32) -> (Option<f64>, Option<u64>) {
        let Some(usage) = afterray_platform_macos::process_usage(pid) else {
            return (None, None);
        };
        let now = Instant::now();
        let mut samples = self
            .samples
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let percent = samples
            .insert(pid, (now, usage))
            .and_then(|(earlier_at, earlier)| {
                usage.cpu_percent_since(earlier, now.duration_since(earlier_at))
            });
        (percent, Some(usage.footprint_bytes))
    }

    /// Forgets processes that have exited, so a daemon that has spawned
    /// thousands of one-shot workers does not accumulate their readings.
    pub(crate) fn forget_dead_samples(&self, live: &[u32]) {
        let mut samples = self
            .samples
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        samples.retain(|pid, _| live.contains(pid));
    }

    /// One row per workload, whether or not anything of that kind is running.
    ///
    /// Empty rows carry the reason, which is the point: "Summaries — held: on
    /// battery" explains a quiet machine, and an absent row explains nothing.
    pub(crate) fn gates(
        &self,
        conditions: MachineConditions,
        now_ms: i64,
        counts: &WorkloadCounts,
    ) -> Vec<ComputeGate> {
        ComputeWorkload::ALL
            .into_iter()
            .map(|workload| {
                let (allowed, code, reason) = match self.decide(workload, conditions, now_ms) {
                    Ok(()) => (true, ComputeGateCode::Allowed, None),
                    Err(refusal) => (false, refusal.code, Some(refusal.reason)),
                };
                let pending = counts.pending(workload);
                let backlog = counts.backlog(workload);
                ComputeGate {
                    workload,
                    allowed,
                    code,
                    reason,
                    pending,
                    backlog,
                    forced_until_ms: self.forced_until_ms(workload, now_ms),
                    // `remaining` here matches what the panel shows: the queue
                    // count is a subset of the vault count, so the larger of the
                    // two is the pile, not their sum.
                    can_run_now: self.can_run_now(workload, pending.max(backlog), now_ms),
                }
            })
            .collect()
    }

    /// Why "run now" cannot help `workload`, if it cannot.
    ///
    /// A suspension is deliberately not an obstacle: `force_now` lifts it. What
    /// remains are the two standing choices no override should quietly
    /// overrule — the off switch, and a workload whose loop never started.
    pub(crate) fn force_refusal(
        &self,
        workload: ComputeWorkload,
        now_ms: i64,
    ) -> Option<GateRefusal> {
        self.standing_refusal(workload, now_ms).filter(|refusal| {
            matches!(
                refusal.code,
                ComputeGateCode::ModeOff | ComputeGateCode::DisabledByEnv
            )
        })
    }

    /// Whether offering "run now" for `workload` would change anything.
    ///
    /// Three ways it would not: something standing blocks it, it is already
    /// running under an override, or there is nothing waiting. The fourth is the
    /// workload itself — screen text and the search index have no machine gate
    /// and no throttle of their own, so forcing them can only lift a suspension,
    /// which the resume button already does more clearly.
    pub(crate) fn can_run_now(
        &self,
        workload: ComputeWorkload,
        remaining: usize,
        now_ms: i64,
    ) -> bool {
        matches!(
            workload,
            ComputeWorkload::Summary | ComputeWorkload::Archive | ComputeWorkload::Asr
        ) && remaining > 0
            && self.force_refusal(workload, now_ms).is_none()
            && self.forced_until_ms(workload, now_ms).is_none()
    }

    /// The machine block of the report, including the daemon's own cost — which
    /// is where in-process AV1 packing shows up, since it has no worker pid of
    /// its own.
    pub(crate) fn machine_report(&self, conditions: MachineConditions) -> ComputeMachine {
        let (daemon_cpu_percent, daemon_footprint_bytes) = self.sample(std::process::id());
        ComputeMachine {
            on_ac: conditions.on_ac,
            battery_fraction: conditions.battery,
            idle_seconds: conditions.idle_seconds,
            load_per_core: conditions.load_per_core,
            thermal_level: conditions.thermal_level,
            daemon_cpu_percent,
            daemon_footprint_bytes,
        }
    }
}

/// The workload a queue capability belongs to. The queue thinks in
/// capabilities; the panel thinks in jobs the user can recognise.
pub(crate) fn workload_for_capability(
    capability: afterray_models::ModelCapability,
) -> ComputeWorkload {
    use afterray_models::ModelCapability;
    match capability {
        ModelCapability::Ocr => ComputeWorkload::Ocr,
        ModelCapability::Asr => ComputeWorkload::Asr,
        ModelCapability::Embedding => ComputeWorkload::Embedding,
        // An LLM job in the queue is either a chat turn or a T2 pass. Both are
        // the same lane and the same model; the panel calls the row Summaries
        // because that is the one the user can switch off.
        ModelCapability::Llm => ComputeWorkload::Summary,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A machine that should be summarising: plugged in, charged, untouched,
    /// quiet. Each test spoils exactly one of those.
    const IDEAL: MachineConditions = MachineConditions {
        on_ac: true,
        battery: Some(0.9),
        idle_seconds: 600.0,
        load_per_core: Some(0.1),
        thermal_level: None,
    };

    fn governor(mode: ComputeMode) -> ComputeGovernor {
        ComputeGovernor::new(mode, 0, ComputeLimits::default())
    }

    #[test]
    fn ideal_conditions_allow_t2() {
        assert!(t2_may_run(IDEAL).is_ok());
    }

    #[test]
    fn t2_requires_two_complete_minutes_without_user_input() {
        let refusal = t2_may_run(MachineConditions {
            idle_seconds: T2_MIN_IDLE_SECONDS - 0.001,
            ..IDEAL
        })
        .unwrap_err();
        assert_eq!(refusal.code, ComputeGateCode::InUse);
        assert!(
            t2_may_run(MachineConditions {
                idle_seconds: T2_MIN_IDLE_SECONDS,
                ..IDEAL
            })
            .is_ok()
        );
    }

    #[test]
    fn each_condition_alone_blocks_t2() {
        let cases = [
            (
                "battery",
                MachineConditions {
                    on_ac: false,
                    ..IDEAL
                },
            ),
            (
                "low charge",
                MachineConditions {
                    battery: Some(0.1),
                    ..IDEAL
                },
            ),
            (
                "in use",
                MachineConditions {
                    idle_seconds: 5.0,
                    ..IDEAL
                },
            ),
            (
                "busy",
                MachineConditions {
                    load_per_core: Some(3.0),
                    ..IDEAL
                },
            ),
            (
                "unreadable load",
                MachineConditions {
                    load_per_core: None,
                    ..IDEAL
                },
            ),
        ];
        for (label, conditions) in cases {
            assert!(
                t2_may_run(conditions).is_err(),
                "{label} should have blocked T2"
            );
        }
    }

    #[test]
    fn a_desktop_without_a_battery_is_not_blocked_by_charge() {
        assert!(
            t2_may_run(MachineConditions {
                battery: None,
                ..IDEAL
            })
            .is_ok()
        );
    }

    #[test]
    fn the_load_boundary_is_inclusive() {
        assert!(
            t2_may_run(MachineConditions {
                load_per_core: Some(T2_MAX_LOAD_PER_CORE),
                ..IDEAL
            })
            .is_ok()
        );
    }

    /// The reason reaches the panel, so it has to name the thing that is wrong.
    #[test]
    fn the_block_reason_names_the_condition() {
        let refusal = t2_may_run(MachineConditions {
            on_ac: false,
            ..IDEAL
        })
        .unwrap_err();
        assert!(refusal.reason.contains("battery"), "{}", refusal.reason);
        assert_eq!(refusal.code, ComputeGateCode::OnBattery);

        let refusal = t2_may_run(MachineConditions {
            idle_seconds: 3.0,
            ..IDEAL
        })
        .unwrap_err();
        assert!(refusal.reason.contains("in use"), "{}", refusal.reason);
        assert_eq!(refusal.code, ComputeGateCode::InUse);
    }

    /// The behaviour the old code only claimed to have: on battery, the two
    /// expensive workloads stand down and the cheap ones carry on.
    #[test]
    fn battery_holds_back_summaries_and_compression_but_not_indexing() {
        let governor = governor(ComputeMode::Full);
        let on_battery = MachineConditions {
            on_ac: false,
            ..IDEAL
        };
        for held in [ComputeWorkload::Summary, ComputeWorkload::Archive] {
            let refusal = governor.decide(held, on_battery, 0).unwrap_err();
            assert_eq!(refusal.code, ComputeGateCode::OnBattery, "{held:?}");
        }
        for allowed in [
            ComputeWorkload::Ocr,
            ComputeWorkload::Asr,
            ComputeWorkload::Embedding,
        ] {
            assert!(
                governor.decide(allowed, on_battery, 0).is_ok(),
                "{allowed:?} should keep running on battery"
            );
        }
    }

    #[test]
    fn transcription_slows_down_on_battery_rather_than_stopping() {
        let governor = governor(ComputeMode::Full);
        let on_battery = MachineConditions {
            on_ac: false,
            ..IDEAL
        };
        assert!(governor.decide(ComputeWorkload::Asr, on_battery, 0).is_ok());
        assert!(
            governor.asr_sweep_interval(on_battery, 0) > governor.asr_sweep_interval(IDEAL, 0),
            "battery should stretch the sweep, not stop it"
        );
    }

    #[test]
    fn essential_mode_keeps_indexing_and_drops_the_expensive_work() {
        let governor = governor(ComputeMode::Essential);
        for allowed in [
            ComputeWorkload::Ocr,
            ComputeWorkload::Asr,
            ComputeWorkload::Embedding,
        ] {
            assert!(governor.decide(allowed, IDEAL, 0).is_ok(), "{allowed:?}");
        }
        for held in [ComputeWorkload::Summary, ComputeWorkload::Archive] {
            assert_eq!(
                governor.decide(held, IDEAL, 0).unwrap_err().code,
                ComputeGateCode::ModeEssential,
                "{held:?}"
            );
        }
    }

    #[test]
    fn off_stops_everything_including_screen_text() {
        let governor = governor(ComputeMode::Off);
        for workload in ComputeWorkload::ALL {
            assert_eq!(
                governor.decide(workload, IDEAL, 0).unwrap_err().code,
                ComputeGateCode::ModeOff,
                "{workload:?}"
            );
        }
    }

    /// Pausing must not cost the user searchable history: there is no OCR
    /// backlog, so a skipped frame is never indexed by anything later.
    #[test]
    fn a_pause_holds_back_everything_except_screen_text() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        assert_eq!(governor.pause_for(now, 3600), Some(now + 3_600_000));

        assert!(
            governor.decide(ComputeWorkload::Ocr, IDEAL, now).is_ok(),
            "screen text has no backlog and must survive a pause"
        );
        for held in [
            ComputeWorkload::Asr,
            ComputeWorkload::Embedding,
            ComputeWorkload::Summary,
            ComputeWorkload::Archive,
        ] {
            assert_eq!(
                governor.decide(held, IDEAL, now).unwrap_err().code,
                ComputeGateCode::Paused,
                "{held:?}"
            );
        }
    }

    #[test]
    fn a_pause_expires_on_its_own() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        governor.pause_for(now, 60);
        assert!(governor.paused_until_ms(now).is_some());
        assert!(
            governor.paused_until_ms(now + 61_000).is_none(),
            "an elapsed deadline reads as not paused, with nobody clearing it"
        );
        record_steady_gpu(&governor, now + 61_000, 0.1);
        assert!(
            governor
                .decide(ComputeWorkload::Summary, IDEAL, now + 61_000)
                .is_ok()
        );
    }

    #[test]
    fn resuming_clears_the_deadline() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        governor.pause_for(now, 3600);
        assert_eq!(governor.pause_for(now, 0), None);
        assert!(governor.paused_until_ms(now).is_none());
    }

    #[test]
    fn an_absurd_pause_is_clamped_rather_than_rejected() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        let until = governor.pause_for(now, u64::MAX).expect("still pauses");
        assert_eq!(
            until,
            now + i64::try_from(MAX_PAUSE_SECONDS).unwrap() * 1_000
        );
    }

    #[test]
    fn the_pause_reason_says_how_much_longer() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        governor.pause_for(now, 3600);
        let refusal = governor
            .decide(ComputeWorkload::Summary, IDEAL, now + 600_000)
            .unwrap_err();
        assert!(refusal.reason.contains("50 min"), "{}", refusal.reason);
    }

    #[test]
    fn an_env_disabled_workload_says_so_instead_of_blaming_the_battery() {
        let governor = ComputeGovernor::new(
            ComputeMode::Full,
            0,
            ComputeLimits {
                summaries_disabled_by_env: true,
                archive_disabled_by_env: true,
                gpu_probe_disabled_by_env: false,
            },
        );
        let on_battery = MachineConditions {
            on_ac: false,
            ..IDEAL
        };
        for workload in [ComputeWorkload::Summary, ComputeWorkload::Archive] {
            assert_eq!(
                governor.decide(workload, on_battery, 0).unwrap_err().code,
                ComputeGateCode::DisabledByEnv,
                "{workload:?}"
            );
        }
    }

    #[test]
    fn every_workload_gets_a_row_with_its_pending_count() {
        let governor = governor(ComputeMode::Full);
        let mut counts = WorkloadCounts::default();
        counts.set(ComputeWorkload::Ocr, 7, 0);
        let gates = governor.gates(IDEAL, 0, &counts);
        assert_eq!(gates.len(), ComputeWorkload::ALL.len());
        let ocr = gates
            .iter()
            .find(|gate| gate.workload == ComputeWorkload::Ocr)
            .expect("ocr row");
        assert_eq!(ocr.pending, 7);
        assert!(ocr.allowed);
        assert!(ocr.reason.is_none());
    }

    #[test]
    fn a_held_row_always_carries_a_reason() {
        let governor = governor(ComputeMode::Off);
        for gate in governor.gates(IDEAL, 0, &WorkloadCounts::default()) {
            assert!(!gate.allowed);
            assert!(
                gate.reason.is_some_and(|reason| !reason.is_empty()),
                "{:?} was held with nothing to show the user",
                gate.workload
            );
        }
    }

    /// The point of the button: a machine that is busy and unplugged still runs
    /// the work when the user says to.
    #[test]
    fn run_now_overrides_the_machine_conditions() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        let hostile = MachineConditions {
            on_ac: false,
            battery: Some(0.12),
            idle_seconds: 0.0,
            load_per_core: Some(4.0),
            thermal_level: Some(3),
        };
        assert!(
            governor
                .decide(ComputeWorkload::Summary, hostile, now)
                .is_err()
        );

        governor.force_now(ComputeWorkload::Summary, now);
        assert!(
            governor
                .decide(ComputeWorkload::Summary, hostile, now)
                .is_ok(),
            "the user pressing start is newer information than the load average"
        );
        // Scoped to the workload asked for; forcing summaries must not start an
        // all-core encode nobody asked about.
        assert!(
            governor
                .decide(ComputeWorkload::Archive, hostile, now)
                .is_err()
        );
    }

    /// Transcription has no machine gate, so bypassing the gate alone would make
    /// its "run now" nothing but a redrawn row. The override has to reach the
    /// throttle that is actually slowing it down.
    #[test]
    fn forcing_transcription_speeds_up_its_sweep_on_battery() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        let on_battery = MachineConditions {
            on_ac: false,
            ..IDEAL
        };
        assert_eq!(
            governor.asr_sweep_interval(on_battery, now),
            Duration::from_secs(300)
        );
        governor.force_now(ComputeWorkload::Asr, now);
        assert_eq!(
            governor.asr_sweep_interval(on_battery, now),
            Duration::from_secs(60),
            "a forced run must not still wait five minutes between claims"
        );
    }

    /// The button is offered by the daemon, not re-derived by the client: the
    /// answer depends on which workloads have a gate or a throttle of their own.
    #[test]
    fn run_now_is_offered_only_where_it_would_change_something() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;

        assert!(governor.can_run_now(ComputeWorkload::Summary, 23, now));
        assert!(
            !governor.can_run_now(ComputeWorkload::Summary, 0, now),
            "nothing waiting means nothing to start"
        );
        // Neither has a machine gate or a throttle, so forcing them could only
        // lift a suspension — which the resume button already does.
        assert!(!governor.can_run_now(ComputeWorkload::Ocr, 40, now));
        assert!(!governor.can_run_now(ComputeWorkload::Embedding, 40, now));

        governor.force_now(ComputeWorkload::Summary, now);
        assert!(
            !governor.can_run_now(ComputeWorkload::Summary, 23, now),
            "already running under an override; pressing again does nothing"
        );

        let off = ComputeGovernor::new(ComputeMode::Off, 0, ComputeLimits::default());
        assert!(
            !off.can_run_now(ComputeWorkload::Summary, 23, now),
            "a standing off switch is not something a button should overrule"
        );
    }

    #[test]
    fn an_override_expires_and_can_be_ended_early() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        let on_battery = MachineConditions {
            on_ac: false,
            ..IDEAL
        };
        let until = governor.force_now(ComputeWorkload::Summary, now);
        assert_eq!(
            until,
            now + i64::try_from(FORCE_WINDOW.as_millis()).unwrap()
        );
        assert!(
            governor
                .decide(ComputeWorkload::Summary, on_battery, until + 1)
                .is_err(),
            "an override must not outlive its window"
        );

        governor.force_now(ComputeWorkload::Summary, now);
        assert!(governor.clear_force(ComputeWorkload::Summary));
        assert!(
            governor
                .forced_until_ms(ComputeWorkload::Summary, now)
                .is_none()
        );
        assert!(
            !governor.clear_force(ComputeWorkload::Summary),
            "clearing nothing reports nothing, so callers do not log a transition"
        );
    }

    /// Pressing start while suspended is a newer instruction from the same
    /// person. Keeping the suspension would leave the panel showing a button
    /// that visibly did nothing.
    #[test]
    fn run_now_lifts_an_active_suspension() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        governor.pause_for(now, 3600);
        governor.force_now(ComputeWorkload::Summary, now);
        assert!(governor.paused_until_ms(now).is_none());
        assert!(governor.decide(ComputeWorkload::Asr, IDEAL, now).is_ok());
    }

    /// A standing "off" is a decision to respect, not to override behind the
    /// user's back — the button says why instead.
    #[test]
    fn run_now_refuses_while_local_computation_is_off() {
        let off = governor(ComputeMode::Off);
        let refusal = off
            .force_refusal(ComputeWorkload::Summary, 0)
            .expect("off blocks a forced run");
        assert!(
            refusal.reason.contains("switched off"),
            "{}",
            refusal.reason
        );
        assert!(
            governor(ComputeMode::Full)
                .force_refusal(ComputeWorkload::Summary, 0)
                .is_none()
        );

        let disabled = ComputeGovernor::new(
            ComputeMode::Full,
            0,
            ComputeLimits {
                summaries_disabled_by_env: true,
                archive_disabled_by_env: false,
                gpu_probe_disabled_by_env: false,
            },
        );
        assert!(
            disabled
                .force_refusal(ComputeWorkload::Summary, 0)
                .expect("env-disabled blocks a forced run")
                .reason
                .contains("AFTERRAY_T2_SWEEP_SECONDS")
        );
        assert!(
            disabled
                .force_refusal(ComputeWorkload::Archive, 0)
                .is_none()
        );
    }

    /// An override must not paper over the launch switch either: the gate keeps
    /// reporting `disabled_by_env` so the panel does not promise work that a
    /// disabled sweeper will never do.
    #[test]
    fn an_override_cannot_revive_an_env_disabled_workload() {
        let governor = ComputeGovernor::new(
            ComputeMode::Full,
            0,
            ComputeLimits {
                summaries_disabled_by_env: true,
                archive_disabled_by_env: false,
                gpu_probe_disabled_by_env: false,
            },
        );
        governor.force_now(ComputeWorkload::Summary, 0);
        assert_eq!(
            governor
                .decide(ComputeWorkload::Summary, IDEAL, 0)
                .unwrap_err()
                .code,
            ComputeGateCode::DisabledByEnv
        );
    }

    #[test]
    fn the_reported_thresholds_are_the_ones_the_gate_uses() {
        let thresholds = ComputeGovernor::thresholds();
        assert!((thresholds.summary_min_idle_seconds - T2_MIN_IDLE_SECONDS).abs() < f64::EPSILON);
        assert!((thresholds.summary_max_load_per_core - T2_MAX_LOAD_PER_CORE).abs() < f64::EPSILON);
        assert!((thresholds.summary_min_battery_fraction - T2_MIN_BATTERY).abs() < f64::EPSILON);
        assert_eq!(thresholds.force_window_seconds, FORCE_WINDOW.as_secs());
    }

    #[test]
    fn a_forced_gate_reports_its_deadline_to_the_panel() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        let until = governor.force_now(ComputeWorkload::Summary, now);
        let mut counts = WorkloadCounts::default();
        counts.set(ComputeWorkload::Summary, 0, 9);
        let gates = governor.gates(
            MachineConditions {
                on_ac: false,
                ..IDEAL
            },
            now,
            &counts,
        );
        let summary = gates
            .iter()
            .find(|gate| gate.workload == ComputeWorkload::Summary)
            .expect("summary row");
        assert!(summary.allowed);
        assert_eq!(summary.forced_until_ms, Some(until));
        assert_eq!(summary.backlog, 9, "the pile the button promised to drain");
    }

    #[test]
    fn summary_history_keeps_the_newest_passes_and_bounds_itself() {
        let governor = governor(ComputeMode::Full);
        for index in 0..(SUMMARY_HISTORY + 5) {
            governor.record_summary(
                i64::try_from(index).unwrap(),
                1_700_000_000_000 + i64::try_from(index).unwrap(),
                Duration::from_secs(60),
                true,
            );
        }
        let runs = governor.recent_summaries();
        assert_eq!(runs.len(), SUMMARY_HISTORY, "the window is bounded");
        assert_eq!(
            runs[0].slot_start_ms,
            i64::try_from(SUMMARY_HISTORY + 4).unwrap(),
            "newest first"
        );
    }

    /// The estimate the user reads is the median of *successful* passes: a run
    /// that died in nine seconds says nothing about how long a real one takes.
    #[test]
    fn the_typical_duration_ignores_failed_passes() {
        let governor = governor(ComputeMode::Full);
        governor.record_summary(1, 0, Duration::from_secs(9), false);
        assert_eq!(
            afterray_protocol::typical_run_ms(&governor.recent_summaries()),
            None
        );
        governor.record_summary(2, 0, Duration::from_secs(180), true);
        governor.record_summary(3, 0, Duration::from_secs(120), true);
        governor.record_summary(4, 0, Duration::from_secs(150), true);
        assert_eq!(
            afterray_protocol::typical_run_ms(&governor.recent_summaries()),
            Some(150_000)
        );
        assert_eq!(
            governor.recent_summaries().len(),
            4,
            "a failed pass still cost its time, so it stays in the list"
        );
    }

    #[test]
    fn a_seed_fills_an_empty_window_but_never_displaces_a_live_measurement() {
        let seed = [ComputeRun {
            slot_start_ms: 1,
            finished_at_ms: 10,
            duration_ms: 999_000,
            ok: true,
        }];

        let fresh = governor(ComputeMode::Full);
        fresh.seed_summaries(seed);
        assert_eq!(
            afterray_protocol::typical_run_ms(&fresh.recent_summaries()),
            Some(999_000)
        );

        let live = governor(ComputeMode::Full);
        live.record_summary(7, 20, Duration::from_secs(120), true);
        live.seed_summaries(seed);
        assert_eq!(
            live.recent_summaries().len(),
            1,
            "a restart seed must not stack on top of this run's own measurements"
        );
        assert_eq!(
            afterray_protocol::typical_run_ms(&live.recent_summaries()),
            Some(120_000)
        );
    }

    #[test]
    fn the_first_sample_of_a_process_reports_memory_but_not_a_rate() {
        let governor = governor(ComputeMode::Full);
        let (percent, footprint) = governor.sample(std::process::id());
        assert!(
            percent.is_none(),
            "a rate needs two readings; the first must not guess"
        );
        assert!(footprint.is_some_and(|bytes| bytes > 0));

        let (percent, _) = governor.sample(std::process::id());
        assert!(percent.is_some(), "the second reading can measure a rate");
    }

    #[test]
    fn dead_processes_are_forgotten() {
        let governor = governor(ComputeMode::Full);
        governor.sample(std::process::id());
        governor.forget_dead_samples(&[]);
        let (percent, _) = governor.sample(std::process::id());
        assert!(
            percent.is_none(),
            "a forgotten pid starts over rather than measuring against a stale sample"
        );
    }

    #[test]
    fn the_machine_report_carries_the_probes_the_gates_used() {
        let governor = governor(ComputeMode::Full);
        let report = governor.machine_report(IDEAL);
        assert!(report.on_ac);
        assert_eq!(report.battery_fraction, Some(0.9));
        assert!((report.idle_seconds - 600.0).abs() < f64::EPSILON);
    }

    #[test]
    fn capabilities_map_onto_the_rows_the_panel_shows() {
        use afterray_models::ModelCapability;
        use afterray_protocol::ComputeLane;
        assert_eq!(
            workload_for_capability(ModelCapability::Ocr),
            ComputeWorkload::Ocr
        );
        assert_eq!(
            workload_for_capability(ModelCapability::Llm),
            ComputeWorkload::Summary
        );
        assert_eq!(ComputeWorkload::Archive.lane(), ComputeLane::Cpu);
    }

    /// Fifteen fresh readings at `value`, ending at `now` — what the 1 Hz
    /// sampler leaves behind on a machine holding a steady GPU load.
    fn record_steady_gpu(governor: &ComputeGovernor, now: i64, value: f64) {
        for back in (0..i64::try_from(GPU_SAMPLES).unwrap()).rev() {
            governor.record_gpu_utilization(now - back * 1_000, value);
        }
    }

    #[test]
    fn a_quiet_gpu_allows_summaries() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        record_steady_gpu(&governor, now, 0.2);
        assert!(governor.decide(ComputeWorkload::Summary, IDEAL, now).is_ok());
    }

    /// The reason reaches the panel, so it names the measurement: how busy
    /// the GPU is, over which span, against which threshold.
    #[test]
    fn a_busy_gpu_holds_summaries_and_says_how_busy() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        record_steady_gpu(&governor, now, 0.8);
        let refusal = governor
            .decide(ComputeWorkload::Summary, IDEAL, now)
            .unwrap_err();
        assert_eq!(refusal.code, ComputeGateCode::MachineBusy);
        assert!(
            refusal.reason.contains("GPU at 80%") && refusal.reason.contains("50%"),
            "{}",
            refusal.reason
        );
        // Only summaries read the GPU window; the CPU-bound archive path
        // has no GPU to contend for.
        assert!(
            governor
                .decide(ComputeWorkload::Archive, IDEAL, now)
                .is_ok()
        );
    }

    /// Fail-closed like the load average: an unanswered probe is not
    /// permission. The window goes stale when the sampler stops recording —
    /// the probe failing, or the daemon just started.
    #[test]
    fn a_stale_or_empty_gpu_window_holds_summaries() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        let refusal = governor
            .decide(ComputeWorkload::Summary, IDEAL, now)
            .unwrap_err();
        assert_eq!(refusal.code, ComputeGateCode::Unavailable);
        assert_eq!(refusal.reason, "GPU utilization unavailable");

        governor.record_gpu_utilization(now - GPU_WINDOW_MS - 1_000, 0.1);
        let refusal = governor
            .decide(ComputeWorkload::Summary, IDEAL, now)
            .unwrap_err();
        assert_eq!(
            refusal.code,
            ComputeGateCode::Unavailable,
            "a window whose newest reading is stale is no reading at all"
        );
    }

    #[test]
    fn the_env_switch_skips_the_gpu_check_entirely() {
        let governor = ComputeGovernor::new(
            ComputeMode::Full,
            0,
            ComputeLimits {
                summaries_disabled_by_env: false,
                archive_disabled_by_env: false,
                gpu_probe_disabled_by_env: true,
            },
        );
        assert!(
            governor
                .decide(ComputeWorkload::Summary, IDEAL, 0)
                .is_ok(),
            "with the probe switched off, no sampler ever ran and the gate must not wait for one"
        );
    }

    /// "Run now" is newer information than any machine reading, GPU included:
    /// the forced override returns before the workload checks.
    #[test]
    fn run_now_overrides_the_gpu_gate_too() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        record_steady_gpu(&governor, now, 0.9);
        assert!(
            governor
                .decide(ComputeWorkload::Summary, IDEAL, now)
                .is_err()
        );
        governor.force_now(ComputeWorkload::Summary, now);
        assert!(
            governor
                .decide(ComputeWorkload::Summary, IDEAL, now)
                .is_ok()
        );
    }

    /// The window is bounded: a sampler running all day must not grow the
    /// governor's memory, and the gate only ever averages the fresh span.
    #[test]
    fn the_gpu_window_is_bounded() {
        let governor = governor(ComputeMode::Full);
        let now = 1_700_000_000_000;
        for index in 0..(GPU_SAMPLES * 2) {
            governor.record_gpu_utilization(now + i64::try_from(index).unwrap() * 1_000, 0.1);
        }
        let samples = governor.gpu_samples.lock().unwrap();
        assert_eq!(samples.len(), GPU_SAMPLES);
    }
}
