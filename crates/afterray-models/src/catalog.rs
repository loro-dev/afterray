use afterray_protocol::{ModelLibrary, ModelPack, ModelPackState};
use std::path::{Path, PathBuf};

pub const READY_MARKER: &str = ".afterray-ready.json";

pub const QWEN35_4B_MLX_REPOSITORY: &str = "mlx-community/Qwen3.5-4B-MLX-4bit";
pub const QWEN35_4B_MLX_REVISION: &str = "32f3e8ecf65426fc3306969496342d504bfa13f3";
pub const QWEN35_4B_MLX_EXPECTED_BYTES: u64 = 3_061_129_077;
pub const QWEN35_4B_MLX_PACK_ID: &str = "llm_qwen35_4b_mlx4";
pub const QWEN35_9B_MLX_REPOSITORY: &str = "mlx-community/Qwen3.5-9B-MLX-4bit";
pub const QWEN35_9B_MLX_REVISION: &str = "938d8919941c6e7efd3c7150eff7fe9d12afa631";
pub const QWEN35_9B_MLX_EXPECTED_BYTES: u64 = 5_977_071_067;
pub const QWEN35_9B_MLX_PACK_ID: &str = "llm_qwen35_9b_mlx4";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestFile {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}

/// Hugging Face snapshot (many files) or a single downloadable weight file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackSource {
    HuggingFaceSnapshot {
        repository: String,
    },
    HuggingFacePinnedSnapshot {
        repository: String,
        revision: String,
        files: Vec<ManifestFile>,
    },
    HuggingFaceFile {
        repository: String,
        file: String,
    },
}

/// One user-visible model pack. Paths and repositories can be overridden
/// with `AFTERRAY_*` environment variables so the daemon never hard-codes a
/// single checkpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackSpec {
    pub id: String,
    pub name: String,
    pub capability: String,
    pub path: PathBuf,
    pub required: bool,
    pub note: String,
    pub expected_bytes: u64,
    pub source: PackSource,
}

impl PackSpec {
    #[must_use]
    pub fn inspect(&self) -> ModelPack {
        let (present, bytes, state, error) = match &self.source {
            PackSource::HuggingFacePinnedSnapshot {
                revision, files, ..
            } => inspect_pinned_snapshot(&self.path, revision, files),
            _ => {
                let (present, bytes) = inspect_model_path(&self.path);
                let state = if present {
                    ModelPackState::Ready
                } else {
                    ModelPackState::NotDownloaded
                };
                (present, bytes, state, None)
            }
        };
        ModelPack {
            id: self.id.clone(),
            name: self.name.clone(),
            capability: self.capability.clone(),
            path: self.path.display().to_string(),
            present,
            state,
            bytes,
            required: self.required,
            note: Some(self.note.clone()),
            expected_bytes: Some(self.expected_bytes),
            revision: self.revision().map(ToOwned::to_owned),
            error,
        }
    }

    #[must_use]
    pub fn revision(&self) -> Option<&str> {
        match &self.source {
            PackSource::HuggingFacePinnedSnapshot { revision, .. } => Some(revision),
            PackSource::HuggingFaceSnapshot { .. } | PackSource::HuggingFaceFile { .. } => None,
        }
    }
}

#[must_use]
pub fn model_directory() -> PathBuf {
    if let Some(path) = std::env::var_os("AFTERRAY_MODEL_DIR") {
        return PathBuf::from(path);
    }
    if let Some(path) = std::env::var_os("AFTERRAY_ASR_MODEL") {
        if let Some(parent) = Path::new(&path).parent() {
            return parent.to_path_buf();
        }
    }
    if let Some(path) = std::env::var_os("AFTERRAY_DATA_DIR") {
        let data = PathBuf::from(path);
        if let Some(parent) = data.parent() {
            return parent.join("models");
        }
    }
    PathBuf::from(".afterray/models")
}

#[must_use]
pub fn default_catalog() -> Vec<PackSpec> {
    catalog_in(&model_directory())
}

#[must_use]
pub fn catalog_in(directory: &Path) -> Vec<PackSpec> {
    vec![
        PackSpec {
            id: "asr".into(),
            name: "Qwen3 ASR".into(),
            capability: "asr".into(),
            path: env_or_join("AFTERRAY_ASR_MODEL", directory, "Qwen3-ASR-1.7B"),
            required: true,
            note: format!(
                "{} · official safetensors · ZH/EN/JA · Rust/Candle",
                env_or("AFTERRAY_ASR_REPOSITORY", "Qwen/Qwen3-ASR-1.7B")
            ),
            expected_bytes: 4_200_000_000,
            source: PackSource::HuggingFaceSnapshot {
                repository: env_or("AFTERRAY_ASR_REPOSITORY", "Qwen/Qwen3-ASR-1.7B"),
            },
        },
        PackSpec {
            id: "embedding".into(),
            name: "Text embeddings".into(),
            capability: "embedding".into(),
            path: env_or_join(
                "AFTERRAY_EMBEDDING_MODEL",
                directory,
                "nomic-embed-text-v1.5.Q4_K_M.gguf",
            ),
            required: true,
            note: "nomic-embed-text v1.5 Q4 · llama.cpp".into(),
            expected_bytes: 84_000_000,
            source: PackSource::HuggingFaceFile {
                repository: env_or(
                    "AFTERRAY_EMBEDDING_REPOSITORY",
                    "nomic-ai/nomic-embed-text-v1.5-GGUF",
                ),
                file: env_or(
                    "AFTERRAY_EMBEDDING_FILE",
                    "nomic-embed-text-v1.5.Q4_K_M.gguf",
                ),
            },
        },
        qwen35_mlx_pack(directory),
        qwen35_9b_mlx_pack(directory),
    ]
}

#[must_use]
pub fn qwen35_mlx_pack(directory: &Path) -> PackSpec {
    PackSpec {
        id: QWEN35_4B_MLX_PACK_ID.into(),
        name: "Qwen3.5 4B · MLX 4-bit".into(),
        capability: "llm_vlm".into(),
        path: env_or_join(
            "AFTERRAY_MLX_MODEL",
            directory,
            "Qwen3.5-4B-MLX-4bit",
        ),
        required: false,
        note: "Recommended local assistant · text and vision · Apache 2.0 · about 3.06 GB · Apple Silicon, macOS 14+ · M2 8 GB experimental; 16 GB+ product candidate".into(),
        expected_bytes: QWEN35_4B_MLX_EXPECTED_BYTES,
        source: PackSource::HuggingFacePinnedSnapshot {
            repository: QWEN35_4B_MLX_REPOSITORY.into(),
            revision: QWEN35_4B_MLX_REVISION.into(),
            files: qwen35_mlx_manifest(),
        },
    }
}

/// Optional higher-quality Qwen3.5 VLM. It intentionally has a separate
/// managed directory and snapshot manifest, but shares the signed MLXVLM
/// worker with the 4B pack.
#[must_use]
pub fn qwen35_9b_mlx_pack(directory: &Path) -> PackSpec {
    PackSpec {
        id: QWEN35_9B_MLX_PACK_ID.into(),
        name: "Qwen3.5 9B · MLX 4-bit".into(),
        capability: "llm_vlm".into(),
        path: env_or_join(
            "AFTERRAY_MLX_9B_MODEL",
            directory,
            "Qwen3.5-9B-MLX-4bit",
        ),
        required: false,
        note: "Higher-quality local assistant · text and vision · Apache 2.0 · about 5.97 GB · Apple Silicon, macOS 14+ · download only after checking available unified memory".into(),
        expected_bytes: QWEN35_9B_MLX_EXPECTED_BYTES,
        source: PackSource::HuggingFacePinnedSnapshot {
            repository: QWEN35_9B_MLX_REPOSITORY.into(),
            revision: QWEN35_9B_MLX_REVISION.into(),
            files: qwen35_9b_mlx_manifest(),
        },
    }
}

#[must_use]
pub fn qwen35_mlx_manifest() -> Vec<ManifestFile> {
    const FILES: &[(&str, u64, &str)] = &[
        (
            "chat_template.jinja",
            7_756,
            "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715",
        ),
        (
            "config.json",
            3_366,
            "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa",
        ),
        (
            "model.safetensors",
            3_034_300_695,
            "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db",
        ),
        (
            "model.safetensors.index.json",
            101_944,
            "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a",
        ),
        (
            "preprocessor_config.json",
            390,
            "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516",
        ),
        (
            "processor_config.json",
            1_300,
            "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b",
        ),
        (
            "tokenizer.json",
            19_989_343,
            "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
        ),
        (
            "tokenizer_config.json",
            1_139,
            "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182",
        ),
        (
            "video_preprocessor_config.json",
            385,
            "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13",
        ),
        (
            "vocab.json",
            6_722_759,
            "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003",
        ),
    ];
    FILES
        .iter()
        .map(|(path, bytes, sha256)| ManifestFile {
            path: (*path).into(),
            bytes: *bytes,
            sha256: (*sha256).into(),
        })
        .collect()
}

#[must_use]
pub fn qwen35_9b_mlx_manifest() -> Vec<ManifestFile> {
    const FILES: &[(&str, u64, &str)] = &[
        (
            "chat_template.jinja",
            7_756,
            "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715",
        ),
        (
            "config.json",
            3_331,
            "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8",
        ),
        (
            "model-00001-of-00002.safetensors",
            5_349_771_222,
            "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd",
        ),
        (
            "model-00002-of-00002.safetensors",
            600_449_850,
            "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d",
        ),
        (
            "model.safetensors.index.json",
            123_592,
            "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e",
        ),
        (
            "preprocessor_config.json",
            390,
            "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516",
        ),
        (
            "processor_config.json",
            1_300,
            "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b",
        ),
        (
            "tokenizer.json",
            19_989_343,
            "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
        ),
        (
            "tokenizer_config.json",
            1_139,
            "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182",
        ),
        (
            "video_preprocessor_config.json",
            385,
            "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13",
        ),
        (
            "vocab.json",
            6_722_759,
            "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003",
        ),
    ];
    FILES
        .iter()
        .map(|(path, bytes, sha256)| ManifestFile {
            path: (*path).into(),
            bytes: *bytes,
            sha256: (*sha256).into(),
        })
        .collect()
}

#[must_use]
pub fn library() -> ModelLibrary {
    library_in(&model_directory())
}

#[must_use]
pub fn library_in(directory: &Path) -> ModelLibrary {
    ModelLibrary {
        directory: directory.display().to_string(),
        packs: catalog_in(directory)
            .into_iter()
            .map(|spec| spec.inspect())
            .collect(),
        download: None,
    }
}

#[must_use]
pub fn spec_by_id(id: &str) -> Option<PackSpec> {
    default_catalog().into_iter().find(|spec| spec.id == id)
}

/// Lists packs that should be downloaded.
///
/// # Errors
///
/// Returns an error when `pack_id` is not in the catalog.
pub fn specs_for_download(pack_id: Option<&str>) -> Result<Vec<PackSpec>, String> {
    specs_for_download_in(&model_directory(), pack_id)
}

/// Lists packs under `directory` that should be downloaded.
///
/// # Errors
///
/// Returns an error when `pack_id` is not in the catalog.
pub fn specs_for_download_in(
    directory: &Path,
    pack_id: Option<&str>,
) -> Result<Vec<PackSpec>, String> {
    let catalog = catalog_in(directory);
    match pack_id {
        None => Ok(catalog
            .into_iter()
            .filter(|spec| !spec.inspect().present)
            .collect()),
        Some(id) => catalog
            .into_iter()
            .find(|spec| spec.id == id)
            .map(|spec| vec![spec])
            .ok_or_else(|| format!("unknown model pack `{id}`")),
    }
}

#[must_use]
pub fn inspect_model_path(path: &Path) -> (bool, u64) {
    if path.is_file() {
        return (
            true,
            std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0),
        );
    }
    if path.is_dir() {
        return (snapshot_is_ready(path), directory_size(path));
    }
    (false, 0)
}

fn inspect_pinned_snapshot(
    path: &Path,
    revision: &str,
    files: &[ManifestFile],
) -> (bool, u64, ModelPackState, Option<String>) {
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        return (
            false,
            directory_size(path),
            ModelPackState::Incompatible,
            Some("AfterRay MLX requires Apple Silicon and macOS 14 or newer".into()),
        );
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let bytes = directory_size(path);
        let marker = path.join(READY_MARKER);
        let marker_revision = std::fs::read_to_string(marker)
            .ok()
            .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
            .and_then(|value| value.get("revision")?.as_str().map(ToOwned::to_owned));
        if marker_revision.as_deref() != Some(revision) {
            let staging = download_staging_path(path);
            if staging.is_dir() {
                return (
                    false,
                    directory_size(&staging),
                    ModelPackState::Downloading,
                    Some("download is resumable; continue from Settings".into()),
                );
            }
            return (false, bytes, ModelPackState::NotDownloaded, None);
        }
        for file in files {
            let candidate = path.join(&file.path);
            let size = std::fs::metadata(&candidate).ok().map(|meta| meta.len());
            if size != Some(file.bytes) {
                return (
                    false,
                    bytes,
                    ModelPackState::Failed,
                    Some(format!("{} is missing or has the wrong size", file.path)),
                );
            }
        }
        (true, bytes, ModelPackState::Ready, None)
    }
}

fn download_staging_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".download");
    path.with_file_name(name)
}

fn snapshot_is_ready(path: &Path) -> bool {
    if !path.join("config.json").is_file() {
        return false;
    }
    let has_tokenizer = path.join("tokenizer.json").is_file()
        || path.join("tokenizer.model").is_file()
        || path.join("vocab.json").is_file();
    has_tokenizer && has_complete_weight(path)
}

fn has_complete_weight(path: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(path) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let child = entry.path();
        if child.is_dir() {
            return has_complete_weight(&child);
        }
        let name = child
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        if name.ends_with(".partial") {
            return false;
        }
        Path::new(name).extension().is_some_and(|ext| {
            ext.eq_ignore_ascii_case("safetensors")
                || ext.eq_ignore_ascii_case("gguf")
                || ext.eq_ignore_ascii_case("bin")
        })
    })
}

fn directory_size(path: &Path) -> u64 {
    let mut total = 0;
    let Ok(entries) = std::fs::read_dir(path) else {
        return 0;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            total += directory_size(&path);
        } else if let Ok(meta) = entry.metadata() {
            total += meta.len();
        }
    }
    total
}

fn env_or(key: &str, fallback: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}

fn env_or_join(key: &str, directory: &Path, file_name: &str) -> PathBuf {
    std::env::var_os(key)
        .filter(|value| !value.is_empty())
        .map_or_else(|| directory.join(file_name), PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn catalog_has_asr_embedding_and_the_managed_mlx_packs() {
        let catalog = catalog_in(Path::new("/tmp/afterray-models"));
        let ids: Vec<_> = catalog.iter().map(|spec| spec.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "asr",
                "embedding",
                QWEN35_4B_MLX_PACK_ID,
                QWEN35_9B_MLX_PACK_ID
            ]
        );
        assert!(catalog[0].required);
        assert!(catalog[1].required);
        assert!(!catalog[2].required);
        assert!(!catalog[3].required);
        assert_eq!(catalog[2].expected_bytes, QWEN35_4B_MLX_EXPECTED_BYTES);
        assert_eq!(catalog[2].revision(), Some(QWEN35_4B_MLX_REVISION));
        assert_eq!(
            QWEN35_4B_MLX_REPOSITORY,
            "mlx-community/Qwen3.5-4B-MLX-4bit"
        );
        assert!(matches!(
            catalog[2].source,
            PackSource::HuggingFacePinnedSnapshot { .. }
        ));
        assert_eq!(catalog[3].expected_bytes, QWEN35_9B_MLX_EXPECTED_BYTES);
        assert_eq!(catalog[3].revision(), Some(QWEN35_9B_MLX_REVISION));
        assert_eq!(
            QWEN35_9B_MLX_REPOSITORY,
            "mlx-community/Qwen3.5-9B-MLX-4bit"
        );
        assert_eq!(
            qwen35_9b_mlx_manifest()
                .iter()
                .map(|file| file.bytes)
                .sum::<u64>(),
            QWEN35_9B_MLX_EXPECTED_BYTES
        );
        assert_eq!(
            qwen35_mlx_manifest()
                .iter()
                .map(|file| file.bytes)
                .sum::<u64>(),
            QWEN35_4B_MLX_EXPECTED_BYTES
        );
        let manifest = qwen35_mlx_manifest();
        let weights = manifest
            .iter()
            .find(|file| file.path == "model.safetensors")
            .expect("4B manifest has one weight file");
        assert_eq!(weights.bytes, 3_034_300_695);
        assert_eq!(
            weights.sha256,
            "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"
        );
        assert_eq!(
            manifest
                .iter()
                .filter(|file| file.path.ends_with(".safetensors"))
                .count(),
            1
        );
        assert!(matches!(
            catalog[0].source,
            PackSource::HuggingFaceSnapshot { .. }
        ));
        assert!(matches!(
            catalog[1].source,
            PackSource::HuggingFaceFile { .. }
        ));
        let weights = qwen35_9b_mlx_manifest()
            .into_iter()
            .filter(|file| file.path.ends_with(".safetensors"))
            .collect::<Vec<_>>();
        assert_eq!(weights.len(), 2);
        assert_eq!(weights[0].bytes, 5_349_771_222);
        assert_eq!(weights[1].bytes, 600_449_850);
    }

    /// The 27B GGUF assistant pack is gone: nothing in the catalog should
    /// still offer a multi-gigabyte llama.cpp download.
    #[test]
    fn catalog_no_longer_offers_the_retired_gguf_assistant_pack() {
        let catalog = catalog_in(Path::new("/tmp/afterray-models"));
        assert!(catalog.iter().all(|spec| spec.id != "llm"));
        assert!(catalog.iter().all(|spec| spec.capability != "llm"));
    }

    #[test]
    fn inspects_files_and_snapshots() {
        let root = std::env::temp_dir().join(format!("afterray-catalog-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("snap")).unwrap();
        fs::write(root.join("snap/config.json"), "{}").unwrap();
        fs::write(root.join("snap/tokenizer.json"), "{}").unwrap();
        fs::write(root.join("snap/model.safetensors"), [0_u8; 8]).unwrap();
        fs::create_dir_all(root.join("incomplete")).unwrap();
        fs::write(root.join("incomplete/config.json"), "{}").unwrap();
        fs::write(root.join("incomplete/model.safetensors.partial"), [0_u8; 8]).unwrap();
        fs::write(root.join("weights.gguf"), [0_u8; 32]).unwrap();

        assert_eq!(inspect_model_path(&root.join("weights.gguf")), (true, 32));
        let (present, bytes) = inspect_model_path(&root.join("snap"));
        assert!(present);
        assert!(bytes >= 2);
        assert!(!inspect_model_path(&root.join("incomplete")).0);
        assert_eq!(inspect_model_path(&root.join("missing")), (false, 0));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn unknown_pack_is_an_error() {
        let error = specs_for_download(Some("nope")).unwrap_err();
        assert!(error.contains("unknown model pack"));
    }
}
