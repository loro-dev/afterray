use afterray_models::{LlmRuntimeConfig, ModelQueue};
use afterray_protocol::{
    ActivitySpan, AskAnswer, AskCitation, Memory, ModelLibrary, Response, SearchHit,
    local_calendar_day_bounds_ms,
};
use afterray_store::Vault;
use chrono::Local;
use std::fmt::Write as _;

use crate::agent;
use afterray_harness::ContextBudget;
use crate::search_hits;
use crate::tools::ToolHost;

const CONTEXT_CHAR_CAP: usize = 10_000;
const SEARCH_HIT_LIMIT: usize = 6;
const CITATION_LIMIT: usize = 3;
const EXCERPT_CHAR_CAP: usize = 180;
const ASK_SYSTEM_PROMPT: &str = "You are AfterRay, a local memory assistant for this computer. \
Answer only from tool evidence. If tools do not contain the answer, say you do not know. \
When you mention a specific activity, cite it as a markdown link using afterray://moment/MOMENT_ID, \
for example [2:14 Safari](afterray://moment/MOMENT_ID). Be concise. Never invent missing evidence. \
The seed below already holds memories, activity and search hits for the range; \
reach for a tool when it is not enough, following the catalog's own ordering.";

const QWEN35_TOOL_PROTOCOL_SUFFIX: &str = "\
For tools, output exactly two lines: TOOL <allowlisted tool name> followed by \
ARGS <one JSON object>. Do not put analysis, thinking markers, or prose before \
those lines. For a user-facing response, output FINAL followed by the answer.";

const MODEL_MISSING_MESSAGE: &str = "The language model is not configured. Open Settings to connect Ollama, an OpenAI-compatible endpoint, or download the on-device pack.";

/// What the model layer offers a turn: whether there is a model at all, and
/// the window it actually has.
///
/// The two travel together because they are decided together, one probe before
/// the turn starts. Passing the window separately is how it ends up defaulted
/// at one call site and real at another.
#[derive(Debug, Clone, Copy)]
pub(crate) struct TurnModel {
    pub present: bool,
    pub budget: ContextBudget,
}

impl TurnModel {
    /// A model is available, on whatever window was worked out for it.
    pub fn ready(budget: ContextBudget) -> Self {
        Self {
            present: true,
            budget,
        }
    }

    /// Nothing configured. The budget is unused on this path but must be
    /// something; the default is as good a placeholder as any.
    pub fn missing() -> Self {
        Self {
            present: false,
            budget: ContextBudget::DEFAULT,
        }
    }
}

#[must_use]
pub(crate) fn mlx_pack_present(library: &ModelLibrary, config: &LlmRuntimeConfig) -> bool {
    config.mlx_pack_id().is_some_and(|pack_id| {
        library
            .packs
            .iter()
            .any(|pack| pack.id == pack_id && pack.present)
    })
}

#[must_use]
pub(crate) fn llm_ready(library: &ModelLibrary, config: &LlmRuntimeConfig) -> bool {
    config.is_ready(mlx_pack_present(library, config))
}

pub(crate) fn resolve_ask_range(
    from_ms: Option<i64>,
    to_ms: Option<i64>,
    now_ms: i64,
) -> (i64, i64) {
    let (today_start, today_end) = local_calendar_day_bounds_ms(now_ms);
    let from = from_ms.unwrap_or(today_start);
    let to = to_ms.unwrap_or(today_end);
    if from <= to { (from, to) } else { (to, from) }
}

pub(crate) fn hits_in_range(hits: &[SearchHit], from_ms: i64, to_ms: i64) -> Vec<SearchHit> {
    hits.iter()
        .filter(|hit| hit.captured_at_ms >= from_ms && hit.captured_at_ms <= to_ms)
        .cloned()
        .collect()
}

fn span_moment_id(span: &ActivitySpan) -> Option<&str> {
    span.moment_ids
        .first()
        .map(String::as_str)
        .filter(|id| !id.is_empty())
}

fn span_label(span: &ActivitySpan) -> String {
    span.application_name
        .clone()
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "Unknown app".to_owned())
}

fn span_detail(span: &ActivitySpan) -> Option<&str> {
    span.url
        .as_deref()
        .or(span.document.as_deref())
        .or(span.window_title.as_deref())
        .filter(|value| !value.is_empty())
}

fn format_duration_ms(ms: i64) -> String {
    let total_minutes = (ms.max(1) + 30_000) / 60_000;
    if total_minutes < 1 {
        return "<1m".to_owned();
    }
    if total_minutes < 60 {
        return format!("{total_minutes}m");
    }
    let hours = total_minutes / 60;
    let minutes = total_minutes % 60;
    if minutes == 0 {
        format!("{hours}h")
    } else {
        format!("{hours}h {minutes}m")
    }
}

pub(crate) fn truncate_chars(text: &str, max_chars: usize) -> String {
    if max_chars == 0 {
        return String::new();
    }
    let count = text.chars().count();
    if count <= max_chars {
        return text.to_owned();
    }
    if max_chars == 1 {
        return "…".to_owned();
    }
    let taken: String = text.chars().take(max_chars - 1).collect();
    format!("{taken}…")
}

pub(crate) fn moment_href(moment_id: &str) -> String {
    format!("afterray://moment/{moment_id}")
}

pub(crate) fn build_ask_context(
    question: &str,
    from_ms: i64,
    to_ms: i64,
    memories: &[Memory],
    spans: &[ActivitySpan],
    hits: &[SearchHit],
) -> String {
    let mut body = String::new();
    body.push_str("Question: ");
    body.push_str(question.trim());
    body.push_str("\n\nTime range (local): ");
    body.push_str(&format_local_ms(from_ms));
    body.push_str(" – ");
    body.push_str(&format_local_ms(to_ms));
    body.push('\n');

    if memories.is_empty() {
        if !push_capped(&mut body, "\nMemories: none yet for this range.\n") {
            return body;
        }
    } else if !push_capped(&mut body, "\nMemories:\n") {
        return body;
    } else {
        for memory in memories {
            let mut line = format!(
                "- [{}–{}] {}",
                format_clock_ms(memory.start_ms),
                format_clock_ms(memory.end_ms),
                memory.summary
            );
            if let Some(moment_id) = &memory.moment_id {
                line.push_str(" ");
                line.push_str(&moment_href(moment_id));
            }
            line.push('\n');
            if !push_capped(&mut body, &line) {
                return body;
            }
        }
    }

    if spans.is_empty() {
        if !push_capped(&mut body, "\nActivity: none recorded in this range.\n") {
            return body;
        }
    } else if !push_capped(&mut body, "\nActivity:\n") {
        return body;
    } else {
        for span in spans {
            let mut line = format!(
                "- [{}–{}] {} {}",
                format_clock_ms(span.start_ms),
                format_clock_ms(span.end_ms),
                span_label(span),
                format_duration_ms(span.duration_ms)
            );
            if let Some(detail) = span_detail(span) {
                line.push(' ');
                line.push_str(detail);
            }
            if let Some(moment_id) = span_moment_id(span) {
                line.push(' ');
                line.push_str(&moment_href(moment_id));
            }
            line.push('\n');
            if !push_capped(&mut body, &line) {
                return body;
            }
        }
    }

    if hits.is_empty() {
        let _ = push_capped(&mut body, "\nEvidence: no search hits in this range.\n");
    } else if push_capped(&mut body, "\nEvidence:\n") {
        for hit in hits.iter().take(SEARCH_HIT_LIMIT) {
            let line = format!(
                "- {} at {} ({}): {}\n",
                moment_href(&hit.moment_id),
                format_clock_ms(hit.captured_at_ms),
                hit.source,
                truncate_chars(hit.text.trim(), EXCERPT_CHAR_CAP)
            );
            if !push_capped(&mut body, &line) {
                return body;
            }
        }
    }
    body
}

fn push_capped(buffer: &mut String, addition: &str) -> bool {
    if buffer.chars().count() >= CONTEXT_CHAR_CAP {
        return false;
    }
    let remaining = CONTEXT_CHAR_CAP.saturating_sub(buffer.chars().count());
    if addition.chars().count() <= remaining {
        buffer.push_str(addition);
        true
    } else {
        buffer.push_str(&truncate_chars(addition, remaining));
        false
    }
}

pub(crate) fn citations_from_evidence(
    memories: &[Memory],
    spans: &[ActivitySpan],
    hits: &[SearchHit],
) -> Vec<AskCitation> {
    let mut citations = Vec::new();
    for memory in memories {
        let Some(moment_id) = memory.moment_id.as_deref() else {
            continue;
        };
        citations.push(AskCitation {
            moment_id: moment_id.to_owned(),
            captured_at_ms: memory.start_ms,
            label: memory
                .application_name
                .clone()
                .unwrap_or_else(|| "Memory".to_owned()),
            excerpt: memory.summary.clone(),
        });
        if citations.len() >= CITATION_LIMIT {
            return citations;
        }
    }
    for hit in hits.iter().take(SEARCH_HIT_LIMIT) {
        if hit.moment_id.is_empty() {
            continue;
        }
        let label = spans
            .iter()
            .find(|span| span.moment_ids.iter().any(|id| id == &hit.moment_id))
            .map(span_label)
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| {
                if hit.source.is_empty() {
                    "Moment".to_owned()
                } else {
                    hit.source.clone()
                }
            });
        citations.push(AskCitation {
            moment_id: hit.moment_id.clone(),
            captured_at_ms: hit.captured_at_ms,
            label,
            excerpt: truncate_chars(hit.text.trim(), EXCERPT_CHAR_CAP),
        });
        if citations.len() >= CITATION_LIMIT {
            return citations;
        }
    }
    for span in spans {
        let Some(moment_id) = span_moment_id(span) else {
            continue;
        };
        if citations
            .iter()
            .any(|citation| citation.moment_id == moment_id)
        {
            continue;
        }
        citations.push(AskCitation {
            moment_id: moment_id.to_owned(),
            captured_at_ms: span.start_ms,
            label: span_label(span),
            excerpt: span_detail(span).unwrap_or_default().to_owned(),
        });
        if citations.len() >= CITATION_LIMIT {
            break;
        }
    }
    citations
}

fn format_local_ms(ms: i64) -> String {
    datetime_local(ms).map_or_else(
        || ms.to_string(),
        |dt| dt.format("%Y-%m-%d %H:%M").to_string(),
    )
}

fn format_clock_ms(ms: i64) -> String {
    datetime_local(ms).map_or_else(|| ms.to_string(), |dt| dt.format("%H:%M").to_string())
}

fn datetime_local(ms: i64) -> Option<chrono::DateTime<Local>> {
    chrono::DateTime::from_timestamp_millis(ms).map(|dt| dt.with_timezone(&Local))
}

fn model_missing_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("model asset is missing")
        || lower.contains("missing model")
        || lower.contains("download the llm")
        || lower.contains("set afterray_llm_model")
}

fn missing_model_answer(memories: &[Memory], spans: &[ActivitySpan]) -> AskAnswer {
    let mut answer = MODEL_MISSING_MESSAGE.to_owned();
    if !memories.is_empty() {
        answer.push_str("\n\nRemembered in this range:");
        for memory in memories.iter().take(6) {
            let _ = write!(
                answer,
                "\n• {}–{} {}",
                format_clock_ms(memory.start_ms),
                format_clock_ms(memory.end_ms),
                memory.summary
            );
        }
    } else if !spans.is_empty() {
        answer.push_str("\n\nRecorded in this range:");
        for span in spans.iter().take(8) {
            let _ = write!(
                answer,
                "\n• {}–{} {}",
                format_clock_ms(span.start_ms),
                format_clock_ms(span.end_ms),
                span_label(span)
            );
            if let Some(detail) = span_detail(span) {
                let _ = write!(answer, " · {detail}");
            }
        }
    }
    AskAnswer {
        answer,
        citations: citations_from_evidence(memories, spans, &[]),
        model_missing: true,
    }
}

pub(crate) async fn handle_ask(
    store: &Vault,
    models: &ModelQueue,
    question: &str,
    from_ms: Option<i64>,
    to_ms: Option<i64>,
    now_ms: i64,
    model: TurnModel,
) -> Response {
    let question = question.trim();
    if question.is_empty() {
        return Response::failure("question must not be empty");
    }
    let (from_ms, to_ms) = resolve_ask_range(from_ms, to_ms, now_ms);

    let spans = match store.activity_spans(from_ms, to_ms, 80) {
        Ok(spans) => spans,
        Err(error) => return Response::failure(error.to_string()),
    };
    let memories = match store.memories(from_ms, to_ms, 40) {
        Ok(memories) => memories,
        Err(error) => {
            eprintln!("ask memories unavailable: {error}");
            Vec::new()
        }
    };

    let search =
        match search_hits(
            afterray_store::ReadOnlyVault::new(store),
            models,
            question,
            SEARCH_HIT_LIMIT.saturating_mul(2),
        )
        .await
        {
            Ok(hits) => hits_in_range(&hits, from_ms, to_ms),
            Err(error) => {
                eprintln!("ask search failed; continuing without hits: {error}");
                Vec::new()
            }
        };
    let hits: Vec<SearchHit> = search.into_iter().take(SEARCH_HIT_LIMIT).collect();
    let citations = citations_from_evidence(&memories, &spans, &hits);

    if !model.present {
        return Response::success(missing_model_answer(&memories, &spans));
    }

    if memories.is_empty() && spans.is_empty() && hits.is_empty() {
        return Response::success(AskAnswer {
            answer: "I don't have any recorded moments for this time range yet.".to_owned(),
            citations,
            model_missing: false,
        });
    }

    let seed = build_ask_context(question, from_ms, to_ms, &memories, &spans, &hits);
    // Ask's seed already carries the evidence for the range, and it has no
    // folded history; the question is inside the seed block it built.
    let opening = afterray_harness::Opening {
        task: format!(
            "{seed}\n\nUse tools if the seed evidence is incomplete. Then answer with FINAL."
        ),
        ..afterray_harness::Opening::default()
    };
    let host = ToolHost {
        store: afterray_store::ReadOnlyVault::new(store),
        models,
        now_ms,
        budget: model.budget,
    };
    let system = format!("{ASK_SYSTEM_PROMPT}\n\n{QWEN35_TOOL_PROTOCOL_SUFFIX}");
    match agent::run_readonly_agent(models, &host, &system, opening).await {
        Ok(answer) => Response::success(AskAnswer {
            answer: answer.trim().to_owned(),
            citations,
            model_missing: false,
        }),
        Err(agent::AgentError::MissingModel) => {
            Response::success(missing_model_answer(&memories, &spans))
        }
        Err(error) => {
            if model_missing_error(&error.to_string()) {
                Response::success(missing_model_answer(&memories, &spans))
            } else {
                Response::failure(error.to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use afterray_models::{
        ModelAdapter, ModelCapability, ModelQueue, ProcessAdapter, ProcessAdapterConfig,
        QueueConfig,
    };
    use afterray_protocol::ModelPack;
    use afterray_store::{Vault, VaultConfig};
    use std::sync::Arc;

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

    fn queue(adapters: Vec<Arc<dyn ModelAdapter>>) -> ModelQueue {
        ModelQueue::new(adapters, QueueConfig::default()).unwrap()
    }

    #[test]
    fn llm_ready_accepts_configured_remote_without_local_pack() {
        let missing = ModelLibrary {
            directory: "/tmp".into(),
            packs: vec![ModelPack {
                id: "llm_qwen35_4b_mlx4".into(),
                name: "Qwen3.5 4B · MLX 4-bit".into(),
                capability: "llm_vlm".into(),
                path: "/tmp/Qwen3.5-4B-MLX-4bit".into(),
                present: false,
                state: afterray_protocol::ModelPackState::NotDownloaded,
                bytes: 0,
                required: false,
                note: None,
                expected_bytes: None,
                revision: None,
                error: None,
            }],
            download: None,
        };
        let remote = LlmRuntimeConfig {
            provider: afterray_protocol::LlmProvider::Ollama,
            base_url: String::new(),
            model: "qwen3.6:latest".into(),
            api_key: None,
            context_tokens: None,
        };
        assert!(llm_ready(&missing, &remote));
        assert!(!llm_ready(&missing, &LlmRuntimeConfig::default()));
    }

    #[test]
    fn llm_ready_uses_the_selected_mlx_pack() {
        let library = ModelLibrary {
            directory: "/tmp".into(),
            packs: vec![ModelPack {
                id: "llm_qwen35_4b_mlx4".into(),
                name: "Qwen3.5 4B · MLX 4-bit".into(),
                capability: "llm_vlm".into(),
                path: "/tmp/Qwen3.5-4B-MLX-4bit".into(),
                present: true,
                state: afterray_protocol::ModelPackState::Ready,
                bytes: 3_061_129_077,
                required: false,
                note: None,
                expected_bytes: Some(3_061_129_077),
                revision: Some("32f3e8ecf65426fc3306969496342d504bfa13f3".into()),
                error: None,
            }],
            download: None,
        };
        let config = LlmRuntimeConfig {
            provider: afterray_protocol::LlmProvider::MlxLocal,
            ..LlmRuntimeConfig::default()
        };
        assert!(mlx_pack_present(&library, &config));
        assert!(llm_ready(&library, &config));

        let config = LlmRuntimeConfig {
            model: "llm_qwen35_9b_mlx4".into(),
            ..config
        };
        assert!(!mlx_pack_present(&library, &config));
        assert!(!llm_ready(&library, &config));
    }

    #[test]
    fn omitted_range_uses_local_today() {
        let now = 1_786_694_400_000;
        let (from, to) = resolve_ask_range(None, None, now);
        let (today_from, today_to) = local_calendar_day_bounds_ms(now);
        assert_eq!((from, to), (today_from, today_to));
        let (explicit_from, explicit_to) = resolve_ask_range(Some(10), Some(5), now);
        assert_eq!((explicit_from, explicit_to), (5, 10));
    }

    fn sample_span(index: u32, application_name: &str, url: Option<&str>) -> ActivitySpan {
        let start_ms = i64::from(index) * 60_000;
        ActivitySpan {
            start_ms,
            end_ms: start_ms + 50_000,
            duration_ms: 50_000,
            application_name: Some(application_name.to_owned()),
            bundle_identifier: None,
            window_title: None,
            url: url.map(ToOwned::to_owned),
            document: None,
            moment_ids: vec![format!("m{index}")],
        }
    }

    #[test]
    fn context_stays_under_char_cap() {
        let spans: Vec<ActivitySpan> = (0..80)
            .map(|index| sample_span(index, &format!("App{index}"), Some("https://example.com")))
            .collect();
        let hits: Vec<SearchHit> = (0..12)
            .map(|index| SearchHit {
                moment_id: format!("h{index}"),
                session_id: "s1".into(),
                captured_at_ms: i64::from(index) * 1_000,
                source: "ocr".into(),
                text: "y".repeat(400),
                score: 1.0,
            })
            .collect();
        let context = build_ask_context("what", 0, 10, &[], &spans, &hits);
        assert!(context.chars().count() <= CONTEXT_CHAR_CAP);
        assert!(context.contains("Question: what"));
    }

    #[test]
    fn citations_prefer_search_hits() {
        let spans = [ActivitySpan {
            start_ms: 1,
            end_ms: 2,
            duration_ms: 1,
            application_name: Some("Safari".into()),
            bundle_identifier: None,
            window_title: Some("Inbox".into()),
            url: Some("https://mail.example".into()),
            document: None,
            moment_ids: vec!["m1".into()],
        }];
        let hits = [SearchHit {
            moment_id: "m2".into(),
            session_id: "s1".into(),
            captured_at_ms: 9,
            source: "ocr".into(),
            text: "design review notes".into(),
            score: 2.0,
        }];
        let citations = citations_from_evidence(&[], &spans, &hits);
        assert_eq!(citations.len(), 2);
        assert_eq!(citations[0].moment_id, "m2");
        assert_eq!(citations[0].excerpt, "design review notes");
        assert_eq!(citations[1].moment_id, "m1");
    }

    #[tokio::test]
    async fn missing_llm_pack_returns_ok_with_flag() {
        let (_directory, vault) = test_vault();
        let response = handle_ask(
            &vault,
            &queue(Vec::new()),
            "我今天做了什么",
            Some(0),
            Some(10),
            5,
            TurnModel::missing(),
        )
        .await;
        assert!(response.ok);
        let answer: AskAnswer = serde_json::from_value(response.data.unwrap()).unwrap();
        assert!(answer.model_missing);
        assert!(answer.answer.contains("Settings"));
    }

    #[tokio::test]
    async fn empty_question_fails() {
        let (_directory, vault) = test_vault();
        let response = handle_ask(&vault, &queue(Vec::new()), "   ", None, None, 1, TurnModel::ready(ContextBudget::DEFAULT)).await;
        assert!(!response.ok);
    }

    #[tokio::test]
    async fn empty_range_returns_no_evidence_without_llm() {
        let (_directory, vault) = test_vault();
        let response = handle_ask(
            &vault,
            &queue(Vec::new()),
            "what did I do",
            Some(0),
            Some(10),
            5,
            TurnModel::ready(ContextBudget::DEFAULT),
        )
        .await;
        assert!(response.ok);
        let answer: AskAnswer = serde_json::from_value(response.data.unwrap()).unwrap();
        assert!(!answer.model_missing);
        assert!(answer.answer.contains("don't have any recorded moments"));
    }

    #[tokio::test]
    async fn ask_uses_mock_llm_and_range_hits() {
        let (_directory, vault) = test_vault();
        let session = vault.create_session_sync(1_000).unwrap();
        let first = vault
            .insert_moment(&session.id, 1_000, "image/jpeg", b"one")
            .unwrap();
        vault
            .attach_accessibility_snapshot(
                &session.id,
                1_000,
                "application/vnd.afterray.ax+json",
                br#"{"app":"Safari"}"#,
                Some("Safari"),
                Some("com.apple.Safari"),
            )
            .unwrap();
        vault
            .insert_text_evidence(
                &session.id,
                Some(&first.id),
                None,
                "ocr",
                "reviewed the design doc",
                1_000,
                None,
                "ocr-model",
                None,
            )
            .unwrap();

        let script = r#"
import json, sys
req = json.load(sys.stdin)
assert "AfterRay" in (req.get("input") or {}).get("system", "") or True
print(json.dumps({
  "protocol_version": 1,
  "output": {"type": "llm", "text": "You reviewed a design doc."},
  "retryable": False
}))
"#;
        let mut config =
            ProcessAdapterConfig::new("test-llm", ModelCapability::Llm, "/usr/bin/python3");
        config.args = vec!["-c".to_owned(), script.to_owned()];
        let models = queue(vec![Arc::new(ProcessAdapter::new(config))]);

        let response =
            handle_ask(&vault, &models, "design", Some(0), Some(2_000), 1_500, TurnModel::ready(ContextBudget::DEFAULT)).await;
        assert!(response.ok, "{response:?}");
        let answer: AskAnswer = serde_json::from_value(response.data.unwrap()).unwrap();
        assert!(!answer.model_missing);
        assert_eq!(answer.answer, "You reviewed a design doc.");
        assert!(!answer.citations.is_empty());
        assert_eq!(answer.citations[0].moment_id, first.id);
    }
}
