//! One `sysctl` reader for the whole crate.
//!
//! Extracted because two probes wanted the same libc call and the second copy
//! arrived without the SAFETY note. This crate is the workspace's only
//! `#![allow(unsafe_code)]` exception, so one documented declaration is the
//! whole point.

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn sysctlbyname(
        name: *const core::ffi::c_char,
        oldp: *mut core::ffi::c_void,
        oldlenp: *mut usize,
        newp: *mut core::ffi::c_void,
        newlen: usize,
    ) -> i32;
}

/// Reads one scalar `sysctl` by name, or `None` when the key does not exist on
/// this machine — which is normal: several of these are Apple-Silicon-only.
#[cfg(target_os = "macos")]
pub(crate) fn scalar<T: Copy + Default>(name: &core::ffi::CStr) -> Option<T> {
    let mut value = T::default();
    let mut length = size_of::<T>();
    // SAFETY: `name` is NUL-terminated by `CStr`, and the out-pointer and its
    // length describe the same `T`, which outlives the call.
    let rc = unsafe {
        sysctlbyname(
            name.as_ptr(),
            std::ptr::from_mut(&mut value).cast(),
            &raw mut length,
            std::ptr::null_mut(),
            0,
        )
    };
    (rc == 0 && length == size_of::<T>()).then_some(value)
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn scalar<T: Copy + Default>(_name: &core::ffi::CStr) -> Option<T> {
    None
}
