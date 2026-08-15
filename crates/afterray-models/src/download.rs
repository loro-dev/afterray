use crate::catalog::{ManifestFile, PackSource, PackSpec, READY_MARKER, inspect_model_path};
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
    mut on_progress: impl FnMut(&PackSpec, DownloadProgress),
) -> Result<(), DownloadError> {
    for pack in packs {
        download_pack(pack, |progress| on_progress(pack, progress)).await?;
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
    mut on_progress: impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
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
        PackSource::HuggingFaceFile { repository, file } => {
            if let Some(parent) = pack.path.parent() {
                fs::create_dir_all(parent)?;
            }
            download_huggingface_file(
                repository,
                "main",
                file,
                &pack.path,
                None,
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
        PackSource::HuggingFaceSnapshot { repository } => {
            fs::create_dir_all(&pack.path)?;
            let files = list_huggingface_files(repository).await?;
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
            download_pinned_snapshot(pack, repository, revision, files, &mut on_progress).await?;
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

async fn download_pinned_snapshot(
    pack: &PackSpec,
    repository: &str,
    revision: &str,
    files: &[ManifestFile],
    on_progress: &mut impl FnMut(DownloadProgress),
) -> Result<(), DownloadError> {
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
    tokio::task::spawn_blocking(move || verify_files(&verification_path, &verification_files))
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
    let mut buffer = vec![0_u8; 1024 * 1024];
    for expected in files {
        let file_path = path.join(&expected.path);
        let metadata = fs::metadata(&file_path).map_err(|error| {
            DownloadError::message(format!("{} is missing: {error}", expected.path))
        })?;
        if metadata.len() != expected.bytes {
            return Err(DownloadError::message(format!(
                "{} has {} bytes; expected {}",
                expected.path,
                metadata.len(),
                expected.bytes
            )));
        }
        let mut source = fs::File::open(&file_path)?;
        let mut digest = Sha256::new();
        loop {
            let read = source.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            digest.update(&buffer[..read]);
        }
        let actual = format!("{:x}", digest.finalize());
        if actual != expected.sha256 {
            return Err(DownloadError::message(format!(
                "{} failed SHA-256 verification (expected {}, got {})",
                expected.path, expected.sha256, actual
            )));
        }
    }
    Ok(())
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

async fn list_huggingface_files(repository: &str) -> Result<Vec<HfFile>, DownloadError> {
    let url = format!("https://huggingface.co/api/models/{repository}/tree/main?recursive=1");
    let response = huggingface_client()?
        .get(url)
        .send()
        .await
        .map_err(|error| DownloadError::Http(error.to_string()))?;
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
    mut on_chunk: impl FnMut(u64, Option<u64>),
) -> Result<(), DownloadError> {
    let url = format!("https://huggingface.co/{repository}/resolve/{revision}/{file}");
    let partial = partial_path(destination);
    let resume_from = fs::metadata(&partial)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let client = huggingface_client()?;
    let mut request = client.get(&url);
    if resume_from > 0 {
        request = request.header(reqwest::header::RANGE, format!("bytes={resume_from}-"));
    }
    let response = request
        .send()
        .await
        .map_err(|error| DownloadError::Http(error.to_string()))?;
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
    while let Some(chunk) = stream.next().await {
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
    fs::rename(partial, destination)?;
    Ok(())
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
}
