use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::Zeroize as _;

pub mod cli_access;
pub mod socket;

pub use cli_access::{
    APP_TOKEN_ENV, CLI_EVIDENCE_WINDOW_MS, CLI_FORBIDDEN, CliRequestClass, EVIDENCE_ACCESS_DISABLED,
    authorize_cli_request, cli_request_class, evidence_window_open, redact_cli_response_data,
    redact_moment_for_cli, redact_search_hit_for_cli,
};

pub const DEFAULT_STORAGE_LIMIT_BYTES: u64 = 100_000_000_000;
/// Bumped whenever the request or event vocabulary changes.
///
/// The handshake is strict equality, so a version that does not move is worse
/// than useless: at 7, an app that knows `ChatAbort` and a daemon that does not
/// both claim 7, the handshake passes, the abort fails to deserialise, and —
/// because a hang-up no longer cancels — the user presses stop and the model
/// runs to completion with nothing said. 8 adds `ChatAbort` and the `started`,
/// `usage`, `progress` and `compaction` stream events. 9 adds
/// `CaptureSetPaused`. 10 adds `CancelModelDownload`, which drops one pack from
/// the download queue instead of tearing the whole queue down. 11 streams the
/// model's reasoning so the chat UI can show thinking as it happens. 12 adds
/// the privacy-bounded parsed summary export. 13 adds the CLI evidence
/// window (`cli_evidence_until_ms` / `cli_evidence_access`) and treats
/// unprivileged socket clients as a gated query surface.
pub const PROTOCOL_VERSION: u32 = 13;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordingState {
    Idle,
    Waiting,
    Recording,
    Stopping,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    Ping,
    Status,
    RecordStart,
    RecordStop {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// Suspends or resumes scheduled screen captures without tearing the
    /// recording session down. The app sets this while its overlay is
    /// frontmost, so whatever the overlay covers is never photographed;
    /// unlike `RecordStop` the session, shim and audio keep running.
    CaptureSetPaused {
        paused: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    SessionsList,
    TimelineList,
    TimelineSince {
        since_ms: i64,
    },
    MomentsList {
        session_id: String,
    },
    RecallWindow {
        session_id: String,
        center_ms: i64,
        limit: usize,
    },
    ReadArtifact {
        artifact_id: String,
    },
    ReadGopSegment {
        segment_id: String,
    },
    ReadGopFrame {
        segment_id: String,
        index: u16,
        mode: GopReadMode,
    },
    /// Smallest available pixels for a moment, for the search filmstrip.
    ///
    /// Usually a cached `image/jpeg` thumbnail. Moments packed into a cold GOP
    /// before thumbnails existed answer with the IVF frame instead — the
    /// daemon cannot decode AV1 — so callers must honour `content_type`.
    ReadThumbnail {
        moment_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max_edge: Option<u32>,
    },
    PackStatus,
    GopShow {
        segment_id: String,
    },
    FavoriteSet {
        moment_id: String,
        favorite: bool,
    },
    Search {
        query: String,
        limit: usize,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from_ms: Option<i64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to_ms: Option<i64>,
    },
    MomentGet {
        moment_id: String,
    },
    /// Nearest moment to a wall-clock instant. Entry point for agent tools
    /// that address evidence by time rather than by id.
    MomentAt {
        at_ms: i64,
    },
    /// Deterministic T1 card for the slot containing `at_ms`.
    SlotCard {
        at_ms: i64,
    },
    /// T1 card rendered as the prompt handed to a T2 agent.
    SlotPrompt {
        at_ms: i64,
    },
    /// Runs the T2 pass for a slot through the configured model and returns
    /// the parsed card alongside timing and the raw completion.
    SlotSummarize {
        at_ms: i64,
    },
    /// Summarises every slot in the last `days` local days that T1 marked ready
    /// and no model has touched. The background sweeper only reaches back two
    /// days; this is how older history gets filled in.
    SlotBackfill {
        days: i64,
    },
    /// Parsed persisted P2 plus visible facts and generation metadata. This
    /// never returns capture evidence, prompts, tool results, or raw model
    /// completions.
    SlotSummaryExport {
        at_ms: i64,
    },
    /// Every occupied half-hour on the local day containing `day_ms`.
    /// Slots the model has never touched are included with facts only.
    DaySummary {
        day_ms: i64,
    },
    /// A cursor-paginated run of occupied local days, newest first. The
    /// cursor is exclusive: pass `next_before_ms` unchanged to get older
    /// summaries without overlaps.
    SummaryHistory {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before_ms: Option<i64>,
        #[serde(default = "default_summary_history_limit")]
        limit: usize,
    },
    EvidenceOcr {
        moment_id: String,
    },
    EvidenceAx {
        moment_id: String,
        /// When true (default), return only the accessibility digest, not the full tree.
        #[serde(default = "default_true")]
        digest_only: bool,
    },
    ActivitySpans {
        from_ms: i64,
        to_ms: i64,
        #[serde(default = "default_activity_spans_limit")]
        limit: usize,
    },
    ModelsStatus,
    JobsList,
    JobRetry {
        job_id: String,
    },
    Summarize {
        session_id: String,
    },
    Ask {
        question: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from_ms: Option<i64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to_ms: Option<i64>,
    },
    ChatSend {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation_id: Option<String>,
        message: String,
    },
    /// NDJSON event stream for one chat turn. The daemon writes event lines
    /// until `done` or `error` instead of a single [`Response`].
    ChatStream {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation_id: Option<String>,
        message: String,
    },
    /// Stop the turn running on `conversation_id`, from a second connection.
    ///
    /// Explicit, rather than inferred from a closed socket, because the two
    /// mean opposite things: pressing stop is "do not finish this", while
    /// closing the panel is "I will read it later". Only the first should end
    /// the turn — see the daemon's `run_watching_for_hangup`.
    ChatAbort {
        conversation_id: String,
    },
    ChatList,
    ChatHistory {
        conversation_id: String,
    },
    ChatDelete {
        conversation_id: String,
    },
    Settings,
    UpdateSettings {
        #[serde(skip_serializing_if = "Option::is_none")]
        record_audio: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ui_language: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        summary_language: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        storage_limit_bytes: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        excluded_bundle_ids: Option<Vec<String>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        excluded_domains: Option<Vec<String>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_provider: Option<LlmProvider>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_base_url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_api_key: Option<String>,
        /// Base URL model downloads resolve against. Empty string restores
        /// the official huggingface.co endpoint; `None` leaves it unchanged.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model_download_endpoint: Option<String>,
        /// App-only. `true` opens a 30-minute CLI evidence window from now;
        /// `false` closes it. `None` leaves it unchanged.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cli_evidence_access: Option<bool>,
    },
    LlmProbe {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        provider: Option<LlmProvider>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        base_url: Option<String>,
    },
    ClearHistory {
        scope: HistoryScope,
    },
    MemoriesList {
        from_ms: i64,
        to_ms: i64,
        #[serde(default = "default_memories_limit")]
        limit: usize,
    },
    DownloadModels {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pack_id: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        pack_ids: Vec<String>,
    },
    PauseModelDownloads,
    ResumeModelDownloads,
    CancelModelDownloads,
    /// Drops a single pack — active or merely queued — and discards its partial
    /// files. The rest of the queue keeps going, which is what separates this
    /// from `CancelModelDownloads`.
    CancelModelDownload {
        pack_id: String,
    },
    RemoveModel {
        pack_id: String,
    },
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelLibrary {
    pub directory: String,
    pub packs: Vec<ModelPack>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub download: Option<ModelDownloadProgress>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelDownloadProgress {
    pub pack_id: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub queued_pack_ids: Vec<String>,
    #[serde(default)]
    pub state: ModelPackState,
    pub bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_bytes: Option<u64>,
    pub completed_files: u64,
    pub total_files: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ModelPackState {
    #[default]
    NotDownloaded,
    Downloading,
    Verifying,
    Paused,
    Ready,
    InUse,
    Failed,
    Incompatible,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelPack {
    pub id: String,
    pub name: String,
    pub capability: String,
    pub path: String,
    pub present: bool,
    #[serde(default)]
    pub state: ModelPackState,
    pub bytes: u64,
    pub required: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub protocol_version: u32,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Response {
    #[must_use]
    pub fn success(data: impl Serialize) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            ok: true,
            data: Some(serde_json::to_value(data).unwrap_or(Value::Null)),
            error: None,
        }
    }

    #[must_use]
    pub fn failure(error: impl Into<String>) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            ok: false,
            data: None,
            error: Some(error.into()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Status {
    pub daemon_version: String,
    pub protocol_version: u32,
    pub schema_version: u32,
    pub recording_state: RecordingState,
    pub active_session_id: Option<String>,
    /// `CFBundleVersion` of the app that spawned this daemon, echoed back from
    /// `AFTERRAY_HOST_BUILD`. The marketing version alone cannot tell two
    /// builds of the same release apart, so an updated app uses this to notice
    /// that the socket is still owned by the daemon it just replaced.
    #[serde(default)]
    pub host_build: Option<String>,
    /// When CLI evidence is temporarily allowed, the wall-clock instant it
    /// closes. Absent or in the past means closed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_evidence_until_ms: Option<i64>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum LlmProvider {
    #[default]
    MlxLocal,
    Ollama,
    OpenaiCompatible,
}

impl LlmProvider {
    #[must_use]
    pub const fn as_label(self) -> &'static str {
        match self {
            Self::MlxLocal => "mlx_local",
            Self::Ollama => "ollama",
            Self::OpenaiCompatible => "openai_compatible",
        }
    }

    /// `builtin`/`local` are the retired llama.cpp GGUF backend. Settings
    /// saved before it was removed still carry those labels, so they land on
    /// the managed MLX packs rather than failing the whole settings load.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "mlx" | "mlx_local" | "mlx-local" | "builtin" | "built_in" | "local" => {
                Some(Self::MlxLocal)
            }
            "ollama" => Some(Self::Ollama),
            "openai" | "openai_compatible" | "openai-compatible" => Some(Self::OpenaiCompatible),
            _ => None,
        }
    }
}

/// Decoded through `parse` so a settings file written by an older build —
/// or a client sending an unknown label — degrades to the default provider
/// instead of rejecting the message.
impl<'de> Deserialize<'de> for LlmProvider {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        Ok(Self::parse(&raw).unwrap_or_default())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LlmRemoteModel {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LlmEndpointStatus {
    pub reachable: bool,
    pub models: Vec<LlmRemoteModel>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recommended_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub default_base_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppSettings {
    pub data_dir: String,
    pub model_dir: String,
    pub record_audio: bool,
    pub capture_interval_seconds: u64,
    #[serde(default = "default_storage_limit_bytes")]
    pub storage_limit_bytes: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excluded_bundle_ids: Vec<String>,
    /// Credential-bearing and system surfaces the daemon always excludes.
    /// Clients use this to explain why these rows cannot be removed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub protected_bundle_ids: Vec<String>,
    /// Hosts whose pages are never recorded. Matched on the URL the
    /// accessibility snapshot reports, subdomains included.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excluded_domains: Vec<String>,
    #[serde(default)]
    pub llm_provider: LlmProvider,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub llm_base_url: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub llm_model: String,
    #[serde(default)]
    pub llm_api_key_set: bool,
    /// Language for the application's own interface.
    #[serde(default = "default_language")]
    pub ui_language: String,
    /// Language the summarising agent writes cards in. Independent of the
    /// interface: reading a UI in English while wanting summaries in your
    /// own language is a normal combination.
    #[serde(default = "default_language")]
    pub summary_language: String,
    /// The catalogue the settings UI renders, so one list serves every client.
    #[serde(default = "summary_language_options")]
    pub language_options: Vec<LanguageOption>,
    /// Mirror model downloads resolve against; empty means the official
    /// huggingface.co endpoint. Pack integrity never depends on this — pinned
    /// packs verify against SHA-256 hashes shipped in the daemon.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub model_download_endpoint: String,
    /// Wall-clock close of the CLI evidence window. `None` means off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_evidence_until_ms: Option<i64>,
}

/// A language a summary can be written in.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LanguageOption {
    /// BCP-47 tag, or `auto` to follow the system language.
    pub code: String,
    /// Name in the language itself — a Japanese speaker scanning the list
    /// looks for 日本語, not "Japanese".
    pub native_name: String,
    /// English name, for accessibility labels and search.
    pub english_name: String,
}

/// Languages offered for summary output. `auto` first, then the sixteen
/// most widely used, ordered by global speaker count.
#[must_use]
pub fn summary_language_options() -> Vec<LanguageOption> {
    const ENTRIES: &[(&str, &str, &str)] = &[
        ("auto", "跟随系统 / System", "Follow system"),
        ("en", "English", "English"),
        ("zh-Hans", "简体中文", "Chinese (Simplified)"),
        ("zh-Hant", "繁體中文", "Chinese (Traditional)"),
        ("es", "Español", "Spanish"),
        ("hi", "हिन्दी", "Hindi"),
        ("ar", "العربية", "Arabic"),
        ("pt", "Português", "Portuguese"),
        ("ru", "Русский", "Russian"),
        ("ja", "日本語", "Japanese"),
        ("de", "Deutsch", "German"),
        ("fr", "Français", "French"),
        ("ko", "한국어", "Korean"),
        ("it", "Italiano", "Italian"),
        ("tr", "Türkçe", "Turkish"),
        ("vi", "Tiếng Việt", "Vietnamese"),
        ("id", "Bahasa Indonesia", "Indonesian"),
    ];
    ENTRIES
        .iter()
        .map(|(code, native_name, english_name)| LanguageOption {
            code: (*code).to_owned(),
            native_name: (*native_name).to_owned(),
            english_name: (*english_name).to_owned(),
        })
        .collect()
}

/// The name a model should be told to write in, for a stored language code.
/// Falls back to English for anything unrecognised, including `auto` — the
/// caller resolves `auto` against the system language before calling.
#[must_use]
pub fn language_display_name(code: &str) -> String {
    summary_language_options()
        .into_iter()
        .find(|option| option.code.eq_ignore_ascii_case(code))
        .map_or_else(|| "English".to_owned(), |option| option.english_name)
}

fn default_language() -> String {
    "auto".to_owned()
}

const fn default_storage_limit_bytes() -> u64 {
    DEFAULT_STORAGE_LIMIT_BYTES
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HistoryScope {
    LastHour,
    Today,
    All,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Conversation {
    pub id: String,
    pub title: String,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub message_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConversationMessage {
    pub id: String,
    pub conversation_id: String,
    /// `user` or `assistant`.
    pub role: String,
    pub content: String,
    /// Which tools the assistant ran for this turn, as JSON. Kept so the UI
    /// can show its work and a later session can tell what was already
    /// looked up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_log: Option<String>,
    /// The model's reasoning for this turn, as a JSON array of
    /// `{"round": n, "text": "…"}`.
    ///
    /// A JSON array rather than one blob because reasoning is produced per
    /// round, and the one API that requires it back — `DeepSeek`'s
    /// `reasoning_content`, which 400s on multi-turn without it — wants it
    /// verbatim per assistant message. Keeping the rounds apart leaves that
    /// possible; concatenating would not.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<String>,
    /// `streaming`, `complete` or `aborted`. `None` on every row written
    /// before turns were persisted as they ran, all of which finished.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
    /// Context occupancy of the turn that wrote this row, as JSON. Read back
    /// when a thread is reopened so the meter does not have to be invented.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage_json: Option<String>,
    pub created_at_ms: i64,
}

/// What a stored assistant row is: still being written, finished, or stopped.
pub const MESSAGE_STATUS_STREAMING: &str = "streaming";
pub const MESSAGE_STATUS_COMPLETE: &str = "complete";
pub const MESSAGE_STATUS_ABORTED: &str = "aborted";

/// Reply to [`Request::ChatSend`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatReply {
    pub conversation: Conversation,
    pub answer: String,
    pub user_message_id: String,
    pub assistant_message_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_log: Option<String>,
    #[serde(default)]
    pub model_missing: bool,
}

/// One conversation plus its messages, in order.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatThread {
    pub conversation: Conversation,
    pub messages: Vec<ConversationMessage>,
}

/// Reply to [`Request::ChatDelete`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatDeleteResult {
    pub deleted: bool,
    pub id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Memory {
    pub id: String,
    pub start_ms: i64,
    pub end_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub moment_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub application_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_identifier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<String>,
    pub summary: String,
    pub fingerprint: String,
}

fn default_memories_limit() -> usize {
    40
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub started_at_ms: i64,
    pub ended_at_ms: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Moment {
    pub id: String,
    pub session_id: String,
    pub captured_at_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_artifact_id: Option<String>,
    pub is_favorite: bool,
    pub ocr_text: Option<String>,
    pub transcript_text: Option<String>,
    pub audio_artifact_id: Option<String>,
    pub audio_started_at_ms: Option<i64>,
    pub accessibility_artifact_id: Option<String>,
    pub application_name: Option<String>,
    pub bundle_identifier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gop: Option<GopRef>,
    #[serde(default = "default_still_origin")]
    pub still_origin: String,
}

fn default_still_origin() -> String {
    "capture".to_owned()
}

fn default_activity_spans_limit() -> usize {
    100
}

const fn default_summary_history_limit() -> usize {
    7
}

const fn default_true() -> bool {
    true
}

/// OCR text for a moment, optionally with Vision-normalized regions.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OcrEvidence {
    pub moment_id: String,
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub regions: Vec<OcrRegion>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct OcrRegion {
    pub text: String,
    pub confidence: f32,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

/// Accessibility digest and optional full tree JSON for a moment.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AxEvidence {
    pub moment_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tree_json: Option<String>,
}

/// Consecutive moments that share an app identity and the same URL, document,
/// or window title. Derived at query time; not a persisted table.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActivitySpan {
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub application_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundle_identifier: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<String>,
    pub moment_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GopRef {
    pub segment_id: String,
    pub index: u16,
    pub keyframe_index: u16,
    pub frame_count: u16,
    pub codec: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GopReadMode {
    Poster,
    Exact,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PackStatus {
    pub archive_enabled: bool,
    /// Always false. Cold packed frames drop unpinned JPEGs; Dual write is gone.
    pub keep_stills: bool,
    pub keyint: u16,
    pub encoder: String,
    pub hot_window_seconds: u64,
    pub running_jobs: u64,
    pub done_jobs: u64,
    pub failed_jobs: u64,
    pub ready_segments: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GopSegmentView {
    pub id: String,
    pub artifact_id: String,
    pub codec: String,
    pub encoder: String,
    pub width: u32,
    pub height: u32,
    pub frame_count: u16,
    pub keyint: u16,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub status: String,
    pub frames: Vec<GopFrameView>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GopFrameView {
    pub index: u16,
    pub moment_id: String,
    pub is_keyframe: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioSegment {
    pub id: String,
    pub session_id: String,
    pub track: AudioTrack,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub audio_artifact_id: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AudioTrack {
    System,
    Microphone,
}

/// JSON header for `read_artifact`. The decrypted bytes follow the newline
/// as a raw payload of exactly `byte_length` octets. Failures are a JSON
/// line with no trailing body.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ArtifactMeta {
    pub id: String,
    pub content_type: String,
    pub byte_length: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gop_index: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyframe_index: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ArtifactPayload {
    pub id: String,
    pub content_type: String,
    pub bytes: Vec<u8>,
}

impl Drop for ArtifactPayload {
    fn drop(&mut self) {
        self.bytes.zeroize();
    }
}

impl ArtifactPayload {
    #[must_use]
    pub fn meta(&self) -> ArtifactMeta {
        ArtifactMeta {
            id: self.id.clone(),
            content_type: self.content_type.clone(),
            byte_length: u64::try_from(self.bytes.len()).unwrap_or(u64::MAX),
            codec: None,
            gop_index: None,
            keyframe_index: None,
        }
    }

    /// Encodes the JSON response header preceding the raw artifact bytes.
    ///
    /// # Errors
    ///
    /// Returns an error if the response metadata cannot be serialized as JSON.
    pub fn header_line(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut header = serde_json::to_vec(&Response::success(self.meta()))?;
        header.push(b'\n');
        Ok(header)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub moment_id: String,
    pub session_id: String,
    pub captured_at_ms: i64,
    pub source: String,
    pub text: String,
    pub score: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AskCitation {
    pub moment_id: String,
    pub captured_at_ms: i64,
    pub label: String,
    pub excerpt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AskAnswer {
    pub answer: String,
    #[serde(default)]
    pub citations: Vec<AskCitation>,
    #[serde(default)]
    pub model_missing: bool,
}

/// One line of a [`Request::ChatStream`] response.
///
/// Tokens are optional: adapters that cannot stream omit them until the
/// finished answer is known, then emit a single `token` so clients can
/// treat every turn the same way.
///
/// Growing this enum is additive by contract. A client that meets a `kind` it
/// does not know must skip the line, and new fields on an existing kind must
/// be `#[serde(default)]` so an older daemon's lines still decode.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ChatStreamEvent {
    ToolCall {
        name: String,
        args: Value,
    },
    ToolResult {
        name: String,
        chars: usize,
        /// Whether the result was cut to fit its budget. The app says so on the
        /// bubble: an answer built from a shortened result deserves the caveat.
        #[serde(default)]
        truncated: bool,
        /// Estimated tokens the cut removed.
        #[serde(default)]
        dropped: usize,
    },
    Token {
        text: String,
    },
    /// One incremental reasoning fragment from a model that exposes it.
    Reasoning {
        text: String,
        round: usize,
    },
    /// How full the context window is, once per round.
    ///
    /// Context pressure was invisible from every angle before this: the user
    /// could not see that a long thread was crowding the window, and neither
    /// could anyone reading a bug report.
    Usage {
        prompt_tokens: usize,
        window_tokens: usize,
        round: usize,
    },
    /// The turn is alive but has nothing to show yet.
    ///
    /// Covers every stretch where the window would otherwise sit empty: a
    /// thinking model streaming reasoning, a cold model load before the first
    /// byte, and the generation of a `TOOL` draft that the answer gate hides.
    /// A client that renders `elapsed_ms` or `reasoning_deltas` as a changing
    /// number can answer "is it stuck" without trusting an animation.
    Progress {
        /// `generating` or `thinking`. A string rather than a closed set, so a
        /// later phase does not break an older client's decode.
        phase: String,
        #[serde(default)]
        reasoning_deltas: usize,
        #[serde(default)]
        elapsed_ms: u64,
        #[serde(default)]
        round: usize,
    },
    /// An earlier part of the turn was dropped to make room.
    ///
    /// Announced rather than silent, and carrying the range it covers, so the
    /// thread can show where the agent stopped being able to see.
    Compaction {
        strategy: String,
        from_round: usize,
        to_round: usize,
        tokens_before: usize,
        tokens_after: usize,
    },
    /// The row this turn will be written to, sent before any output.
    ///
    /// The assistant message exists in the vault from the moment the stream
    /// opens, so a client can name it immediately and does not have to invent a
    /// local placeholder that no reload would ever match.
    Started {
        message_id: String,
        conversation_id: String,
    },
    Done {
        message_id: String,
        conversation_id: String,
    },
    Error {
        message: String,
    },
}

impl ChatStreamEvent {
    /// Encodes one NDJSON line, including the trailing newline.
    ///
    /// # Errors
    ///
    /// Returns an error if the event cannot be serialized.
    pub fn to_ndjson_line(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut line = serde_json::to_vec(self)?;
        line.push(b'\n');
        Ok(line)
    }
}

/// Inclusive local-calendar day bounds containing `now_ms`.
///
/// Used when an [`Request::Ask`] omits `from_ms` / `to_ms`.
#[must_use]
pub fn local_calendar_day_bounds_ms(now_ms: i64) -> (i64, i64) {
    use chrono::{Local, NaiveTime};

    let now = chrono::DateTime::from_timestamp_millis(now_ms)
        .unwrap_or_else(chrono::Utc::now)
        .with_timezone(&Local);
    let date = now.date_naive();
    let midnight = NaiveTime::from_hms_opt(0, 0, 0).unwrap_or_default();
    let start_naive = date.and_time(midnight);
    let start_ms = resolve_local_ms(start_naive).unwrap_or(now_ms);
    let end_ms = date
        .succ_opt()
        .and_then(|next| resolve_local_ms(next.and_time(midnight)))
        .map_or(now_ms, |next_start| next_start.saturating_sub(1));
    (start_ms.min(end_ms), end_ms.max(start_ms))
}

fn resolve_local_ms(naive: chrono::NaiveDateTime) -> Option<i64> {
    use chrono::{Local, TimeZone as _};
    Local
        .from_local_datetime(&naive)
        .earliest()
        .or_else(|| Local.from_local_datetime(&naive).latest())
        .map(|dt| dt.timestamp_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trip_is_stable() {
        let json = serde_json::to_string(&Request::RecordStart).unwrap();
        assert_eq!(json, r#"{"type":"record_start"}"#);
        let decoded: Request = serde_json::from_str(&json).unwrap();
        assert!(matches!(decoded, Request::RecordStart));
        let stop: Request = serde_json::from_str(r#"{"type":"record_stop"}"#).unwrap();
        assert!(matches!(stop, Request::RecordStop { reason: None }));
        let locked: Request =
            serde_json::from_str(r#"{"type":"record_stop","reason":"lock"}"#).unwrap();
        assert!(matches!(
            locked,
            Request::RecordStop {
                reason: Some(ref value)
            } if value == "lock"
        ));
    }

    #[test]
    fn shutdown_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::Shutdown).unwrap();
        assert_eq!(json, r#"{"type":"shutdown"}"#);
    }

    #[test]
    fn capture_set_paused_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::CaptureSetPaused {
            paused: true,
            reason: None,
        })
        .unwrap();
        assert_eq!(json, r#"{"type":"capture_set_paused","paused":true}"#);
        let json = serde_json::to_string(&Request::CaptureSetPaused {
            paused: false,
            reason: Some("overlay".into()),
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"capture_set_paused","paused":false,"reason":"overlay"}"#
        );
        let decoded: Request =
            serde_json::from_str(r#"{"type":"capture_set_paused","paused":true}"#).unwrap();
        assert!(matches!(
            decoded,
            Request::CaptureSetPaused {
                paused: true,
                reason: None
            }
        ));
    }

    #[test]
    fn timeline_cursor_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::TimelineSince { since_ms: 42 }).unwrap();
        assert_eq!(json, r#"{"type":"timeline_since","since_ms":42}"#);
    }

    #[test]
    fn day_summary_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::DaySummary { day_ms: 42 }).unwrap();
        assert_eq!(json, r#"{"type":"day_summary","day_ms":42}"#);
    }

    #[test]
    fn summary_history_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::SummaryHistory {
            before_ms: Some(42),
            limit: 7,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"summary_history","before_ms":42,"limit":7}"#
        );
    }

    #[test]
    fn slot_summary_export_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::SlotSummaryExport { at_ms: 42 }).unwrap();
        assert_eq!(json, r#"{"type":"slot_summary_export","at_ms":42}"#);
    }

    #[test]
    fn settings_wire_shape_is_stable() {
        assert_eq!(
            serde_json::to_string(&Request::Settings).unwrap(),
            r#"{"type":"settings"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::UpdateSettings {
                record_audio: Some(false),
                ui_language: None,
                summary_language: None,
                storage_limit_bytes: None,
                excluded_bundle_ids: None,
                excluded_domains: None,
                llm_provider: None,
                llm_base_url: None,
                llm_model: None,
                llm_api_key: None,
                model_download_endpoint: None,
                cli_evidence_access: None,
            })
            .unwrap(),
            r#"{"type":"update_settings","record_audio":false}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::UpdateSettings {
                record_audio: None,
                ui_language: None,
                summary_language: None,
                storage_limit_bytes: None,
                excluded_bundle_ids: None,
                excluded_domains: None,
                llm_provider: None,
                llm_base_url: None,
                llm_model: None,
                llm_api_key: None,
                model_download_endpoint: Some("https://hf-mirror.com".into()),
                cli_evidence_access: None,
            })
            .unwrap(),
            r#"{"type":"update_settings","model_download_endpoint":"https://hf-mirror.com"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::LlmProbe {
                provider: Some(LlmProvider::Ollama),
                base_url: None,
            })
            .unwrap(),
            r#"{"type":"llm_probe","provider":"ollama"}"#
        );
    }

    #[test]
    fn app_settings_decode_defaults_llm_fields() {
        let settings: AppSettings = serde_json::from_str(
            r#"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10}"#,
        )
        .unwrap();
        assert_eq!(settings.llm_provider, LlmProvider::MlxLocal);
        assert!(settings.llm_base_url.is_empty());
        assert!(settings.llm_model.is_empty());
        assert!(!settings.llm_api_key_set);
        assert_eq!(settings.storage_limit_bytes, DEFAULT_STORAGE_LIMIT_BYTES);
        assert!(
            settings.model_download_endpoint.is_empty(),
            "no endpoint field means the official one"
        );
    }

    #[test]
    fn retired_builtin_provider_decodes_as_the_local_mlx_pack() {
        let settings: AppSettings = serde_json::from_str(
            r#"{"data_dir":"/tmp/data","model_dir":"/tmp/models","record_audio":true,"capture_interval_seconds":10,"llm_provider":"builtin"}"#,
        )
        .unwrap();
        assert_eq!(settings.llm_provider, LlmProvider::MlxLocal);
        assert_eq!(LlmProvider::parse("built_in"), Some(LlmProvider::MlxLocal));
        assert_eq!(LlmProvider::parse("local"), Some(LlmProvider::MlxLocal));
        assert_eq!(LlmProvider::parse("nonsense"), None);
    }

    #[test]
    fn storage_limit_update_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::UpdateSettings {
            record_audio: None,
            ui_language: None,
            summary_language: None,
            storage_limit_bytes: Some(250_000_000_000),
            excluded_bundle_ids: None,
            excluded_domains: None,
            llm_provider: None,
            llm_base_url: None,
            llm_model: None,
            llm_api_key: None,
            model_download_endpoint: None,
            cli_evidence_access: None,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"update_settings","storage_limit_bytes":250000000000}"#
        );
    }

    #[test]
    fn cli_evidence_access_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::UpdateSettings {
            record_audio: None,
            ui_language: None,
            summary_language: None,
            storage_limit_bytes: None,
            excluded_bundle_ids: None,
            excluded_domains: None,
            llm_provider: None,
            llm_base_url: None,
            llm_model: None,
            llm_api_key: None,
            model_download_endpoint: None,
            cli_evidence_access: Some(true),
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"update_settings","cli_evidence_access":true}"#
        );
    }

    #[test]
    fn chat_wire_shapes_are_stable() {
        assert_eq!(
            serde_json::to_string(&Request::ChatSend {
                conversation_id: None,
                message: "我今天下午在干嘛".into(),
            })
            .unwrap(),
            r#"{"type":"chat_send","message":"我今天下午在干嘛"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::ChatSend {
                conversation_id: Some("c1".into()),
                message: "那第三件呢".into(),
            })
            .unwrap(),
            r#"{"type":"chat_send","conversation_id":"c1","message":"那第三件呢"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::ChatList).unwrap(),
            r#"{"type":"chat_list"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::ChatHistory {
                conversation_id: "c1".into(),
            })
            .unwrap(),
            r#"{"type":"chat_history","conversation_id":"c1"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::ChatDelete {
                conversation_id: "c1".into(),
            })
            .unwrap(),
            r#"{"type":"chat_delete","conversation_id":"c1"}"#
        );
        let decoded: Request =
            serde_json::from_str(r#"{"type":"chat_send","message":"hello"}"#).unwrap();
        assert!(matches!(
            decoded,
            Request::ChatSend {
                ref message,
                conversation_id: None
            } if message == "hello"
        ));
    }

    #[test]
    fn ask_wire_shape_is_stable() {
        assert_eq!(
            serde_json::to_string(&Request::Ask {
                question: "我今天做了什么".into(),
                from_ms: None,
                to_ms: None,
            })
            .unwrap(),
            r#"{"type":"ask","question":"我今天做了什么"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::Ask {
                question: "what did I do".into(),
                from_ms: Some(10),
                to_ms: Some(20),
            })
            .unwrap(),
            r#"{"type":"ask","question":"what did I do","from_ms":10,"to_ms":20}"#
        );
        let decoded: Request =
            serde_json::from_str(r#"{"type":"ask","question":"hello"}"#).unwrap();
        assert!(matches!(
            decoded,
            Request::Ask {
                ref question,
                from_ms: None,
                to_ms: None
            } if question == "hello"
        ));
    }

    #[test]
    fn activity_spans_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::ActivitySpans {
            from_ms: 10,
            to_ms: 20,
            limit: 5,
        })
        .unwrap();
        assert_eq!(
            json,
            r#"{"type":"activity_spans","from_ms":10,"to_ms":20,"limit":5}"#
        );
        let decoded: Request =
            serde_json::from_str(r#"{"type":"activity_spans","from_ms":1,"to_ms":2}"#).unwrap();
        assert!(matches!(
            decoded,
            Request::ActivitySpans {
                from_ms: 1,
                to_ms: 2,
                limit: 100
            }
        ));
    }

    #[test]
    fn chat_stream_wire_shape_is_stable() {
        assert_eq!(
            serde_json::to_string(&Request::ChatStream {
                conversation_id: None,
                message: "我今天下午在干嘛".into(),
            })
            .unwrap(),
            r#"{"type":"chat_stream","message":"我今天下午在干嘛"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::ChatStream {
                conversation_id: Some("c1".into()),
                message: "那第三件呢".into(),
            })
            .unwrap(),
            r#"{"type":"chat_stream","conversation_id":"c1","message":"那第三件呢"}"#
        );
        let decoded: Request =
            serde_json::from_str(r#"{"type":"chat_stream","message":"hello"}"#).unwrap();
        assert!(matches!(
            decoded,
            Request::ChatStream {
                ref message,
                conversation_id: None
            } if message == "hello"
        ));
    }

    #[test]
    fn chat_stream_event_wire_shape_is_stable() {
        let tool = ChatStreamEvent::ToolCall {
            name: "get_slot_card".into(),
            args: serde_json::json!({"at_ms": 1}),
        };
        assert_eq!(
            serde_json::to_string(&tool).unwrap(),
            r#"{"kind":"tool_call","name":"get_slot_card","args":{"at_ms":1}}"#
        );
        let result = ChatStreamEvent::ToolResult {
            name: "get_slot_card".into(),
            chars: 2480,
            truncated: false,
            dropped: 0,
        };
        assert_eq!(
            serde_json::to_string(&result).unwrap(),
            r#"{"kind":"tool_result","name":"get_slot_card","chars":2480,"truncated":false,"dropped":0}"#
        );
        let usage = ChatStreamEvent::Usage {
            prompt_tokens: 5_120,
            window_tokens: 16_384,
            round: 2,
        };
        assert_eq!(
            serde_json::to_string(&usage).unwrap(),
            r#"{"kind":"usage","prompt_tokens":5120,"window_tokens":16384,"round":2}"#
        );
        let reasoning = ChatStreamEvent::Reasoning {
            text: "checking the timeline".into(),
            round: 2,
        };
        assert_eq!(
            serde_json::to_string(&reasoning).unwrap(),
            r#"{"kind":"reasoning","text":"checking the timeline","round":2}"#
        );
        let progress = ChatStreamEvent::Progress {
            phase: "thinking".into(),
            reasoning_deltas: 131,
            elapsed_ms: 2_400,
            round: 1,
        };
        assert_eq!(
            serde_json::to_string(&progress).unwrap(),
            r#"{"kind":"progress","phase":"thinking","reasoning_deltas":131,"elapsed_ms":2400,"round":1}"#
        );
        let compaction = ChatStreamEvent::Compaction {
            strategy: "prune_tool_results".into(),
            from_round: 0,
            to_round: 2,
            tokens_before: 14_000,
            tokens_after: 6_200,
        };
        assert_eq!(
            serde_json::to_string(&compaction).unwrap(),
            r#"{"kind":"compaction","strategy":"prune_tool_results","from_round":0,"to_round":2,"tokens_before":14000,"tokens_after":6200}"#
        );
        let token = ChatStreamEvent::Token {
            text: "你今天下午".into(),
        };
        assert_eq!(
            serde_json::to_string(&token).unwrap(),
            r#"{"kind":"token","text":"你今天下午"}"#
        );
        let done = ChatStreamEvent::Done {
            message_id: "m1".into(),
            conversation_id: "c1".into(),
        };
        assert_eq!(
            serde_json::to_string(&done).unwrap(),
            r#"{"kind":"done","message_id":"m1","conversation_id":"c1"}"#
        );
        let error = ChatStreamEvent::Error {
            message: "boom".into(),
        };
        assert_eq!(
            serde_json::to_string(&error).unwrap(),
            r#"{"kind":"error","message":"boom"}"#
        );
        let line = token.to_ndjson_line().unwrap();
        assert!(line.ends_with(b"\n"));
        let parsed: ChatStreamEvent = serde_json::from_slice(&line[..line.len() - 1]).unwrap();
        assert_eq!(parsed, token);
    }

    /// A line written by a daemon that predates `truncated`/`dropped` must
    /// still decode, or upgrading the daemon and the app becomes a lockstep.
    #[test]
    fn tool_result_decodes_without_the_newer_fields() {
        let parsed: ChatStreamEvent =
            serde_json::from_str(r#"{"kind":"tool_result","name":"get_ocr","chars":12}"#).unwrap();
        assert_eq!(
            parsed,
            ChatStreamEvent::ToolResult {
                name: "get_ocr".into(),
                chars: 12,
                truncated: false,
                dropped: 0,
            }
        );
    }

    #[test]
    fn ask_answer_defaults_missing_model_flag() {
        let parsed: AskAnswer = serde_json::from_str(r#"{"answer":"ok","citations":[]}"#).unwrap();
        assert_eq!(parsed.answer, "ok");
        assert!(!parsed.model_missing);
        assert!(parsed.citations.is_empty());
    }

    #[test]
    fn local_calendar_day_contains_now() {
        let now = 1_786_694_400_000; // 2026-08-14 12:00:00 UTC
        let (start, end) = local_calendar_day_bounds_ms(now);
        assert!(start <= now, "start={start} now={now}");
        assert!(now <= end, "now={now} end={end}");
        let span = end.saturating_sub(start);
        assert!(
            (23 * 60 * 60 * 1000..26 * 60 * 60 * 1000).contains(&span),
            "day span should be ~24h, got {span}ms"
        );
        assert_eq!(local_calendar_day_bounds_ms(now), (start, end));
    }

    #[test]
    fn moment_new_activity_fields_default_when_omitted() {
        let moment: Moment = serde_json::from_str(
            r#"{"id":"m1","session_id":"s1","captured_at_ms":1,"is_favorite":false}"#,
        )
        .unwrap();
        assert!(moment.window_title.is_none());
        assert!(moment.url.is_none());
        assert!(moment.document.is_none());
        let encoded = serde_json::to_value(&moment).unwrap();
        assert!(encoded.get("window_title").is_none());
        assert!(encoded.get("url").is_none());
        assert!(encoded.get("document").is_none());
    }

    #[test]
    fn activity_span_round_trip_preserves_duration() {
        let span = ActivitySpan {
            start_ms: 0,
            end_ms: 1_560_000,
            duration_ms: 1_560_000,
            application_name: Some("Safari".into()),
            bundle_identifier: Some("com.apple.Safari".into()),
            window_title: Some("Example Domain".into()),
            url: Some("https://example.com/".into()),
            document: None,
            moment_ids: vec!["m1".into(), "m2".into()],
        };
        let json = serde_json::to_string(&span).unwrap();
        let decoded: ActivitySpan = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, span);
        assert!(!json.contains("document"));
    }

    #[test]
    fn clear_history_wire_shape_is_stable() {
        assert_eq!(
            serde_json::to_string(&Request::ClearHistory {
                scope: HistoryScope::LastHour
            })
            .unwrap(),
            r#"{"type":"clear_history","scope":"last_hour"}"#
        );
    }

    #[test]
    fn download_models_wire_shape_is_stable() {
        assert_eq!(
            serde_json::to_string(&Request::DownloadModels {
                pack_id: None,
                pack_ids: Vec::new(),
            })
            .unwrap(),
            r#"{"type":"download_models"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::DownloadModels {
                pack_id: Some("asr".into()),
                pack_ids: Vec::new(),
            })
            .unwrap(),
            r#"{"type":"download_models","pack_id":"asr"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::DownloadModels {
                pack_id: None,
                pack_ids: vec!["asr".into(), "embedding".into()],
            })
            .unwrap(),
            r#"{"type":"download_models","pack_ids":["asr","embedding"]}"#
        );
    }

    #[test]
    fn mlx_provider_and_model_removal_wire_shapes_are_stable() {
        assert_eq!(LlmProvider::parse("mlx_local"), Some(LlmProvider::MlxLocal));
        assert_eq!(LlmProvider::MlxLocal.as_label(), "mlx_local");
        assert_eq!(
            serde_json::to_string(&Request::RemoveModel {
                pack_id: "llm_qwen35_4b_mlx4".into()
            })
            .unwrap(),
            r#"{"type":"remove_model","pack_id":"llm_qwen35_4b_mlx4"}"#
        );
        let state: ModelPackState = serde_json::from_str(r#""in_use""#).unwrap();
        assert_eq!(state, ModelPackState::InUse);
    }

    #[test]
    fn model_download_control_wire_shapes_are_stable() {
        assert_eq!(
            serde_json::to_string(&Request::PauseModelDownloads).unwrap(),
            r#"{"type":"pause_model_downloads"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::ResumeModelDownloads).unwrap(),
            r#"{"type":"resume_model_downloads"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::CancelModelDownloads).unwrap(),
            r#"{"type":"cancel_model_downloads"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::CancelModelDownload {
                pack_id: "embedding".into()
            })
            .unwrap(),
            r#"{"type":"cancel_model_download","pack_id":"embedding"}"#
        );
        assert_eq!(
            serde_json::to_string(&ModelPackState::Paused).unwrap(),
            r#""paused""#
        );
    }

    /// The singular and plural cancels differ by one character on the wire, so
    /// a typo in either client would silently tear down the whole queue.
    #[test]
    fn single_and_whole_queue_cancels_are_distinct_requests() {
        let single: Request =
            serde_json::from_str(r#"{"type":"cancel_model_download","pack_id":"asr"}"#).unwrap();
        assert!(matches!(single, Request::CancelModelDownload { pack_id } if pack_id == "asr"));
        let all: Request = serde_json::from_str(r#"{"type":"cancel_model_downloads"}"#).unwrap();
        assert!(matches!(all, Request::CancelModelDownloads));
    }

    #[test]
    fn model_library_omits_idle_download() {
        let library = ModelLibrary {
            directory: "/tmp/models".into(),
            packs: Vec::new(),
            download: None,
        };
        assert_eq!(
            serde_json::to_string(&library).unwrap(),
            r#"{"directory":"/tmp/models","packs":[]}"#
        );
    }

    #[test]
    fn artifact_header_omits_bytes() {
        let payload = ArtifactPayload {
            id: "a1".to_owned(),
            content_type: "image/jpeg".to_owned(),
            bytes: b"\x00\xffJPEG".to_vec(),
        };
        let header = payload.header_line().unwrap();
        let text = std::str::from_utf8(&header).unwrap();
        assert!(text.ends_with('\n'));
        assert!(!text.contains("bytes"));
        assert!(!text.contains("base64"));
        let parsed: Response = serde_json::from_slice(&header[..header.len() - 1]).unwrap();
        assert!(parsed.ok);
        let meta: ArtifactMeta = serde_json::from_value(parsed.data.unwrap()).unwrap();
        assert_eq!(meta.id, "a1");
        assert_eq!(meta.content_type, "image/jpeg");
        assert_eq!(meta.byte_length, 6);
    }
}
