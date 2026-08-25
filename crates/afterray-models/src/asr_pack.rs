use crate::catalog::{ManifestFile, READY_MARKER};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::Write as _,
    path::{Path, PathBuf},
};

pub const QWEN3_ASR_RECIPE_VERSION: u32 = 1;

#[derive(Debug, Serialize, Deserialize)]
struct AsrReadyMarker {
    v: u32,
    revision: String,
    recipe_version: u32,
    manifest_digest: String,
    tokenizer_sha256: String,
}

/// Returns success only when the files consumed by the shipped ASR worker are
/// present and the generated tokenizer still matches the verified inputs.
///
/// # Errors
///
/// Returns an error when the marker or tokenizer is absent, stale, corrupted,
/// or cannot be parsed by the tokenizer runtime.
pub fn verify_qwen3_asr_prepared(
    path: &Path,
    revision: &str,
    manifest: &[ManifestFile],
) -> Result<(), String> {
    let marker_path = path.join(READY_MARKER);
    let marker: AsrReadyMarker = serde_json::from_slice(
        &fs::read(&marker_path).map_err(|error| format!("ASR ready marker is missing: {error}"))?,
    )
    .map_err(|error| format!("ASR ready marker is invalid: {error}"))?;
    if marker.v != 1
        || marker.revision != revision
        || marker.recipe_version != QWEN3_ASR_RECIPE_VERSION
        || marker.manifest_digest != manifest_digest(manifest)
    {
        return Err("ASR model preparation is stale".into());
    }
    let tokenizer_path = path.join("tokenizer.json");
    let tokenizer_bytes =
        fs::read(&tokenizer_path).map_err(|error| format!("tokenizer.json is missing: {error}"))?;
    if sha256_bytes(&tokenizer_bytes) != marker.tokenizer_sha256 {
        return Err("tokenizer.json does not match its ready marker".into());
    }
    tokenizers::Tokenizer::from_bytes(&tokenizer_bytes)
        .map_err(|error| format!("tokenizer.json cannot be loaded: {error}"))?;
    Ok(())
}

/// Builds the tokenizer file that the official Qwen snapshot deliberately
/// omits. Both the downloader and inference worker call this function, so
/// "ready" and "loadable" cannot drift into two definitions again.
///
/// # Errors
///
/// Returns an error when the tokenizer inputs cannot be read or parsed, or
/// when the generated tokenizer and ready marker cannot be installed.
pub fn prepare_qwen3_asr(
    path: &Path,
    revision: &str,
    manifest: &[ManifestFile],
) -> Result<(), String> {
    if verify_qwen3_asr_prepared(path, revision, manifest).is_ok() {
        return Ok(());
    }
    let vocab = fs::read_to_string(path.join("vocab.json"))
        .map_err(|error| format!("could not read vocab.json: {error}"))?;
    let merges = fs::read_to_string(path.join("merges.txt"))
        .map_err(|error| format!("could not read merges.txt: {error}"))?;
    let tokenizer_config = fs::read_to_string(path.join("tokenizer_config.json"))
        .map_err(|error| format!("could not read tokenizer_config.json: {error}"))?;
    let tokenizer = build_tokenizer_json(&vocab, &merges, &tokenizer_config)?;
    tokenizers::Tokenizer::from_bytes(&tokenizer)
        .map_err(|error| format!("generated tokenizer.json cannot be loaded: {error}"))?;

    atomic_write(&path.join("tokenizer.json"), &tokenizer)?;
    let marker = AsrReadyMarker {
        v: 1,
        revision: revision.to_owned(),
        recipe_version: QWEN3_ASR_RECIPE_VERSION,
        manifest_digest: manifest_digest(manifest),
        tokenizer_sha256: sha256_bytes(&tokenizer),
    };
    let marker = serde_json::to_vec_pretty(&marker)
        .map_err(|error| format!("could not encode ASR ready marker: {error}"))?;
    atomic_write(&path.join(READY_MARKER), &marker)?;
    verify_qwen3_asr_prepared(path, revision, manifest)
}

/// Repairs or verifies the configured Qwen3-ASR pack at `path`.
///
/// # Errors
///
/// Returns an error when `path` is not the configured ASR pack, its pinned
/// files fail verification, or tokenizer preparation fails.
pub fn prepare_configured_qwen3_asr(path: &Path) -> Result<(), String> {
    let pack = crate::catalog::default_catalog()
        .into_iter()
        .find(|pack| pack.id == "asr" && pack.path == path)
        .ok_or_else(|| format!("no configured ASR pack owns {}", path.display()))?;
    match pack.source {
        crate::catalog::PackSource::HuggingFaceSnapshot { pin: Some(pin), .. } => {
            if verify_qwen3_asr_prepared(path, &pin.revision, &pin.files).is_ok() {
                return Ok(());
            }
            crate::download::verify_files(path, &pin.files)
                .map_err(|error| format!("ASR snapshot verification failed: {error}"))?;
            prepare_qwen3_asr(path, &pin.revision, &pin.files)
        }
        crate::catalog::PackSource::HuggingFaceSnapshot { pin: None, .. } => {
            prepare_qwen3_asr(path, "custom", &[])
        }
        crate::catalog::PackSource::HuggingFacePinnedSnapshot {
            revision, files, ..
        } => {
            if verify_qwen3_asr_prepared(path, &revision, &files).is_ok() {
                return Ok(());
            }
            crate::download::verify_files(path, &files)
                .map_err(|error| format!("ASR snapshot verification failed: {error}"))?;
            prepare_qwen3_asr(path, &revision, &files)
        }
        _ => Err("configured ASR pack has an unsupported source".into()),
    }
}

pub fn invalidate_qwen3_asr_ready(path: &Path) {
    let _ = fs::remove_file(path.join(READY_MARKER));
}

fn build_tokenizer_json(vocab: &str, merges: &str, config: &str) -> Result<Vec<u8>, String> {
    let vocab: serde_json::Value =
        serde_json::from_str(vocab).map_err(|error| format!("invalid vocab.json: {error}"))?;
    let merges: Vec<&str> = merges
        .lines()
        .filter(|line| !line.starts_with('#') && !line.is_empty())
        .collect();
    let config: serde_json::Value = serde_json::from_str(config)
        .map_err(|error| format!("invalid tokenizer_config.json: {error}"))?;
    let mut entries = config["added_tokens_decoder"]
        .as_object()
        .map(|values| {
            values
                .iter()
                .filter_map(|(id, value)| id.parse::<u64>().ok().map(|id| (id, value)))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    entries.sort_by_key(|(id, _)| *id);
    let added_tokens = entries
        .into_iter()
        .map(|(id, value)| {
            serde_json::json!({
                "id": id,
                "content": value["content"],
                "single_word": false,
                "lstrip": false,
                "rstrip": false,
                "normalized": false,
                "special": value["special"]
            })
        })
        .collect::<Vec<_>>();
    serde_json::to_vec(&serde_json::json!({
        "version": "1.0",
        "truncation": null,
        "padding": null,
        "added_tokens": added_tokens,
        "normalizer": {"type": "NFC"},
        "pre_tokenizer": {
            "type": "Sequence",
            "pretokenizers": [
                {
                    "type": "Split",
                    "pattern": {"Regex": "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"},
                    "behavior": "Isolated",
                    "invert": false
                },
                {"type": "ByteLevel", "add_prefix_space": false, "trim_offsets": false, "use_regex": false}
            ]
        },
        "post_processor": {"type": "ByteLevel", "add_prefix_space": false, "trim_offsets": false, "use_regex": false},
        "decoder": {"type": "ByteLevel", "add_prefix_space": false, "trim_offsets": false, "use_regex": false},
        "model": {
            "type": "BPE",
            "dropout": null,
            "unk_token": null,
            "continuing_subword_prefix": "",
            "end_of_word_suffix": "",
            "fuse_unk": false,
            "byte_fallback": false,
            "ignore_merges": false,
            "vocab": vocab,
            "merges": merges
        }
    }))
    .map_err(|error| format!("could not encode tokenizer.json: {error}"))
}

fn manifest_digest(manifest: &[ManifestFile]) -> String {
    let mut digest = Sha256::new();
    for file in manifest {
        digest.update(file.path.as_bytes());
        digest.update([0]);
        digest.update(file.bytes.to_le_bytes());
        digest.update(file.sha256.as_bytes());
        digest.update([0xff]);
    }
    format!("{:x}", digest.finalize())
}

fn sha256_bytes(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temporary = temporary_path(path);
    let result = (|| {
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temporary)
            .map_err(|error| format!("could not create {}: {error}", temporary.display()))?;
        file.write_all(bytes)
            .and_then(|()| file.sync_all())
            .map_err(|error| format!("could not write {}: {error}", temporary.display()))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("could not install {}: {error}", path.display()))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn temporary_path(path: &Path) -> PathBuf {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!(".{name}.{}.tmp", uuid::Uuid::now_v7()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(path: &Path) {
        fs::create_dir_all(path).unwrap();
        fs::write(path.join("vocab.json"), r#"{"a":0,"b":1,"ab":2}"#).unwrap();
        fs::write(path.join("merges.txt"), "#version: 0.2\na b\n").unwrap();
        fs::write(
            path.join("tokenizer_config.json"),
            r#"{"added_tokens_decoder":{"3":{"content":"<eos>","special":true}}}"#,
        )
        .unwrap();
    }

    #[test]
    fn a_pack_is_ready_only_after_its_generated_tokenizer_is_loadable() {
        let root = std::env::temp_dir().join(format!(
            "afterray-asr-prepare-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        fixture(&root);
        let manifest = Vec::new();
        assert!(verify_qwen3_asr_prepared(&root, "revision", &manifest).is_err());
        prepare_qwen3_asr(&root, "revision", &manifest).unwrap();
        verify_qwen3_asr_prepared(&root, "revision", &manifest).unwrap();
        fs::write(root.join("tokenizer.json"), "{}").unwrap();
        assert!(verify_qwen3_asr_prepared(&root, "revision", &manifest).is_err());
        let _ = fs::remove_dir_all(root);
    }
}
