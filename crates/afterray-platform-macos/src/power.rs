//! Power and load probes for deciding whether expensive background work may
//! run. Every probe fails closed: unknown means "do not run".

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::array::CFArray;
    use core_foundation::base::{CFRelease, CFType, CFTypeRef, TCFType};
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::number::CFNumber;
    use core_foundation::string::CFString;

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
        fn IOPSCopyPowerSourcesList(blob: CFTypeRef) -> CFTypeRef;
        fn IOPSGetPowerSourceDescription(blob: CFTypeRef, ps: CFTypeRef) -> CFTypeRef;
    }

    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        fn CGEventSourceSecondsSinceLastEventType(state: u32, event_type: u32) -> f64;
    }

    unsafe extern "C" {
        fn getloadavg(loadavg: *mut f64, nelem: i32) -> i32;
    }

    /// Drop this thread to background QoS so rav1e cannot starve ScreenCaptureKit.
    pub fn apply_background_qos() {
        const QOS_CLASS_BACKGROUND: u32 = 0x09;
        unsafe extern "C" {
            fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) -> i32;
        }
        let rc = unsafe { pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) };
        if rc != 0 {
            eprintln!("could not set background QoS ({rc})");
        }
    }

    /// Charge as a fraction of full. `None` on a machine with no battery — a
    /// desk Mac has nothing to conserve, and callers read that as "fine".
    pub fn battery_fraction() -> Option<f64> {
        unsafe {
            let info = IOPSCopyPowerSourcesInfo();
            if info.is_null() {
                return None;
            }
            let list_ref = IOPSCopyPowerSourcesList(info);
            if list_ref.is_null() {
                CFRelease(info);
                return None;
            }
            let list = CFArray::<CFTypeRef>::wrap_under_create_rule(list_ref.cast());
            let current_key = CFString::from_static_string("Current Capacity");
            let max_key = CFString::from_static_string("Max Capacity");
            let mut fraction = None;
            for source in list.iter() {
                let description = IOPSGetPowerSourceDescription(info, *source);
                if description.is_null() {
                    continue;
                }
                let dict =
                    CFDictionary::<CFString, CFType>::wrap_under_get_rule(description.cast());
                let current = dict
                    .find(&current_key)
                    .and_then(|value| value.downcast::<CFNumber>())
                    .and_then(|number| number.to_f64());
                let max = dict
                    .find(&max_key)
                    .and_then(|value| value.downcast::<CFNumber>())
                    .and_then(|number| number.to_f64());
                if let (Some(current), Some(max)) = (current, max)
                    && max > 0.0
                {
                    fraction = Some((current / max).clamp(0.0, 1.0));
                    break;
                }
            }
            CFRelease(info);
            fraction
        }
    }

    /// Seconds since the last keyboard or pointer event anywhere in the system.
    pub fn seconds_since_user_input() -> f64 {
        // kCGAnyInputEventType across the combined session state: any HID
        // activity in any app counts, not just events this process saw.
        const COMBINED_SESSION_STATE: u32 = 0;
        const ANY_INPUT_EVENT: u32 = 0xFFFF_FFFF;
        let seconds = unsafe {
            CGEventSourceSecondsSinceLastEventType(COMBINED_SESSION_STATE, ANY_INPUT_EVENT)
        };
        if seconds.is_finite() && seconds >= 0.0 {
            seconds
        } else {
            0.0
        }
    }

    /// One-minute load average divided by core count, so the number means the
    /// same thing on an 8-core laptop and a 24-core desktop.
    pub fn load_per_core() -> Option<f64> {
        let mut samples = [0.0_f64; 3];
        let filled = unsafe { getloadavg(samples.as_mut_ptr(), 3) };
        if filled < 1 {
            return None;
        }
        let cores = std::thread::available_parallelism()
            .map(std::num::NonZeroUsize::get)
            .unwrap_or(1);
        #[expect(clippy::cast_precision_loss, reason = "core counts are tiny")]
        Some(samples[0] / cores as f64)
    }

    pub fn on_ac_power() -> bool {
        unsafe {
            let info = IOPSCopyPowerSourcesInfo();
            if info.is_null() {
                return false;
            }
            let list_ref = IOPSCopyPowerSourcesList(info);
            if list_ref.is_null() {
                CFRelease(info);
                return false;
            }
            let list = CFArray::<CFTypeRef>::wrap_under_create_rule(list_ref.cast());
            let state_key = CFString::from_static_string("Power Source State");
            let mut on_ac = false;
            for source in list.iter() {
                let description = IOPSGetPowerSourceDescription(info, *source);
                if description.is_null() {
                    continue;
                }
                let dict =
                    CFDictionary::<CFString, CFString>::wrap_under_get_rule(description.cast());
                if let Some(state) = dict.find(&state_key) {
                    let state = state.to_string();
                    if state == "AC Power" {
                        on_ac = true;
                        break;
                    }
                }
            }
            CFRelease(info);
            on_ac
        }
    }
}

#[cfg(target_os = "macos")]
#[must_use]
pub fn on_ac_power() -> bool {
    macos::on_ac_power()
}

#[cfg(target_os = "macos")]
pub fn apply_background_qos() {
    macos::apply_background_qos();
}

#[cfg(target_os = "macos")]
#[must_use]
pub fn battery_fraction() -> Option<f64> {
    macos::battery_fraction()
}

#[cfg(target_os = "macos")]
#[must_use]
pub fn seconds_since_user_input() -> f64 {
    macos::seconds_since_user_input()
}

#[cfg(target_os = "macos")]
#[must_use]
pub fn load_per_core() -> Option<f64> {
    macos::load_per_core()
}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn on_ac_power() -> bool {
    true
}

#[cfg(not(target_os = "macos"))]
pub fn apply_background_qos() {}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn battery_fraction() -> Option<f64> {
    None
}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn seconds_since_user_input() -> f64 {
    f64::MAX
}

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn load_per_core() -> Option<f64> {
    None
}
