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

pub const QWEN3_ASR_REPOSITORY: &str = "Qwen/Qwen3-ASR-1.7B";
pub const QWEN3_ASR_REVISION: &str = "7278e1e70fe206f11671096ffdd38061171dd6e5";
pub const QWEN3_ASR_EXPECTED_BYTES: u64 = 4_703_114_308;
pub const NOMIC_EMBED_REPOSITORY: &str = "nomic-ai/nomic-embed-text-v1.5-GGUF";
pub const NOMIC_EMBED_FILE: &str = "nomic-embed-text-v1.5.Q4_K_M.gguf";
pub const NOMIC_EMBED_REVISION: &str = "0188c9bf409793f810680a5a431e7b899c46104c";
pub const NOMIC_EMBED_EXPECTED_BYTES: u64 = 84_106_624;
const NOMIC_EMBED_SHA256: &str = "d4e388894e09cf3816e8b0896d81d265b55e7a9fff9ab03fe8bf4ef5e11295ac";

/// The architectural context window of a managed MLX pack, in tokens.
///
/// Both packs are Qwen3.5, which declares 262 144 at 4B and at 9B. It lives
/// beside the revisions and the byte counts because it is the same kind of
/// fact: a property of this pinned checkpoint, not of the machine running it.
/// What the machine can hold is a separate limit, applied on top.
#[must_use]
pub fn mlx_pack_context_tokens(pack_id: &str) -> Option<usize> {
    match pack_id {
        QWEN35_4B_MLX_PACK_ID | QWEN35_9B_MLX_PACK_ID => Some(262_144),
        _ => None,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestFile {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
}

/// Exact content pin for a snapshot that keeps the plain on-disk layout: the
/// commit plus a SHA-256 per file, so bytes from any endpoint — a mirror
/// included — are checked against hashes recorded here, not against whatever
/// the server claims. Unlike `HuggingFacePinnedSnapshot` it adds no staging
/// directory or ready marker, so already-installed packs stay valid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotPin {
    pub revision: String,
    pub files: Vec<ManifestFile>,
}

/// Hugging Face snapshot (many files) or a single downloadable weight file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackSource {
    HuggingFaceSnapshot {
        repository: String,
        /// `None` only when an `AFTERRAY_*` override points at a custom
        /// repository — unknown content, nothing to verify against.
        pin: Option<SnapshotPin>,
    },
    HuggingFacePinnedSnapshot {
        repository: String,
        revision: String,
        files: Vec<ManifestFile>,
    },
    HuggingFaceFile {
        repository: String,
        file: String,
        /// Git revision the file is resolved at; `main` when unpinned.
        revision: String,
        /// Expected SHA-256; `None` only for env-overridden custom files.
        sha256: Option<String>,
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
            PackSource::HuggingFaceSnapshot { pin, .. } => {
                pin.as_ref().map(|pin| pin.revision.as_str())
            }
            PackSource::HuggingFaceFile {
                revision, sha256, ..
            } => sha256.is_some().then_some(revision.as_str()),
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
    // An env override points at content this catalog knows nothing about, so
    // the pin — and with it verification — only applies to the default source.
    let asr_repository = env_or("AFTERRAY_ASR_REPOSITORY", QWEN3_ASR_REPOSITORY);
    let asr_pin = (asr_repository == QWEN3_ASR_REPOSITORY).then(|| SnapshotPin {
        revision: QWEN3_ASR_REVISION.into(),
        files: qwen3_asr_manifest(),
    });
    let asr_expected = if asr_pin.is_some() {
        QWEN3_ASR_EXPECTED_BYTES
    } else {
        4_200_000_000
    };
    let embedding_repository = env_or("AFTERRAY_EMBEDDING_REPOSITORY", NOMIC_EMBED_REPOSITORY);
    let embedding_file = env_or("AFTERRAY_EMBEDDING_FILE", NOMIC_EMBED_FILE);
    let embedding_pinned =
        embedding_repository == NOMIC_EMBED_REPOSITORY && embedding_file == NOMIC_EMBED_FILE;
    vec![
        PackSpec {
            id: "asr".into(),
            name: "Qwen3 ASR".into(),
            capability: "asr".into(),
            path: env_or_join("AFTERRAY_ASR_MODEL", directory, "Qwen3-ASR-1.7B"),
            required: true,
            note: format!("{asr_repository} · official safetensors · ZH/EN/JA · Rust/Candle"),
            expected_bytes: asr_expected,
            source: PackSource::HuggingFaceSnapshot {
                repository: asr_repository,
                pin: asr_pin,
            },
        },
        PackSpec {
            id: "embedding".into(),
            name: "Text embeddings".into(),
            capability: "embedding".into(),
            path: env_or_join("AFTERRAY_EMBEDDING_MODEL", directory, NOMIC_EMBED_FILE),
            required: true,
            note: "nomic-embed-text v1.5 Q4 · llama.cpp".into(),
            expected_bytes: if embedding_pinned {
                NOMIC_EMBED_EXPECTED_BYTES
            } else {
                84_000_000
            },
            source: PackSource::HuggingFaceFile {
                repository: embedding_repository,
                file: embedding_file,
                revision: if embedding_pinned {
                    NOMIC_EMBED_REVISION.into()
                } else {
                    "main".into()
                },
                sha256: embedding_pinned.then(|| NOMIC_EMBED_SHA256.into()),
            },
        },
        qwen35_mlx_pack(directory),
        qwen35_9b_mlx_pack(directory),
    ]
}

/// Everything `Qwen/Qwen3-ASR-1.7B` ships at [`QWEN3_ASR_REVISION`] — the same
/// set the unpinned listing used to return, so behaviour only gains the hash
/// check. LFS hashes come from Hugging Face's own LFS records; the small JSON
/// and tokenizer files were fetched at that commit and hashed directly.
#[must_use]
pub fn qwen3_asr_manifest() -> Vec<ManifestFile> {
    const FILES: &[(&str, u64, &str)] = &[
        (
            ".gitattributes",
            1_519,
            "11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361",
        ),
        (
            "README.md",
            57_456,
            "5058416891bc47a2051557765997e8c42f8eb78a0e33c3e775bd17d4b0ba4d50",
        ),
        (
            "chat_template.json",
            1_161,
            "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff",
        ),
        (
            "config.json",
            6_194,
            "2e74a751548b8ad7d7526d29365ad8144c345d8b412b1152d25dc6698452712f",
        ),
        (
            "generation_config.json",
            142,
            "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c",
        ),
        (
            "merges.txt",
            1_671_853,
            "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
        ),
        (
            "model-00001-of-00002.safetensors",
            4_220_320_824,
            "a4cd1f1a04d90b757dc7f7dd26254e69a013b19e80efe590a83c6a3bde8608d6",
        ),
        (
            "model-00002-of-00002.safetensors",
            478_200_688,
            "6e0b9d9e09e2e0238e7ef3cc8a484ab387e91b90f1900bedf88bc92d7929ccfc",
        ),
        (
            "model.safetensors.index.json",
            64_821,
            "f994739fe38e5210b9e3e8ce6c6307315e2ceac3cb630e7b7414d69dce520f60",
        ),
        (
            "preprocessor_config.json",
            330,
            "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d",
        ),
        (
            "tokenizer_config.json",
            12_487,
            "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c",
        ),
        (
            "vocab.json",
            2_776_833,
            "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
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

    /// The pins are what make third-party download mirrors safe to use:
    /// sizes and hashes are recorded here, never taken from the server.
    #[test]
    fn asr_and_embedding_are_pinned_with_matching_totals() {
        let catalog = catalog_in(Path::new("/tmp/afterray-models"));

        let asr = catalog.iter().find(|pack| pack.id == "asr").unwrap();
        let PackSource::HuggingFaceSnapshot { pin: Some(pin), .. } = &asr.source else {
            panic!("the default asr pack must carry a pin");
        };
        assert_eq!(pin.revision, QWEN3_ASR_REVISION);
        assert_eq!(
            pin.files.iter().map(|file| file.bytes).sum::<u64>(),
            asr.expected_bytes,
            "expected_bytes must equal the manifest total or progress lies"
        );
        assert!(pin.files.iter().all(|file| file.sha256.len() == 64));
        assert_eq!(asr.revision(), Some(QWEN3_ASR_REVISION));

        let embedding = catalog.iter().find(|pack| pack.id == "embedding").unwrap();
        let PackSource::HuggingFaceFile {
            revision,
            sha256: Some(sha256),
            ..
        } = &embedding.source
        else {
            panic!("the default embedding pack must carry a pinned hash");
        };
        assert_eq!(revision, NOMIC_EMBED_REVISION);
        assert_eq!(sha256.len(), 64);
        assert_eq!(embedding.expected_bytes, NOMIC_EMBED_EXPECTED_BYTES);
        assert_eq!(embedding.revision(), Some(NOMIC_EMBED_REVISION));
    }

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
