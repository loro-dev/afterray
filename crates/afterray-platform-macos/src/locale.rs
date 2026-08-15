//! The user's ordered language preference, read from macOS itself.
//!
//! A GUI-launched daemon has no `LANG`; resolving language from the shell
//! environment silently falls back to English for every real user. This asks
//! the same API System Settings writes.

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::array::{CFArray, CFArrayRef};
    use core_foundation::base::TCFType;
    use core_foundation::string::CFString;

    unsafe extern "C" {
        fn CFLocaleCopyPreferredLanguages() -> CFArrayRef;
    }

    /// BCP-47 tags, most preferred first: `["en-CN", "zh-Hans-CN"]`.
    pub fn preferred_languages() -> Vec<String> {
        unsafe {
            let raw = CFLocaleCopyPreferredLanguages();
            if raw.is_null() {
                return Vec::new();
            }
            let array: CFArray<CFString> = CFArray::wrap_under_create_rule(raw);
            array.iter().map(|value| value.to_string()).collect()
        }
    }
}

#[cfg(target_os = "macos")]
pub use macos::preferred_languages;

#[cfg(not(target_os = "macos"))]
#[must_use]
pub fn preferred_languages() -> Vec<String> {
    Vec::new()
}
