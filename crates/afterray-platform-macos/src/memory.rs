//! How much context this machine can afford.
//!
//! A model's architectural limit is not what you get. Qwen3.5 declares 262 144
//! tokens at both 4B and 9B, but the KV cache for that lives in memory, and on
//! Apple Silicon that memory is shared with everything else on the machine.
//! Ollama therefore picks a default from installed RAM, and a prompt longer
//! than the window is cut **before the model reads it**, with no error. Guessing
//! high does not fail loudly; it fails by quietly deleting the front of the
//! conversation, which is the exact thing compaction exists to do carefully.
//!
//! So the ceiling is chosen the same way Ollama chooses it, from the same
//! numbers, and the probe that reads the machine is kept apart from the
//! arithmetic that decides — one is untestable, the other is where the mistakes
//! would be.

/// One gibibyte, the unit the tiers are stated in.
pub const GIB: u64 = 1024 * 1024 * 1024;

/// Context window to plan for, given total system memory.
///
/// The tiers are Ollama's own (<24 GiB → 4k, 24–48 → 32k, ≥48 → 256k), matched
/// deliberately: a different curve would mean asking for a window the server
/// then silently declines to give, which is worse than asking for less.
///
/// Unified memory is shared with the OS, the browser and everything else, so
/// these are already conservative for a Mac — the tier boundaries assume the
/// whole machine, not a dedicated card.
#[must_use]
pub fn context_tokens_for_memory(total_bytes: u64) -> usize {
    if total_bytes < 24 * GIB {
        4_096
    } else if total_bytes < 48 * GIB {
        32_768
    } else {
        262_144
    }
}

/// Total physical memory, or `None` if the machine will not say.
///
/// On Apple Silicon this is unified memory: the same pool the GPU allocates a
/// KV cache from.
#[must_use]
pub fn total_memory_bytes() -> Option<u64> {
    #[cfg(target_os = "macos")]
    {
        macos::total_memory_bytes()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// What this machine can afford, or the smallest tier when it will not say.
///
/// Fails low on purpose: a window we under-claim costs some room, and one we
/// over-claim costs the front of the user's question without saying so.
#[must_use]
pub fn local_context_tokens() -> usize {
    total_memory_bytes().map_or(4_096, context_tokens_for_memory)
}

#[cfg(target_os = "macos")]
mod macos {
    unsafe extern "C" {
        fn sysctlbyname(
            name: *const core::ffi::c_char,
            oldp: *mut core::ffi::c_void,
            oldlenp: *mut usize,
            newp: *mut core::ffi::c_void,
            newlen: usize,
        ) -> i32;
    }

    pub fn total_memory_bytes() -> Option<u64> {
        let name = c"hw.memsize";
        let mut value: u64 = 0;
        let mut length = size_of::<u64>();
        // SAFETY: `name` is a NUL-terminated literal, and the out-pointer and
        // its length describe the same `u64` that outlives the call.
        let rc = unsafe {
            sysctlbyname(
                name.as_ptr(),
                std::ptr::from_mut(&mut value).cast(),
                &raw mut length,
                std::ptr::null_mut(),
                0,
            )
        };
        (rc == 0 && value > 0).then_some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each boundary, from both sides. These are the only interesting inputs:
    /// everything between two boundaries behaves the same.
    #[test]
    fn the_tiers_match_ollamas_own_boundaries() {
        assert_eq!(context_tokens_for_memory(8 * GIB), 4_096);
        assert_eq!(context_tokens_for_memory(16 * GIB), 4_096);
        // 23.9 GiB is still the small tier; 24 exactly is not.
        assert_eq!(context_tokens_for_memory(24 * GIB - 1), 4_096);
        assert_eq!(context_tokens_for_memory(24 * GIB), 32_768);
        assert_eq!(context_tokens_for_memory(36 * GIB), 32_768);
        assert_eq!(context_tokens_for_memory(48 * GIB - 1), 32_768);
        assert_eq!(context_tokens_for_memory(48 * GIB), 262_144);
        assert_eq!(context_tokens_for_memory(64 * GIB), 262_144);
        assert_eq!(context_tokens_for_memory(128 * GIB), 262_144);
    }

    /// A machine that will not say gets the smallest window, not the largest.
    /// Over-claiming is the failure that deletes the user's question silently.
    #[test]
    fn an_unknown_machine_falls_to_the_smallest_tier() {
        assert_eq!(context_tokens_for_memory(0), 4_096);
    }

    /// The probe agrees with the arithmetic on whatever machine runs the tests.
    #[test]
    fn the_probe_and_the_tiers_agree() {
        let tokens = local_context_tokens();
        assert!(
            [4_096, 32_768, 262_144].contains(&tokens),
            "unexpected tier {tokens}"
        );
        if let Some(bytes) = total_memory_bytes() {
            assert!(bytes >= GIB, "implausible memory reading: {bytes}");
            assert_eq!(tokens, context_tokens_for_memory(bytes));
        }
    }
}
