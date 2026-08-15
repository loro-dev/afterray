//! Episode segmentation from accessibility snapshots.
//!
//! Episodes are cut in real time — an identity-key change closes one — but
//! deliberately never summarised by a model here. The live capture path stays
//! deterministic and free; all model spend belongs to the deferred T2 pass,
//! which reconstructs the story from richer evidence anyway. The stored
//! summary is the digest's deterministic fallback line.

use afterray_protocol::Memory;
use afterray_store::{
    AccessibilityDigest, Vault, digest_fingerprint, is_idle_digest, parse_accessibility_digest,
};
use std::sync::Mutex;
use uuid::Uuid;

const MIN_MEMORY_MS: i64 = 45_000;

#[derive(Debug, Clone)]
struct OpenEpisode {
    start_ms: i64,
    last_ms: i64,
    moment_id: String,
    digest: AccessibilityDigest,
    fingerprint: String,
}

#[derive(Default)]
pub(crate) struct MemoryRuntime {
    open: Option<OpenEpisode>,
}

impl MemoryRuntime {
    fn observe(
        &mut self,
        store: &Vault,
        captured_at_ms: i64,
        moment_id: &str,
        digest: AccessibilityDigest,
    ) -> Option<OpenEpisode> {
        if is_idle_digest(&digest) {
            return self.open.take();
        }
        let fingerprint = digest_fingerprint(&digest);
        if let Some(latest) = store.latest_memory().ok().flatten()
            && latest.fingerprint == fingerprint
        {
            if let Some(open) = &mut self.open {
                open.last_ms = captured_at_ms.max(open.last_ms);
                moment_id.clone_into(&mut open.moment_id);
            }
            return None;
        }
        match self.open.take() {
            Some(mut open) if open.digest.identity_key() == digest.identity_key() => {
                open.last_ms = captured_at_ms.max(open.last_ms);
                moment_id.clone_into(&mut open.moment_id);
                open.digest = digest;
                open.fingerprint = fingerprint;
                self.open = Some(open);
                None
            }
            Some(previous) => {
                self.open = Some(OpenEpisode {
                    start_ms: captured_at_ms,
                    last_ms: captured_at_ms,
                    moment_id: moment_id.to_owned(),
                    digest,
                    fingerprint,
                });
                Some(previous)
            }
            None => {
                self.open = Some(OpenEpisode {
                    start_ms: captured_at_ms,
                    last_ms: captured_at_ms,
                    moment_id: moment_id.to_owned(),
                    digest,
                    fingerprint,
                });
                None
            }
        }
    }

    fn close(&mut self) -> Option<OpenEpisode> {
        self.open.take()
    }
}

pub(crate) fn observe_and_maybe_commit(
    store: &Vault,
    runtime: &Mutex<MemoryRuntime>,
    captured_at_ms: i64,
    moment_id: &str,
    snapshot: &[u8],
) {
    let digest = parse_accessibility_digest(snapshot);
    let closed = runtime
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .observe(store, captured_at_ms, moment_id, digest);
    if let Some(episode) = closed {
        commit_episode(store, episode);
    }
}

pub(crate) fn flush(store: &Vault, runtime: &Mutex<MemoryRuntime>) {
    let closed = runtime
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .close();
    if let Some(episode) = closed {
        commit_episode(store, episode);
    }
}

fn commit_episode(store: &Vault, episode: OpenEpisode) {
    if episode.last_ms.saturating_sub(episode.start_ms) < MIN_MEMORY_MS {
        return;
    }
    if let Some(latest) = store.latest_memory().ok().flatten()
        && latest.fingerprint == episode.fingerprint
    {
        return;
    }
    let memory = Memory {
        id: Uuid::now_v7().to_string(),
        start_ms: episode.start_ms,
        end_ms: episode.last_ms.max(episode.start_ms + MIN_MEMORY_MS),
        moment_id: Some(episode.moment_id),
        application_name: episode.digest.application_name.clone(),
        bundle_identifier: episode.digest.bundle_identifier.clone(),
        window_title: episode.digest.window_title.clone(),
        url: episode.digest.url.clone(),
        document: episode.digest.document.clone(),
        summary: episode.digest.fallback_summary(),
        fingerprint: episode.fingerprint,
    };
    if let Err(error) = store.insert_memory(&memory) {
        eprintln!("could not store memory: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_store::{Vault, VaultConfig};

    fn test_vault() -> (tempfile::TempDir, Vault) {
        let directory = tempfile::tempdir().unwrap();
        let vault = Vault::open_with_key(
            VaultConfig {
                data_dir: directory.path().to_path_buf(),
                ..VaultConfig::default()
            },
            [9_u8; 32],
        )
        .unwrap();
        (directory, vault)
    }

    #[test]
    fn duplicate_fingerprint_does_not_reopen() {
        let (_dir, vault) = test_vault();
        let session = vault.create_session_sync(1).unwrap();
        let first = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"one")
            .unwrap();
        let digest = AccessibilityDigest {
            application_name: Some("Safari".into()),
            bundle_identifier: Some("com.apple.Safari".into()),
            window_title: Some("Example".into()),
            url: Some("https://example.com/".into()),
            ..AccessibilityDigest::default()
        };
        vault
            .insert_memory(&Memory {
                id: "mem1".into(),
                start_ms: 0,
                end_ms: 60_000,
                moment_id: Some(first.id.clone()),
                application_name: digest.application_name.clone(),
                bundle_identifier: digest.bundle_identifier.clone(),
                window_title: digest.window_title.clone(),
                url: digest.url.clone(),
                document: None,
                summary: "Used Safari.".into(),
                fingerprint: digest_fingerprint(&digest),
            })
            .unwrap();
        let mut runtime = MemoryRuntime::default();
        let closed = runtime.observe(&vault, 70_000, &first.id, digest);
        assert!(closed.is_none());
    }
}
