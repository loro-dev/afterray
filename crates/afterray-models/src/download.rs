use crate::Cancellation;
use crate::catalog::{
    ManifestFile, PackSource, PackSpec, READY_MARKER, SnapshotPin, inspect_model_path,
};
use afterray_protocol::ModelPackState;
use futures_util::StreamExt as _;
use serde::Deserialize;
use sha2::{Digest as _, Sha256};
use std::{
    fs,
    fs::OpenOptions,
    io::{self, Read as _},
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::AsyncWriteExt as _;

#[derive(Debug, thiserror::Error)]
pub enum DownloadError {
    #[error("{0}")]
    Message(String),
    #[error("download I/O failed: {0}")]
    Io(#[from] io::Error),
    #[error("download request failed: {0}")]
    Http(String),
    #[error("model download was cancelled")]
    Cancelled,
}

impl DownloadError {
    fn message(message: impl Into<String>) -> Self {
        Self::Message(message.into())
    }
}

#[derive(Debug, Clone, Copy)]
pub struct DownloadProgress {
    pub state: ModelPackState,
    pub completed_files: usize,
    pub total_files: usize,
    pub bytes: u64,
    pub expected_bytes: Option<u64>,
}

impl DownloadProgress {
    #[must_use]
    pub fn percent(self) -> Option<u8> {
        let expected = self.expected_bytes.filter(|value| *value > 0)?;
        let percent = self.bytes.saturating_mul(100) / expected;
        Some(u8::try_from(percent.min(100)).unwrap_or(100))
    }
}

/// Downloads every pack that is not already present.
///
/// # Errors
///
/// Returns a [`DownloadError`] when a listing or file transfer fails.
pub async fn download_packs(
    packs: &[PackSpec],
    on_progress: impl FnMut(&PackSpec, DownloadProgress),
) -> Result<(), DownloadError> {
    download_packs_with_cancellation(packs, Cancellation::default(), on_progress).await
}

/// Downloads every requested pack until completion or cooperative cancellation.
/// Partial files are deliberately preserved so a paused download can resume.
pub async fn download_packs_with_cancellation(
    packs: &[PackSpec],
    cancellation: Cancellation,
    mut on_progress: impl FnMut(&PackSpec, DownloadProgress),
) -> Result<(), DownloadError> {
    for pack in packs {
        download_pack_with_cancellation(pack, cancellation.clone(), |progress| {
            on_progress(pack, progress);
        })
        .await?;
    }
    Ok(())
}

/// Downloads one pack into `pack.path`.
///
/// # Errors
///
/// Returns a [`DownloadError`] when Hugging Face cannot be reached or the
/// destination cannot be written.
pub async fn download_pack(
    pack: &PackSpec,
    on_progress: impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
    download_pack_with_cancellation(pack, Cancellation::default(), on_progress).await
}

pub async fn download_pack_with_cancellation(
    pack: &PackSpec,
    cancellation: Cancellation,
    mut on_progress: impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
    ensure_not_cancelled(&cancellation)?;
    if pack.inspect().present {
        let bytes = inspect_model_path(&pack.path).1;
        on_progress(DownloadProgress {
            state: ModelPackState::Ready,
            completed_files: 1,
            total_files: 1,
            bytes,
            expected_bytes: Some(bytes.max(1)),
        });
        return Ok(());
    }
    match &pack.source {
        PackSource::HuggingFaceFile {
            repository,
            file,
            revision,
            sha256,
        } => {
            if let Some(parent) = pack.path.parent() {
                fs::create_dir_all(parent)?;
            }
            download_huggingface_file(
                repository,
                revision,
                file,
                &pack.path,
                sha256.as_ref().map(|_| pack.expected_bytes),
                sha256.as_deref(),
                &cancellation,
                |bytes, expected| {
                    on_progress(DownloadProgress {
                        state: ModelPackState::Downloading,
                        completed_files: 0,
                        total_files: 1,
                        bytes,
                        expected_bytes: expected.or(Some(pack.expected_bytes)),
                    });
                },
            )
            .await?;
            let bytes = inspect_model_path(&pack.path).1;
            on_progress(DownloadProgress {
                state: ModelPackState::Ready,
                completed_files: 1,
                total_files: 1,
                bytes,
                expected_bytes: Some(bytes.max(pack.expected_bytes)),
            });
        }
        PackSource::HuggingFaceSnapshot {
            repository,
            pin: Some(pin),
        } => {
            download_snapshot_with_pin(pack, repository, pin, &cancellation, &mut on_progress)
                .await?;
        }
        PackSource::HuggingFaceSnapshot {
            repository,
            pin: None,
        } => {
            fs::create_dir_all(&pack.path)?;
            let files = list_huggingface_files(repository, &cancellation).await?;
            let total_files = files.len();
            if total_files == 0 {
                return Err(DownloadError::message(format!(
                    "Hugging Face repository `{repository}` listed no files"
                )));
            }
            let listed_total: u64 = files.iter().filter_map(|file| file.size).sum();
            let expected = if listed_total > 0 {
                Some(listed_total)
            } else {
                Some(pack.expected_bytes)
            };
            let mut finished_bytes = 0_u64;
            for (index, file) in files.iter().enumerate() {
                ensure_not_cancelled(&cancellation)?;
                let destination = pack.path.join(&file.path);
                if destination.is_file() {
                    finished_bytes += file
                        .size
                        .unwrap_or_else(|| inspect_model_path(&destination).1);
                    on_progress(DownloadProgress {
                        state: ModelPackState::Downloading,
                        completed_files: index + 1,
                        total_files,
                        bytes: finished_bytes,
                        expected_bytes: expected,
                    });
                    continue;
                }
                if let Some(parent) = destination.parent() {
                    fs::create_dir_all(parent)?;
                }
                download_huggingface_file(
                    repository,
                    "main",
                    &file.path,
                    &destination,
                    file.size,
                    None,
                    &cancellation,
                    |written, _| {
                        on_progress(DownloadProgress {
                            state: ModelPackState::Downloading,
                            completed_files: index,
                            total_files,
                            bytes: finished_bytes.saturating_add(written),
                            expected_bytes: expected,
                        });
                    },
                )
                .await?;
                finished_bytes += file
                    .size
                    .unwrap_or_else(|| inspect_model_path(&destination).1);
                on_progress(DownloadProgress {
                    state: ModelPackState::Downloading,
                    completed_files: index + 1,
                    total_files,
                    bytes: finished_bytes,
                    expected_bytes: expected,
                });
            }
        }
        PackSource::HuggingFacePinnedSnapshot {
            repository,
            revision,
            files,
        } => {
            download_pinned_snapshot(
                pack,
                repository,
                revision,
                files,
                &cancellation,
                &mut on_progress,
            )
            .await?;
        }
    }
    Ok(())
}

/// Removes one catalog pack and any resumable staging directory next to it.
///
/// # Errors
///
/// Returns an error when a pack file cannot be removed.
pub fn remove_pack(pack: &PackSpec) -> Result<(), DownloadError> {
    remove_path_if_present(&pack.path)?;
    remove_path_if_present(&partial_path(&pack.path))?;
    if matches!(pack.source, PackSource::HuggingFacePinnedSnapshot { .. }) {
        remove_path_if_present(&staging_path(&pack.path))?;
    }
    Ok(())
}

fn remove_path_if_present(path: &Path) -> Result<(), DownloadError> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(());
    };
    if metadata.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

/// Downloads a pinned snapshot into the pack's plain directory layout.
///
/// Unlike [`download_pinned_snapshot`] there is no staging directory or ready
/// marker — files land where the unpinned flow always put them, so packs
/// installed before pinning existed remain valid. What the pin adds: the file
/// list comes from the manifest instead of a live (spoofable) listing, every
/// file resolves at the pinned revision, and a final SHA-256 pass rejects —
/// and bins — any file whose bytes differ from Hugging Face's own hashes.
async fn download_snapshot_with_pin(
    pack: &PackSpec,
    repository: &str,
    pin: &SnapshotPin,
    cancellation: &Cancellation,
    on_progress: &mut impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
    ensure_not_cancelled(cancellation)?;
    fs::create_dir_all(&pack.path)?;
    let total_files = pin.files.len();
    let expected = Some(pack.expected_bytes);
    let mut finished_bytes = 0_u64;
    for (index, file) in pin.files.iter().enumerate() {
        ensure_not_cancelled(cancellation)?;
        let destination = pack.path.join(&file.path);
        if destination
            .metadata()
            .ok()
            .is_some_and(|metadata| metadata.is_file() && metadata.len() == file.bytes)
        {
            finished_bytes = finished_bytes.saturating_add(file.bytes);
            on_progress(DownloadProgress {
                state: ModelPackState::Downloading,
                completed_files: index + 1,
                total_files,
                bytes: finished_bytes,
                expected_bytes: expected,
            });
            continue;
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        download_huggingface_file(
            repository,
            &pin.revision,
            &file.path,
            &destination,
            Some(file.bytes),
            None, // the verification pass below hashes every file once
            cancellation,
            |written, _| {
                on_progress(DownloadProgress {
                    state: ModelPackState::Downloading,
                    completed_files: index,
                    total_files,
                    bytes: finished_bytes.saturating_add(written),
                    expected_bytes: expected,
                });
            },
        )
        .await?;
        finished_bytes = finished_bytes.saturating_add(file.bytes);
    }

    on_progress(DownloadProgress {
        state: ModelPackState::Verifying,
        completed_files: 0,
        total_files,
        bytes: 0,
        expected_bytes: expected,
    });
    let verification_path = pack.path.clone();
    let verification_files = pin.files.clone();
    let verification_cancellation = cancellation.clone();
    tokio::task::spawn_blocking(move || {
        verify_files_removing_corrupt(
            &verification_path,
            &verification_files,
            &verification_cancellation,
        )
    })
    .await
    .map_err(|error| DownloadError::message(format!("verification task failed: {error}")))??;
    on_progress(DownloadProgress {
        state: ModelPackState::Ready,
        completed_files: total_files,
        total_files,
        bytes: pack.expected_bytes,
        expected_bytes: expected,
    });
    Ok(())
}

async fn download_pinned_snapshot(
    pack: &PackSpec,
    repository: &str,
    revision: &str,
    files: &[ManifestFile],
    cancellation: &Cancellation,
    on_progress: &mut impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
    ensure_not_cancelled(cancellation)?;
    let staging = staging_path(&pack.path);
    fs::create_dir_all(&staging)?;
    let staged_bytes = directory_size(&staging);
    let parent = pack.path.parent().unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let remaining = pack.expected_bytes.saturating_sub(staged_bytes);
    let operational_reserve = 1_073_741_824_u64;
    let required = remaining.saturating_add(operational_reserve);
    let available = fs2::available_space(parent)?;
    if available < required {
        return Err(DownloadError::message(format!(
            "not enough free space for {}: need {} bytes for the remaining atomic download and filesystem reserve, have {} bytes",
            pack.name, required, available
        )));
    }

    let total_files = files.len();
    let mut finished_bytes = 0_u64;
    for (index, file) in files.iter().enumerate() {
        ensure_not_cancelled(cancellation)?;
        let destination = staging.join(&file.path);
        if destination
            .metadata()
            .ok()
            .is_some_and(|metadata| metadata.is_file() && metadata.len() == file.bytes)
        {
            finished_bytes = finished_bytes.saturating_add(file.bytes);
            on_progress(DownloadProgress {
                state: ModelPackState::Downloading,
                completed_files: index + 1,
                total_files,
                bytes: finished_bytes,
                expected_bytes: Some(pack.expected_bytes),
            });
            continue;
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)?;
        }
        download_huggingface_file(
            repository,
            revision,
            &file.path,
            &destination,
            Some(file.bytes),
            None,
            cancellation,
            |written, _| {
                on_progress(DownloadProgress {
                    state: ModelPackState::Downloading,
                    completed_files: index,
                    total_files,
                    bytes: finished_bytes.saturating_add(written),
                    expected_bytes: Some(pack.expected_bytes),
                });
            },
        )
        .await?;
        finished_bytes = finished_bytes.saturating_add(file.bytes);
    }

    on_progress(DownloadProgress {
        state: ModelPackState::Verifying,
        completed_files: 0,
        total_files,
        bytes: 0,
        expected_bytes: Some(pack.expected_bytes),
    });
    let verification_path = staging.clone();
    let verification_files = files.to_vec();
    let verification_cancellation = cancellation.clone();
    tokio::task::spawn_blocking(move || {
        verify_files_with_cancellation(
            &verification_path,
            &verification_files,
            &verification_cancellation,
        )
    })
    .await
    .map_err(|error| DownloadError::message(format!("verification task failed: {error}")))??;

    let marker = serde_json::json!({
        "v": 1,
        "repository": repository,
        "revision": revision,
        "expected_bytes": pack.expected_bytes,
        "verified": true,
    });
    fs::write(
        staging.join(READY_MARKER),
        serde_json::to_vec_pretty(&marker).map_err(|error| {
            DownloadError::message(format!("could not encode ready marker: {error}"))
        })?,
    )?;
    if pack.path.exists() {
        return Err(DownloadError::message(format!(
            "refusing to replace incomplete model directory `{}`; remove it from Settings and retry",
            pack.path.display()
        )));
    }
    fs::rename(&staging, &pack.path)?;
    on_progress(DownloadProgress {
        state: ModelPackState::Ready,
        completed_files: total_files,
        total_files,
        bytes: pack.expected_bytes,
        expected_bytes: Some(pack.expected_bytes),
    });
    Ok(())
}

/// Verifies every fixed-size file and SHA-256 in a pinned snapshot.
///
/// # Errors
///
/// Returns an error for any missing, truncated, or modified file.
pub fn verify_files(path: &Path, files: &[ManifestFile]) -> Result<(), DownloadError> {
    verify_files_with_cancellation(path, files, &Cancellation::default())
}

fn verify_files_with_cancellation(
    path: &Path,
    files: &[ManifestFile],
    cancellation: &Cancellation,
) -> Result<(), DownloadError> {
    for expected in files {
        verify_one_file(path, expected, cancellation)?;
    }
    Ok(())
}

/// Like [`verify_files`], but bins a file whose bytes do not match before
/// erroring, so the next attempt re-downloads that file instead of failing
/// forever on the same corrupt bytes. Cancellation deletes nothing.
fn verify_files_removing_corrupt(
    path: &Path,
    files: &[ManifestFile],
    cancellation: &Cancellation,
) -> Result<(), DownloadError> {
    for expected in files {
        if let Err(error) = verify_one_file(path, expected, cancellation) {
            if !matches!(error, DownloadError::Cancelled) {
                let _ = fs::remove_file(path.join(&expected.path));
            }
            return Err(error);
        }
    }
    Ok(())
}

fn verify_one_file(
    path: &Path,
    expected: &ManifestFile,
    cancellation: &Cancellation,
) -> Result<(), DownloadError> {
    ensure_not_cancelled(cancellation)?;
    let file_path = path.join(&expected.path);
    let metadata = fs::metadata(&file_path)
        .map_err(|error| DownloadError::message(format!("{} is missing: {error}", expected.path)))?;
    if metadata.len() != expected.bytes {
        return Err(DownloadError::message(format!(
            "{} has {} bytes; expected {}",
            expected.path,
            metadata.len(),
            expected.bytes
        )));
    }
    let actual = sha256_of_file(&file_path, cancellation)?;
    if actual != expected.sha256 {
        return Err(DownloadError::message(format!(
            "{} failed SHA-256 verification (expected {}, got {})",
            expected.path, expected.sha256, actual
        )));
    }
    Ok(())
}

fn sha256_of_file(path: &Path, cancellation: &Cancellation) -> Result<String, DownloadError> {
    let mut source = fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    loop {
        ensure_not_cancelled(cancellation)?;
        let read = source.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
    }
    Ok(format!("{:x}", digest.finalize()))
}

#[derive(Debug, Deserialize)]
struct HfTreeEntry {
    path: String,
    #[serde(rename = "type")]
    kind: String,
    size: Option<u64>,
    lfs: Option<HfLfs>,
}

#[derive(Debug, Deserialize)]
struct HfLfs {
    size: Option<u64>,
}

#[derive(Debug, Clone)]
struct HfFile {
    path: String,
    size: Option<u64>,
}

async fn list_huggingface_files(
    repository: &str,
    cancellation: &Cancellation,
) -> Result<Vec<HfFile>, DownloadError> {
    ensure_not_cancelled(cancellation)?;
    let url = format!(
        "{}/api/models/{repository}/tree/main?recursive=1",
        huggingface_endpoint()
    );
    let request = huggingface_client()?.get(url).send();
    let response = tokio::select! {
        () = cancellation.cancelled() => return Err(DownloadError::Cancelled),
        response = request => response.map_err(|error| DownloadError::Http(error.to_string()))?,
    };
    if !response.status().is_success() {
        return Err(DownloadError::message(format!(
            "could not list `{repository}`: HTTP {}",
            response.status()
        )));
    }
    let entries: Vec<HfTreeEntry> = response
        .json()
        .await
        .map_err(|error| DownloadError::Http(error.to_string()))?;
    Ok(entries
        .into_iter()
        .filter(|entry| entry.kind == "file")
        .map(|entry| HfFile {
            path: entry.path,
            size: entry.lfs.and_then(|lfs| lfs.size).or(entry.size),
        })
        .collect())
}

async fn download_huggingface_file(
    repository: &str,
    revision: &str,
    file: &str,
    destination: &Path,
    expected_file_bytes: Option<u64>,
    expected_sha256: Option<&str>,
    cancellation: &Cancellation,
    mut on_chunk: impl FnMut(u64, Option<u64>),
) -> Result<(), DownloadError> {
    ensure_not_cancelled(cancellation)?;
    let url = format!(
        "{}/{repository}/resolve/{revision}/{file}",
        huggingface_endpoint()
    );
    let partial = partial_path(destination);
    let resume_from = fs::metadata(&partial)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let client = huggingface_client()?;
    let mut request = client.get(&url);
    if resume_from > 0 {
        request = request.header(reqwest::header::RANGE, format!("bytes={resume_from}-"));
    }
    let response = tokio::select! {
        () = cancellation.cancelled() => return Err(DownloadError::Cancelled),
        response = request.send() => response.map_err(|error| DownloadError::Http(error.to_string()))?,
    };
    if !response.status().is_success() {
        return Err(DownloadError::message(format!(
            "download `{repository}/{file}` failed: HTTP {}",
            response.status()
        )));
    }
    if let Some(parent) = partial.parent() {
        fs::create_dir_all(parent)?;
    }
    let resumed = resume_from > 0 && response.status() == reqwest::StatusCode::PARTIAL_CONTENT;
    let expected = expected_file_bytes.or_else(|| {
        response.content_length().map(|size| {
            if resumed {
                size.saturating_add(resume_from)
            } else {
                size
            }
        })
    });
    let output_file = if resumed {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&partial)?
    } else {
        fs::File::create(&partial)?
    };
    let mut output_file = tokio::fs::File::from_std(output_file);
    let mut stream = response.bytes_stream();
    let mut written = if resumed { resume_from } else { 0 };
    on_chunk(written, expected);
    loop {
        let next = tokio::select! {
            () = cancellation.cancelled() => return Err(DownloadError::Cancelled),
            next = stream.next() => next,
        };
        let Some(chunk) = next else { break };
        let chunk = chunk.map_err(|error| DownloadError::Http(error.to_string()))?;
        written = written.saturating_add(chunk.len() as u64);
        output_file.write_all(&chunk).await?;
        on_chunk(written, expected);
    }
    output_file.flush().await?;
    drop(output_file);
    if let Some(expected) = expected_file_bytes {
        let actual = fs::metadata(&partial)?.len();
        if actual != expected {
            return Err(DownloadError::message(format!(
                "download `{repository}/{file}` has {actual} bytes; expected {expected}"
            )));
        }
    }
    if let Some(expected_sha256) = expected_sha256 {
        let actual = {
            let partial = partial.clone();
            let cancellation = cancellation.clone();
            tokio::task::spawn_blocking(move || sha256_of_file(&partial, &cancellation))
                .await
                .map_err(|error| DownloadError::message(format!("hash task failed: {error}")))??
        };
        if actual != expected_sha256 {
            // Keeping the bytes would resume into the same failure forever.
            let _ = fs::remove_file(&partial);
            return Err(DownloadError::message(format!(
                "download `{repository}/{file}` failed SHA-256 verification (expected {expected_sha256}, got {actual}); the file was discarded, retry the download"
            )));
        }
    }
    fs::rename(partial, destination)?;
    Ok(())
}

fn ensure_not_cancelled(cancellation: &Cancellation) -> Result<(), DownloadError> {
    if cancellation.is_cancelled() {
        Err(DownloadError::Cancelled)
    } else {
        Ok(())
    }
}

/// Endpoint chosen in the app's settings. It outranks `HF_ENDPOINT` because
/// the GUI app never sees shell environment variables — the setting is the
/// only mirror control a packaged install actually has.
static CONFIGURED_ENDPOINT: std::sync::RwLock<Option<String>> = std::sync::RwLock::new(None);

/// Points model downloads at a Hugging Face mirror, or back at the official
/// endpoint with `None`/empty. Content integrity does not depend on the
/// endpoint: pinned packs are verified against SHA-256 hashes recorded in the
/// catalog. Note that `HF_TOKEN` is sent to whatever endpoint is in effect.
pub fn set_huggingface_endpoint(endpoint: Option<String>) {
    let cleaned = endpoint
        .as_deref()
        .map(|value| value.trim().trim_end_matches('/'))
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    *CONFIGURED_ENDPOINT
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = cleaned;
}

/// Base URL for every Hugging Face request: the configured setting, else
/// `HF_ENDPOINT` — the same variable the official CLI honours — else the
/// official endpoint.
fn huggingface_endpoint() -> String {
    if let Some(configured) = CONFIGURED_ENDPOINT
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
    {
        return configured;
    }
    endpoint_or_default(std::env::var("HF_ENDPOINT").ok())
}

fn endpoint_or_default(configured: Option<String>) -> String {
    let trimmed = configured.as_deref().map_or("", str::trim);
    if trimmed.is_empty() {
        return "https://huggingface.co".to_owned();
    }
    trimmed.trim_end_matches('/').to_owned()
}

fn huggingface_client() -> Result<reqwest::Client, DownloadError> {
    let mut headers = reqwest::header::HeaderMap::new();
    if let Ok(token) =
        std::env::var("HF_TOKEN").or_else(|_| std::env::var("HUGGING_FACE_HUB_TOKEN"))
    {
        let value = format!("Bearer {token}");
        headers.insert(
            reqwest::header::AUTHORIZATION,
            value
                .parse()
                .map_err(|_| DownloadError::message("HF_TOKEN is not a valid HTTP header value"))?,
        );
    }
    reqwest::Client::builder()
        .user_agent("afterray/0.0.1")
        .default_headers(headers)
        .redirect(reqwest::redirect::Policy::limited(16))
        .timeout(Duration::from_secs(60 * 30))
        .build()
        .map_err(|error| DownloadError::Http(error.to_string()))
}

fn partial_path(destination: &Path) -> PathBuf {
    let mut name = destination.file_name().unwrap_or_default().to_os_string();
    name.push(".partial");
    destination.with_file_name(name)
}

fn staging_path(destination: &Path) -> PathBuf {
    let mut name = destination.file_name().unwrap_or_default().to_os_string();
    name.push(".download");
    destination.with_file_name(name)
}

fn directory_size(path: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    entries.flatten().fold(0_u64, |total, entry| {
        let candidate = entry.path();
        if candidate.is_dir() {
            total.saturating_add(directory_size(&candidate))
        } else {
            total.saturating_add(entry.metadata().map(|metadata| metadata.len()).unwrap_or(0))
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn file_pack(path: PathBuf) -> PackSpec {
        PackSpec {
            id: "test".into(),
            name: "Test model".into(),
            capability: "test".into(),
            path,
            required: true,
            note: String::new(),
            expected_bytes: 4,
            source: PackSource::HuggingFaceFile {
                repository: "example/test".into(),
                file: "weights.bin".into(),
                revision: "main".into(),
                sha256: None,
            },
        }
    }

    /// `HF_ENDPOINT` is pure prefix substitution: a mirror serves the same
    /// paths, so the override must not grow a double slash or lose the default.
    #[test]
    fn hf_endpoint_override_trims_and_falls_back() {
        assert_eq!(endpoint_or_default(None), "https://huggingface.co");
        assert_eq!(endpoint_or_default(Some("  ".into())), "https://huggingface.co");
        assert_eq!(
            endpoint_or_default(Some("https://hf-mirror.com/".into())),
            "https://hf-mirror.com"
        );
        assert_eq!(
            endpoint_or_default(Some(" https://hf-mirror.com ".into())),
            "https://hf-mirror.com"
        );
    }

    #[test]
    fn partial_files_sit_next_to_the_destination() {
        let path = Path::new("/tmp/models/weights.gguf");
        assert_eq!(
            partial_path(path),
            PathBuf::from("/tmp/models/weights.gguf.partial")
        );
    }

    #[test]
    fn percent_uses_expected_bytes() {
        let progress = DownloadProgress {
            state: ModelPackState::Downloading,
            completed_files: 0,
            total_files: 1,
            bytes: 42,
            expected_bytes: Some(100),
        };
        assert_eq!(progress.percent(), Some(42));
        assert_eq!(
            DownloadProgress {
                expected_bytes: None,
                ..progress
            }
            .percent(),
            None
        );
    }

    #[test]
    fn verification_rejects_a_changed_or_missing_manifest_file() {
        let directory =
            std::env::temp_dir().join(format!("afterray-download-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).unwrap();
        let file = directory.join("config.json");
        fs::File::create(&file).unwrap().write_all(b"good").unwrap();
        let manifest = [ManifestFile {
            path: "config.json".into(),
            bytes: 4,
            sha256: "770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c".into(),
        }];
        assert!(verify_files(&directory, &manifest).is_ok());
        fs::File::create(&file).unwrap().write_all(b"bad!").unwrap();
        assert!(verify_files(&directory, &manifest).is_err());
        fs::remove_file(&file).unwrap();
        assert!(verify_files(&directory, &manifest).is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    /// A pinned-snapshot file that fails verification must be deleted — kept
    /// bytes would satisfy the size-based resume skip and fail identically on
    /// every retry. Good files stay; cancellation deletes nothing.
    #[test]
    fn corrupt_snapshot_file_is_binned_so_a_retry_redownloads_it() {
        const GOOD_SHA: &str = "770e607624d689265ca6c44884d0807d9b054d23c473c106c72be9de08b7376c";
        let directory = std::env::temp_dir().join(format!(
            "afterray-corrupt-bin-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).unwrap();
        fs::write(directory.join("good.json"), b"good").unwrap();
        fs::write(directory.join("bad.bin"), b"bad!").unwrap();
        let manifest = [
            ManifestFile {
                path: "good.json".into(),
                bytes: 4,
                sha256: GOOD_SHA.into(),
            },
            ManifestFile {
                path: "bad.bin".into(),
                bytes: 4,
                sha256: GOOD_SHA.into(),
            },
        ];

        let error =
            verify_files_removing_corrupt(&directory, &manifest, &Cancellation::default())
                .unwrap_err();
        assert!(error.to_string().contains("bad.bin"));
        assert!(directory.join("good.json").is_file(), "good file kept");
        assert!(!directory.join("bad.bin").exists(), "corrupt file binned");

        fs::write(directory.join("bad.bin"), b"bad!").unwrap();
        let cancellation = Cancellation::default();
        cancellation.cancel();
        let result = verify_files_removing_corrupt(&directory, &manifest, &cancellation);
        assert!(matches!(result, Err(DownloadError::Cancelled)));
        assert!(
            directory.join("bad.bin").is_file(),
            "cancellation must not delete"
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[tokio::test]
    async fn cancelled_download_stops_before_network_or_disk_work() {
        let cancellation = Cancellation::default();
        cancellation.cancel();
        let pack = file_pack(std::env::temp_dir().join("afterray-cancelled-test.bin"));

        let result = download_pack_with_cancellation(&pack, cancellation, |_| {}).await;

        assert!(matches!(result, Err(DownloadError::Cancelled)));
        assert!(!pack.path.exists());
    }

    #[test]
    fn removing_a_file_pack_also_removes_its_resumable_partial() {
        let directory = std::env::temp_dir().join(format!(
            "afterray-remove-partial-test-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).unwrap();
        let pack = file_pack(directory.join("weights.bin"));
        fs::write(&pack.path, b"done").unwrap();
        fs::write(partial_path(&pack.path), b"part").unwrap();

        remove_pack(&pack).unwrap();

        assert!(!pack.path.exists());
        assert!(!partial_path(&pack.path).exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
