//! Per-process cost probes, for showing the user what local computation is
//! actually costing them.
//!
//! Deliberately not GPU: `macOS` has no public per-process GPU accounting, and
//! the only route to even a machine-wide number is the private `IOReport`
//! framework. A number that says "this job is using 40% GPU" would be invented,
//! so this module reports CPU time and memory footprint — which *are*
//! attributable to a pid — and the daemon labels each job with the lane it
//! occupies instead.

/// A cumulative CPU-time and memory reading for one process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProcessUsage {
    /// User + system CPU time since the process started, in nanoseconds.
    pub cpu_time_ns: u64,
    /// Physical footprint — the number Activity Monitor calls "Memory".
    pub footprint_bytes: u64,
}

impl ProcessUsage {
    /// CPU busy percentage between two readings, as a share of one core.
    ///
    /// A four-thread encoder legitimately reports 400%: the number answers
    /// "how much of the machine is this taking", and clamping it to 100 would
    /// hide exactly the case the user opened the panel to find.
    #[must_use]
    pub fn cpu_percent_since(self, earlier: Self, elapsed: std::time::Duration) -> Option<f64> {
        let elapsed_ns = u64::try_from(elapsed.as_nanos()).ok()?;
        if elapsed_ns == 0 {
            return None;
        }
        let busy_ns = self.cpu_time_ns.checked_sub(earlier.cpu_time_ns)?;
        #[expect(
            clippy::cast_precision_loss,
            reason = "nanosecond counts stay far below f64's exact range"
        )]
        Some((busy_ns as f64 / elapsed_ns as f64) * 100.0)
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::ProcessUsage;

    /// `RUSAGE_INFO_V0` — the oldest flavour, and the only one whose layout is
    /// guaranteed not to move under us. Everything this panel shows is in it.
    const RUSAGE_INFO_V0: i32 = 0;

    /// `struct rusage_info_v0` from `<libproc.h>`, field for field.
    ///
    /// The times are **mach absolute time**, not nanoseconds, whatever the
    /// field names suggest: on Apple Silicon the timebase is 125/3, so reading
    /// them raw under-reports CPU by ~42×. Measured, not assumed — a spinning
    /// thread reported 2.4% before `mach_timebase_info` was applied
    /// (`measured_cpu_time_is_in_nanoseconds` below is the guard).
    /// `ri_phys_footprint` is the Activity Monitor "Memory" column.
    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    #[expect(
        clippy::struct_field_names,
        reason = "the field names are C's, and renaming them would hide which header this mirrors"
    )]
    struct RUsageInfoV0 {
        ri_uuid: [u8; 16],
        ri_user_time: u64,
        ri_system_time: u64,
        ri_pkg_idle_wkups: u64,
        ri_interrupt_wkups: u64,
        ri_pageins: u64,
        ri_wired_size: u64,
        ri_resident_size: u64,
        ri_phys_footprint: u64,
        ri_proc_start_abstime: u64,
        ri_proc_exit_abstime: u64,
    }

    #[repr(C)]
    #[derive(Default, Clone, Copy)]
    struct MachTimebaseInfo {
        numer: u32,
        denom: u32,
    }

    unsafe extern "C" {
        fn proc_pid_rusage(pid: i32, flavor: i32, buffer: *mut RUsageInfoV0) -> i32;
        fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
    }

    /// Cached because it cannot change while the process lives, and the panel
    /// samples every process every couple of seconds.
    fn timebase() -> (u64, u64) {
        static TIMEBASE: std::sync::OnceLock<(u64, u64)> = std::sync::OnceLock::new();
        *TIMEBASE.get_or_init(|| {
            let mut info = MachTimebaseInfo::default();
            if unsafe { mach_timebase_info(&raw mut info) } != 0
                || info.numer == 0
                || info.denom == 0
            {
                // Intel's identity timebase is the safe guess: it leaves the
                // reading unscaled rather than inventing a multiplier.
                return (1, 1);
            }
            (u64::from(info.numer), u64::from(info.denom))
        })
    }

    fn absolute_to_nanos(ticks: u64) -> u64 {
        let (numer, denom) = timebase();
        ticks
            .checked_mul(numer)
            .map_or_else(|| (ticks / denom).saturating_mul(numer), |scaled| {
                scaled / denom
            })
    }

    /// `None` when the process is gone, or belongs to another user — both mean
    /// "nothing to show", never "zero cost".
    pub fn process_usage(pid: u32) -> Option<ProcessUsage> {
        let pid = i32::try_from(pid).ok()?;
        let mut info = RUsageInfoV0::default();
        let rc = unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V0, &raw mut info) };
        if rc != 0 {
            return None;
        }
        Some(ProcessUsage {
            cpu_time_ns: absolute_to_nanos(
                info.ri_user_time.saturating_add(info.ri_system_time),
            ),
            footprint_bytes: if info.ri_phys_footprint > 0 {
                info.ri_phys_footprint
            } else {
                info.ri_resident_size
            },
        })
    }

    /// System thermal pressure, as the OS reports it to every app.
    ///
    /// `OSThermalNotificationLevel` is a private symbol; this reads the same
    /// state through the public `sysctl` the kernel exports. Absent on Intel,
    /// which is why the caller treats `None` as "no thermal reading".
    pub fn thermal_pressure() -> Option<u32> {
        crate::sysctl::scalar::<u32>(c"machdep.xcpm.cpu_thermal_level")
    }
}

/// CPU time and memory footprint for one process, or `None` if it cannot be
/// read.
#[cfg(target_os = "macos")]
#[must_use]
pub fn process_usage(pid: u32) -> Option<ProcessUsage> {
    macos::process_usage(pid)
}

/// CPU time and memory footprint for this process. Test-only: the daemon samples
/// its own pid through the same `process_usage` path as every worker.
#[cfg(test)]
fn current_process_usage() -> Option<ProcessUsage> {
    process_usage(std::process::id())
}

/// Thermal level, when the platform reports one. Higher means hotter; the
/// scale is not documented, so callers should only compare it against zero.
#[cfg(target_os = "macos")]
#[must_use]
pub fn thermal_pressure() -> Option<u32> {
    macos::thermal_pressure()
}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn process_usage(_pid: u32) -> Option<ProcessUsage> {
    None
}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn thermal_pressure() -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn cpu_percent_is_a_share_of_one_core() {
        let earlier = ProcessUsage {
            cpu_time_ns: 1_000_000_000,
            footprint_bytes: 0,
        };
        let later = ProcessUsage {
            cpu_time_ns: 1_500_000_000,
            footprint_bytes: 0,
        };
        let percent = later
            .cpu_percent_since(earlier, Duration::from_secs(1))
            .expect("a one-second window is measurable");
        assert!((percent - 50.0).abs() < 0.001, "got {percent}");
    }

    #[test]
    fn a_restarted_counter_does_not_wrap_into_a_huge_percentage() {
        let earlier = ProcessUsage {
            cpu_time_ns: 5_000_000_000,
            footprint_bytes: 0,
        };
        let later = ProcessUsage {
            cpu_time_ns: 1_000_000_000,
            footprint_bytes: 0,
        };
        assert!(
            later
                .cpu_percent_since(earlier, Duration::from_secs(1))
                .is_none()
        );
    }

    /// The unit of `ri_user_time` is the one thing here that reading the header
    /// cannot settle, and getting it wrong under-reports every number in the
    /// panel by ~42× on Apple Silicon. Burn a known amount of CPU on one
    /// thread and assert the measured share of a core lands near 100%.
    #[cfg(target_os = "macos")]
    #[test]
    fn measured_cpu_time_is_in_nanoseconds() {
        let before = current_process_usage().expect("this process can read its own usage");
        let started = Instant::now();
        // Spin, do not sleep: sleeping accrues no CPU time and would pass
        // against a broken unit as easily as a correct one.
        let mut sink = 0_u64;
        while started.elapsed() < Duration::from_millis(300) {
            sink = sink.wrapping_add(u64::try_from(started.elapsed().as_nanos()).unwrap_or(1) | 1);
        }
        assert_ne!(sink, 0);
        let elapsed = started.elapsed();
        let after = current_process_usage().expect("this process can read its own usage");
        let percent = after
            .cpu_percent_since(before, elapsed)
            .expect("the counter moved forward");
        assert!(
            percent > 60.0,
            "a busy-spinning thread should report most of a core, got {percent:.1}% \
             — ri_user_time is probably not nanoseconds"
        );
        assert!(
            after.footprint_bytes > 0,
            "a live process has a memory footprint"
        );
    }
}
