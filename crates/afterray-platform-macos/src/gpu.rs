//! Machine-wide GPU utilization probe feeding the daemon's summary gate.
//!
//! macOS publishes no per-process GPU accounting, but Apple Silicon exposes a
//! machine-wide figure through public `IOKit`: the `AGXAccelerator` service's
//! `PerformanceStatistics` dictionary carries `Device Utilization %`. A
//! summary pass is the daemon's most expensive background job, and a game or
//! a local LLM elsewhere on the machine is exactly the load the CPU load
//! average cannot see — this probe is how the gate finds out.
//!
//! Like every probe in this crate it fails closed: any step that cannot be
//! answered returns `None`, because the caller reads `None` as "do not run",
//! and a fabricated "idle" would make the daemon pile onto a busy machine.

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::base::{CFAllocatorRef, CFType, CFTypeRef, TCFType, kCFAllocatorDefault};
    use core_foundation::dictionary::{CFDictionary, CFMutableDictionaryRef};
    use core_foundation::number::CFNumber;
    use core_foundation::string::{CFString, CFStringRef};

    // Mach ports and IOKit objects are all `u32` handles; naming them keeps
    // the extern signatures readable without pulling in the mach crate.
    type MachPort = u32;
    type IoIterator = u32;
    type IoObject = u32;
    type IoRegistryEntry = u32;
    type KernReturn = i32;

    // One documented declaration per IOKit symbol, per this crate's rule.

    // Builds the matching dictionary selecting the Apple GPU service.
    // SAFETY: `name` must be NUL-terminated, which the C-string literal at
    // the call site guarantees. The returned dictionary is consumed by
    // `IOServiceGetMatchingServices`, so the caller must not release it.
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceMatching(name: *const core::ffi::c_char) -> CFMutableDictionaryRef;
    }

    // Finds services matching `matching` and hands back an iterator over
    // them. SAFETY: `matching` is a dictionary from `IOServiceMatching` and
    // is consumed by this call; `existing` must point at valid storage for
    // one iterator handle, which outlives the call. Port 0 is the main port
    // default on every supported macOS.
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOServiceGetMatchingServices(
            main_port: MachPort,
            matching: CFMutableDictionaryRef,
            existing: *mut IoIterator,
        ) -> KernReturn;
    }

    // The next object in an iterator, or 0 when it is exhausted.
    // SAFETY: `iterator` must be a live iterator owned by the caller; the
    // returned object is owned by the caller and released below.
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOIteratorNext(iterator: IoIterator) -> IoObject;
    }

    // Copies one named property of a registry entry, following the create
    // rule. SAFETY: `entry` must be a live registry entry; the caller owns
    // the returned object and wraps it under the create rule so its Drop
    // releases it. Returns null when the property does not exist.
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IORegistryEntryCreateCFProperty(
            entry: IoRegistryEntry,
            key: CFStringRef,
            allocator: CFAllocatorRef,
            options: u32,
        ) -> CFTypeRef;
    }

    // Releases one IOKit object, iterators included.
    // SAFETY: `object` must be owned by the caller and released exactly once.
    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOObjectRelease(object: IoObject) -> KernReturn;
    }

    pub fn gpu_utilization() -> Option<f64> {
        let mut iterator: IoIterator = 0;
        let status = unsafe {
            IOServiceGetMatchingServices(
                0,
                IOServiceMatching(c"AGXAccelerator".as_ptr()),
                &raw mut iterator,
            )
        };
        if status != 0 || iterator == 0 {
            return None;
        }
        let service = unsafe { IOIteratorNext(iterator) };
        unsafe { IOObjectRelease(iterator) };
        if service == 0 {
            return None;
        }
        // Request only the statistics sub-dictionary, not the whole property
        // table — the registry carries far more than this one reading.
        let performance_key = CFString::from_static_string("PerformanceStatistics");
        let stats_ref = unsafe {
            IORegistryEntryCreateCFProperty(
                service,
                performance_key.as_concrete_TypeRef(),
                kCFAllocatorDefault,
                0,
            )
        };
        unsafe { IOObjectRelease(service) };
        if stats_ref.is_null() {
            return None;
        }
        // SAFETY: `stats_ref` is a CFDictionary this call owns (create rule);
        // wrapping it under that rule ties its release to the wrapper's Drop.
        let statistics = unsafe {
            CFDictionary::<CFString, CFType>::wrap_under_create_rule(stats_ref.cast())
        };
        // `Device Utilization %` is the AGX key; older drivers answered the
        // same question as `GPU Activity(%)`. Either is a 0–100 percentage.
        let percent = ["Device Utilization %", "GPU Activity(%)"]
            .iter()
            .find_map(|name| {
                let key = CFString::from_static_string(name);
                statistics
                    .find(&key)
                    .and_then(|value| value.downcast::<CFNumber>())
                    .and_then(|number| number.to_f64())
            })?;
        // A fraction, matching `battery_fraction`'s convention.
        Some((percent / 100.0).clamp(0.0, 1.0))
    }
}

// @dec:gpu-utilization-gate — docs/decisions/active/architecture/2026-08-24-gpu-utilization-gate.md
/// Machine-wide GPU utilization as a fraction (`0.0..=1.0`), or `None` when
/// it cannot be read — no AGX service (Intel Macs), no statistics key, any
/// `IOKit` step failing. Callers treat `None` as "unknown", never as "idle".
#[cfg(target_os = "macos")]
#[must_use]
pub fn gpu_utilization() -> Option<f64> {
    macos::gpu_utilization()
}

/// Machine-wide GPU utilization, or `None` — on non-macOS there is no AGX
/// service to ask, so the reading is simply unknown.
#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn gpu_utilization() -> Option<f64> {
    None
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    #[test]
    fn the_agx_service_answers_with_a_fraction() {
        let value = super::gpu_utilization()
            .expect("an Apple Silicon machine has an AGXAccelerator service");
        eprintln!("machine GPU utilization: {value:.3}");
        assert!(
            (0.0..=1.0).contains(&value),
            "utilization out of range: {value}"
        );
    }
}
