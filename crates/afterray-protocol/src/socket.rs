//! Where the daemon listens and every client connects.
//!
//! The daemon and the CLI used to answer this question separately, and both
//! fell back to `$TMPDIR/afterray-v0.sock`. That is wrong twice over: `/tmp`
//! is world-writable, so any process can pre-bind the path a daemon is about
//! to take, and it is never where the app's daemon actually listens — a CLI
//! installed from the app talked to nothing at all. One resolver, no `/tmp`.

use std::path::{Path, PathBuf};

/// Overrides everything else so a development build can point at its
/// checkout, and so tests can run against a throwaway socket.
pub const SOCKET_ENV: &str = "AFTERRAY_SOCKET";

/// Resolution order: the environment, then a socket inside the checkout when
/// this binary is a `cargo build` artifact, then the installed location.
///
/// # Errors
///
/// Fails when there is no home directory to resolve the installed location
/// against. Falling back to a temporary directory is not an option here.
pub fn default_socket_path() -> std::io::Result<PathBuf> {
    if let Some(path) = std::env::var_os(SOCKET_ENV).filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(path));
    }
    if let Some(path) = std::env::current_exe()
        .ok()
        .as_deref()
        .and_then(development_socket_path)
    {
        return Ok(path);
    }
    installed_socket_path()
}

/// `~/Library/Application Support/AfterRay/afterray.sock` — the same path
/// `DaemonSupervisor` hands the daemon it spawns, and the same directory the
/// vault lives in, which the store keeps at `0700`.
///
/// # Errors
///
/// Fails when the Application Support directory cannot be resolved.
pub fn installed_socket_path() -> std::io::Result<PathBuf> {
    let data_dir = dirs::data_dir().ok_or_else(|| {
        std::io::Error::other(
            "could not resolve the Application Support directory; set AFTERRAY_SOCKET",
        )
    })?;
    Ok(data_dir.join("AfterRay").join("afterray.sock"))
}

/// A binary at `<checkout>/target/{debug,release}/x` belongs to a source
/// build. The checkout identifies the socket, but cannot contain it: macOS's
/// Unix socket path limit is shorter than a typical Lody worktree path.
/// Keying on the executable rather than the working directory also prevents an
/// attacker-chosen cwd from redirecting the CLI.
fn development_socket_path(executable: &Path) -> Option<PathBuf> {
    let profile_dir = executable.parent()?;
    if !matches!(profile_dir.file_name()?.to_str()?, "debug" | "release") {
        return None;
    }
    let target_dir = profile_dir.parent()?;
    if target_dir.file_name()?.to_str()? != "target" {
        return None;
    }
    let checkout = target_dir.parent()?;
    let canonical = std::fs::canonicalize(checkout).unwrap_or_else(|_| checkout.to_path_buf());
    let token = fnv1a64(canonical.to_string_lossy().as_bytes());
    Some(
        dirs::cache_dir()?
            .join("AfterRay")
            .join("DevSockets")
            .join(format!("{token:016x}.sock")),
    )
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 14_695_981_039_346_656_037_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cargo_artifact_resolves_the_checkout_socket() {
        let release =
            development_socket_path(Path::new("/Users/dev/afterray/target/release/afterray"))
                .unwrap();
        let debug =
            development_socket_path(Path::new("/Users/dev/afterray/target/debug/afterrayd"))
                .unwrap();
        assert_eq!(release, debug);
        assert_eq!(
            release.extension().and_then(|value| value.to_str()),
            Some("sock")
        );
        assert!(!release.starts_with("/Users/dev/afterray"), "{release:?}");
        assert!(release.as_os_str().len() < 104, "{release:?}");
    }

    #[test]
    fn checkout_hash_matches_the_cross_language_test_vector() {
        assert_eq!(fnv1a64(b"hello"), 0xa430_d846_80aa_bd0b);
    }

    #[test]
    fn an_installed_binary_is_not_a_development_build() {
        assert_eq!(
            development_socket_path(Path::new("/Users/dev/.local/bin/afterray")),
            None
        );
        assert_eq!(
            development_socket_path(Path::new(
                "/Applications/AfterRay.app/Contents/Helpers/afterray"
            )),
            None
        );
        // `release` alone is not a cargo layout: the parent has to be `target`.
        assert_eq!(
            development_socket_path(Path::new("/tmp/release/afterray")),
            None
        );
    }

    #[test]
    fn the_installed_socket_sits_beside_the_vault() {
        let path = installed_socket_path().unwrap();
        assert!(path.ends_with("AfterRay/afterray.sock"), "{path:?}");
        assert!(!path.starts_with(std::env::temp_dir()), "{path:?}");
    }
}
