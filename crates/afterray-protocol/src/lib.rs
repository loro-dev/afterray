use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::Zeroize as _;

pub const PROTOCOL_VERSION: u32 = 6;

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
    Settings,
    UpdateSettings {
        #[serde(skip_serializing_if = "Option::is_none")]
        record_audio: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        excluded_bundle_ids: Option<Vec<String>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_provider: Option<LlmProvider>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_base_url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        llm_api_key: Option<String>,
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
    pub bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_bytes: Option<u64>,
    pub completed_files: u64,
    pub total_files: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelPack {
    pub id: String,
    pub name: String,
    pub capability: String,
    pub path: String,
    pub present: bool,
    pub bytes: u64,
    pub required: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_bytes: Option<u64>,
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
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum LlmProvider {
    #[default]
    Builtin,
    Ollama,
    OpenaiCompatible,
}

impl LlmProvider {
    #[must_use]
    pub const fn as_label(self) -> &'static str {
        match self {
            Self::Builtin => "builtin",
            Self::Ollama => "ollama",
            Self::OpenaiCompatible => "openai_compatible",
        }
    }

    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "builtin" | "built_in" | "local" => Some(Self::Builtin),
            "ollama" => Some(Self::Ollama),
            "openai" | "openai_compatible" | "openai-compatible" => Some(Self::OpenaiCompatible),
            _ => None,
        }
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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub excluded_bundle_ids: Vec<String>,
    #[serde(default)]
    pub llm_provider: LlmProvider,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub llm_base_url: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub llm_model: String,
    #[serde(default)]
    pub llm_api_key_set: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HistoryScope {
    LastHour,
    Today,
    All,
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
    fn timeline_cursor_wire_shape_is_stable() {
        let json = serde_json::to_string(&Request::TimelineSince { since_ms: 42 }).unwrap();
        assert_eq!(json, r#"{"type":"timeline_since","since_ms":42}"#);
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
                excluded_bundle_ids: None,
                llm_provider: None,
                llm_base_url: None,
                llm_model: None,
                llm_api_key: None,
            })
            .unwrap(),
            r#"{"type":"update_settings","record_audio":false}"#
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
        assert_eq!(settings.llm_provider, LlmProvider::Builtin);
        assert!(settings.llm_base_url.is_empty());
        assert!(settings.llm_model.is_empty());
        assert!(!settings.llm_api_key_set);
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
            serde_json::to_string(&Request::DownloadModels { pack_id: None }).unwrap(),
            r#"{"type":"download_models"}"#
        );
        assert_eq!(
            serde_json::to_string(&Request::DownloadModels {
                pack_id: Some("asr".into())
            })
            .unwrap(),
            r#"{"type":"download_models","pack_id":"asr"}"#
        );
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
