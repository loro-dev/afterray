//! What a same-user CLI connection may call, and how to strip evidence from
//! the query surface when the 30-minute window is closed.
//!
//! The AfterRay.app process is a privileged client (peer executable path).
//! Everything else — `afterray` on PATH, scripts, coding agents — is a CLI
//! client. Mutations, ask/chat, and settings writes stay app-only. Evidence
//! (frames, OCR, AX, T1 cards) needs an open window.

use super::{Moment, Request, SearchHit};
use serde_json::Value;

/// How long Settings → "Allow for 30 minutes" stays open.
pub const CLI_EVIDENCE_WINDOW_MS: i64 = 30 * 60 * 1000;

/// Optional override so tests (and a wedged peer-path check) can mark a
/// connection as the app. Never documented for agents.
pub const APP_TOKEN_ENV: &str = "AFTERRAY_APP_TOKEN";

pub const EVIDENCE_ACCESS_DISABLED: &str = "evidence_access_disabled: CLI cannot read original evidence (screenshots, OCR, accessibility trees, audio, or T1 slot cards). Open AfterRay → Settings → Advanced → CLI for agents and choose “Allow for 30 minutes”.";

pub const CLI_FORBIDDEN: &str = "cli_forbidden: this action is only available in the AfterRay app.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliRequestClass {
    /// Locator / summary reads. Always allowed; payload may be redacted.
    Query,
    /// Original captures and T1 cards. Allowed only while the window is open.
    Evidence,
    /// Record, settings, chat, deletes, model control. App only.
    Privileged,
}

#[must_use]
pub fn cli_request_class(request: &Request) -> CliRequestClass {
    match request {
        Request::Ping
        | Request::Status
        | Request::SessionsList
        | Request::TimelineList
        | Request::TimelineSince { .. }
        | Request::MomentsList { .. }
        | Request::RecallWindow { .. }
        | Request::Search { .. }
        | Request::MomentGet { .. }
        | Request::MomentAt { .. }
        | Request::DaySummary { .. }
        | Request::SummaryHistory { .. }
        | Request::SlotSummaryExport { .. }
        | Request::ActivitySpans { .. }
        | Request::MemoriesList { .. }
        | Request::Settings
        | Request::ModelsStatus
        | Request::JobsList
        | Request::PackStatus => CliRequestClass::Query,
        Request::EvidenceOcr { .. }
        | Request::EvidenceAx { .. }
        | Request::ReadArtifact { .. }
        | Request::ReadGopSegment { .. }
        | Request::ReadGopFrame { .. }
        | Request::ReadThumbnail { .. }
        | Request::SlotCard { .. }
        | Request::SlotPrompt { .. }
        | Request::GopShow { .. } => CliRequestClass::Evidence,
        _ => CliRequestClass::Privileged,
    }
}

#[must_use]
pub fn evidence_window_open(until_ms: Option<i64>, now_ms: i64) -> bool {
    until_ms.is_some_and(|until| until > now_ms)
}

/// `Ok` if this CLI client may run `request`. Privileged callers skip this.
///
/// # Errors
///
/// Returns [`EVIDENCE_ACCESS_DISABLED`] when `request` is evidence and the
/// window is closed, or [`CLI_FORBIDDEN`] when it is app-only.
pub fn authorize_cli_request(
    request: &Request,
    evidence_until_ms: Option<i64>,
    now_ms: i64,
) -> Result<(), &'static str> {
    match cli_request_class(request) {
        CliRequestClass::Query => Ok(()),
        CliRequestClass::Evidence if evidence_window_open(evidence_until_ms, now_ms) => Ok(()),
        CliRequestClass::Evidence => Err(EVIDENCE_ACCESS_DISABLED),
        CliRequestClass::Privileged => Err(CLI_FORBIDDEN),
    }
}

pub fn redact_moment_for_cli(moment: &mut Moment) {
    moment.ocr_text = None;
    moment.transcript_text = None;
}

pub fn redact_search_hit_for_cli(hit: &mut SearchHit) {
    hit.text.clear();
}

/// Strips original text out of a successful query payload. Search never
/// returns OCR, even while the evidence window is open — that is a
/// separate command.
pub fn redact_cli_response_data(request: &Request, data: &mut Value) {
    match request {
        Request::Search { .. } => redact_search_payload(data),
        Request::MomentGet { .. } | Request::MomentAt { .. } => strip_moment_object(data),
        Request::TimelineList
        | Request::TimelineSince { .. }
        | Request::MomentsList { .. }
        | Request::RecallWindow { .. } => {
            if let Some(items) = data.as_array_mut() {
                for item in items {
                    strip_moment_object(item);
                }
            }
        }
        _ => {}
    }
}

fn redact_search_payload(data: &mut Value) {
    let items = if let Some(items) = data.as_array_mut() {
        items
    } else if let Some(items) = data.get_mut("hits").and_then(Value::as_array_mut) {
        items
    } else {
        return;
    };
    for item in items {
        if let Some(object) = item.as_object_mut() {
            object.insert("text".to_owned(), Value::String(String::new()));
        }
    }
}

fn strip_moment_object(value: &mut Value) {
    if let Some(object) = value.as_object_mut() {
        object.remove("ocr_text");
        object.remove("transcript_text");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Request;

    #[test]
    fn search_and_summaries_are_query() {
        assert_eq!(
            cli_request_class(&Request::Search {
                query: "design review".into(),
                limit: 10,
                from_ms: None,
                to_ms: None,
            }),
            CliRequestClass::Query
        );
        assert_eq!(
            cli_request_class(&Request::DaySummary { day_ms: 1 }),
            CliRequestClass::Query
        );
        assert_eq!(
            cli_request_class(&Request::SlotSummaryExport { at_ms: 1 }),
            CliRequestClass::Query
        );
    }

    #[test]
    fn t1_and_raw_assets_are_evidence() {
        assert_eq!(
            cli_request_class(&Request::SlotCard { at_ms: 1 }),
            CliRequestClass::Evidence
        );
        assert_eq!(
            cli_request_class(&Request::SlotPrompt { at_ms: 1 }),
            CliRequestClass::Evidence
        );
        assert_eq!(
            cli_request_class(&Request::EvidenceOcr {
                moment_id: "m".into(),
            }),
            CliRequestClass::Evidence
        );
        assert_eq!(
            cli_request_class(&Request::ReadThumbnail {
                moment_id: "m".into(),
                max_edge: None,
            }),
            CliRequestClass::Evidence
        );
    }

    #[test]
    fn writes_and_chat_are_privileged() {
        assert_eq!(
            cli_request_class(&Request::ClearHistory {
                scope: crate::HistoryScope::Today,
            }),
            CliRequestClass::Privileged
        );
        assert_eq!(
            cli_request_class(&Request::Ask {
                question: "what".into(),
                from_ms: None,
                to_ms: None,
            }),
            CliRequestClass::Privileged
        );
        assert_eq!(
            cli_request_class(&Request::ChatSend {
                conversation_id: None,
                message: "hi".into(),
            }),
            CliRequestClass::Privileged
        );
        assert_eq!(cli_request_class(&Request::RecordStart), CliRequestClass::Privileged);
        assert_eq!(
            cli_request_class(&Request::UpdateSettings {
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
            }),
            CliRequestClass::Privileged
        );
    }

    #[test]
    fn evidence_window_is_strictly_in_the_future() {
        assert!(!evidence_window_open(None, 100));
        assert!(!evidence_window_open(Some(100), 100));
        assert!(evidence_window_open(Some(101), 100));
    }

    #[test]
    fn authorize_closes_evidence_and_writes() {
        let ocr = Request::EvidenceOcr {
            moment_id: "m".into(),
        };
        assert!(authorize_cli_request(&ocr, Some(200), 100).is_ok());
        assert_eq!(
            authorize_cli_request(&ocr, None, 100),
            Err(EVIDENCE_ACCESS_DISABLED)
        );
        assert_eq!(
            authorize_cli_request(&Request::RecordStart, None, 100),
            Err(CLI_FORBIDDEN)
        );
    }

    #[test]
    fn search_redaction_clears_hit_text() {
        let mut data = serde_json::json!([{
            "moment_id": "m1",
            "text": "password spreadsheet"
        }]);
        redact_cli_response_data(
            &Request::Search {
                query: "x".into(),
                limit: 1,
                from_ms: None,
                to_ms: None,
            },
            &mut data,
        );
        assert_eq!(data[0]["text"], "");
        assert_eq!(data[0]["moment_id"], "m1");
    }
}
