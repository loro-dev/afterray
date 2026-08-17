//! Identity of a Unix-socket peer. Used by the daemon to tell the
//! AfterRay.app process apart from `afterray` on PATH and from other
//! same-user processes.

use std::path::{Path, PathBuf};

/// `getsockopt(LOCAL_PEERPID)` + `proc_pidpath`. `fd` is the accepted
/// connection, not the listening socket.
#[must_use]
pub fn peer_executable_path(fd: i32) -> Option<PathBuf> {
    process_path(peer_pid(fd)?)
}

#[must_use]
pub fn peer_is_afterray_app(fd: i32) -> bool {
    peer_executable_path(fd).is_some_and(|path| is_afterray_app_executable(&path))
}

/// The packaged app, the `afterray-app` Swift package product, or anything
/// inside `AfterRay.app`. The CLI binary is named `afterray` and does not
/// match.
#[must_use]
pub fn is_afterray_app_executable(path: &Path) -> bool {
    if path.components().any(|component| component.as_os_str() == "AfterRay.app") {
        return true;
    }
    matches!(
        path.file_name().and_then(|name| name.to_str()),
        Some("AfterRay" | "afterray-app")
    )
}

fn peer_pid(fd: i32) -> Option<u32> {
    #[cfg(target_os = "macos")]
    {
        let mut pid: libc::pid_t = 0;
        let mut len = libc::socklen_t::try_from(std::mem::size_of::<libc::pid_t>()).unwrap_or(0);
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                std::ptr::from_mut(&mut pid).cast(),
                &raw mut len,
            )
        };
        if rc == 0 && pid > 0 {
            u32::try_from(pid).ok()
        } else {
            None
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = fd;
        None
    }
}

fn process_path(pid: u32) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let mut buf = [0i8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        let n = unsafe {
            libc::proc_pidpath(
                i32::try_from(pid).ok()?,
                buf.as_mut_ptr().cast(),
                u32::try_from(buf.len()).unwrap_or(0),
            )
        };
        if n <= 0 {
            return None;
        }
        let bytes = unsafe {
            std::slice::from_raw_parts(buf.as_ptr().cast::<u8>(), usize::try_from(n).ok()?)
        };
        Some(PathBuf::from(std::str::from_utf8(bytes).ok()?))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = pid;
        None
    }
}

#[cfg(test)]
mod tests {
    use super::is_afterray_app_executable;
    use std::path::Path;

    #[test]
    fn packaged_and_dev_app_binaries_match() {
        assert!(is_afterray_app_executable(Path::new(
            "/Applications/AfterRay.app/Contents/MacOS/AfterRay"
        )));
        assert!(is_afterray_app_executable(Path::new(
            "/tmp/.build/debug/afterray-app"
        )));
        assert!(!is_afterray_app_executable(Path::new(
            "/Users/me/.local/bin/afterray"
        )));
        assert!(!is_afterray_app_executable(Path::new(
            "/opt/homebrew/bin/claude"
        )));
    }
}
