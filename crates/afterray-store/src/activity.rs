//! Activity context parsed from Accessibility snapshots, and span folding.

use afterray_protocol::ActivitySpan;
use serde::Deserialize;

pub const MAX_SPAN_MOMENT_IDS: usize = 32;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ActivityContext {
    pub application_name: Option<String>,
    pub bundle_identifier: Option<String>,
    pub window_title: Option<String>,
    pub url: Option<String>,
    pub document: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityMomentRow {
    pub id: String,
    pub captured_at_ms: i64,
    pub application_name: Option<String>,
    pub bundle_identifier: Option<String>,
    pub window_title: Option<String>,
    pub url: Option<String>,
    pub document: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct SnapshotHeader {
    #[serde(default)]
    private_browsing: bool,
    #[serde(default)]
    application_name: Option<String>,
    #[serde(default)]
    bundle_identifier: Option<String>,
    #[serde(default)]
    window_title: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    document: Option<String>,
    #[serde(default)]
    root: Option<SnapshotNode>,
}

#[derive(Debug, Default, Deserialize)]
struct SnapshotNode {
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    document: Option<String>,
    #[serde(default)]
    children: Vec<SnapshotNode>,
}

#[must_use]
pub fn parse_accessibility_context(snapshot: &[u8]) -> ActivityContext {
    let Ok(header) = serde_json::from_slice::<SnapshotHeader>(snapshot) else {
        return ActivityContext::default();
    };
    let private_browsing = header.private_browsing;
    let mut context = ActivityContext {
        application_name: nonempty(header.application_name),
        bundle_identifier: nonempty(header.bundle_identifier),
        window_title: nonempty(header.window_title),
        url: classify_url(header.url),
        document: classify_document(header.document),
    };
    if let Some(root) = header.root {
        let mut found_web_url = context.url.is_some();
        fill_context_from_tree(&mut context, &root, &mut found_web_url);
    }
    if private_browsing {
        context.url = None;
    }
    context
}

pub fn merge_activity_context(
    parsed: ActivityContext,
    application_name: Option<&str>,
    bundle_identifier: Option<&str>,
) -> ActivityContext {
    ActivityContext {
        application_name: nonempty(application_name.map(ToOwned::to_owned))
            .or(parsed.application_name),
        bundle_identifier: nonempty(bundle_identifier.map(ToOwned::to_owned))
            .or(parsed.bundle_identifier),
        window_title: parsed.window_title,
        url: parsed.url,
        document: parsed.document,
    }
}

#[must_use]
pub fn fold_activity_spans(moments: &[ActivityMomentRow], limit: usize) -> Vec<ActivitySpan> {
    if limit == 0 || moments.is_empty() {
        return Vec::new();
    }
    let mut spans = Vec::new();
    let mut open: Option<OpenSpan> = None;
    for moment in moments {
        let key = activity_key(moment);
        match open {
            Some(ref current) if current.key == key => {
                if let Some(span) = open.as_mut() {
                    span.extend(moment);
                }
            }
            Some(current) => {
                spans.push(current.close(Some(moment.captured_at_ms)));
                if spans.len() == limit {
                    return spans;
                }
                open = Some(OpenSpan::new(moment, key));
            }
            None => open = Some(OpenSpan::new(moment, key)),
        }
    }
    if let Some(current) = open
        && spans.len() < limit
    {
        spans.push(current.close(None));
    }
    spans
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActivityKey {
    app: Option<String>,
    context: Option<String>,
}

fn activity_key(moment: &ActivityMomentRow) -> ActivityKey {
    ActivityKey {
        app: nonempty(moment.bundle_identifier.clone())
            .or_else(|| nonempty(moment.application_name.clone())),
        context: nonempty(moment.url.clone())
            .or_else(|| nonempty(moment.document.clone()))
            .or_else(|| nonempty(moment.window_title.clone())),
    }
}

struct OpenSpan {
    key: ActivityKey,
    start_ms: i64,
    last_ms: i64,
    application_name: Option<String>,
    bundle_identifier: Option<String>,
    window_title: Option<String>,
    url: Option<String>,
    document: Option<String>,
    moment_ids: Vec<String>,
}

impl OpenSpan {
    fn new(moment: &ActivityMomentRow, key: ActivityKey) -> Self {
        Self {
            key,
            start_ms: moment.captured_at_ms,
            last_ms: moment.captured_at_ms,
            application_name: moment.application_name.clone(),
            bundle_identifier: moment.bundle_identifier.clone(),
            window_title: moment.window_title.clone(),
            url: moment.url.clone(),
            document: moment.document.clone(),
            moment_ids: vec![moment.id.clone()],
        }
    }

    fn extend(&mut self, moment: &ActivityMomentRow) {
        self.last_ms = moment.captured_at_ms;
        if let Some(name) = nonempty(moment.application_name.clone()) {
            self.application_name = Some(name);
        }
        if let Some(bundle) = nonempty(moment.bundle_identifier.clone()) {
            self.bundle_identifier = Some(bundle);
        }
        if let Some(title) = nonempty(moment.window_title.clone()) {
            self.window_title = Some(title);
        }
        if let Some(url) = nonempty(moment.url.clone()) {
            self.url = Some(url);
        }
        if let Some(document) = nonempty(moment.document.clone()) {
            self.document = Some(document);
        }
        push_moment_id(&mut self.moment_ids, moment.id.clone());
    }

    fn close(self, next_ms: Option<i64>) -> ActivitySpan {
        let end_ms = next_ms.unwrap_or(self.last_ms);
        ActivitySpan {
            start_ms: self.start_ms,
            end_ms,
            duration_ms: end_ms.saturating_sub(self.start_ms),
            application_name: self.application_name,
            bundle_identifier: self.bundle_identifier,
            window_title: self.window_title,
            url: self.url,
            document: self.document,
            moment_ids: self.moment_ids,
        }
    }
}

fn push_moment_id(ids: &mut Vec<String>, id: String) {
    if ids.len() < MAX_SPAN_MOMENT_IDS {
        ids.push(id);
        return;
    }
    if let Some(last) = ids.last_mut() {
        *last = id;
    }
}

fn fill_context_from_tree(
    context: &mut ActivityContext,
    node: &SnapshotNode,
    found_web_url: &mut bool,
) {
    let role = node.role.as_deref();
    if let Some(url) = classify_url(node.url.clone()) {
        if is_document_like(role) {
            if !*found_web_url {
                context.url = Some(url);
                *found_web_url = true;
            }
        } else if context.url.is_none() {
            context.url = Some(url);
        }
    }
    if context.document.is_none() {
        let from_node = node.document.clone();
        let from_file_url = node.url.clone().filter(|value| looks_like_file(value));
        if let Some(document) = classify_document(from_node.or(from_file_url)) {
            context.document = Some(document);
        }
    }
    if context.window_title.is_none()
        && is_window_like(role)
        && let Some(title) = nonempty(node.title.clone())
    {
        context.window_title = Some(title);
    }
    for child in &node.children {
        fill_context_from_tree(context, child, found_web_url);
    }
}

fn is_document_like(role: Option<&str>) -> bool {
    matches!(
        role,
        Some("AXWebArea" | "AXBrowser" | "AXWebDocument" | "AXDocument")
    )
}

fn is_window_like(role: Option<&str>) -> bool {
    matches!(role, Some("AXWindow" | "AXStandardWindow"))
}

fn classify_url(value: Option<String>) -> Option<String> {
    let value = nonempty(value)?;
    if looks_like_file(&value) {
        return None;
    }
    Some(value)
}

fn classify_document(value: Option<String>) -> Option<String> {
    let value = nonempty(value)?;
    if value.starts_with("http://") || value.starts_with("https://") {
        return None;
    }
    if value.starts_with("file://") {
        return Some(value);
    }
    if value.starts_with('/') {
        return Some(format!("file://{value}"));
    }
    Some(value)
}

fn looks_like_file(value: &str) -> bool {
    value.starts_with("file://") || (value.starts_with('/') && !value.starts_with("//"))
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.and_then(|text| {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(
        id: &str,
        at: i64,
        bundle: &str,
        app: &str,
        title: Option<&str>,
        url: Option<&str>,
        document: Option<&str>,
    ) -> ActivityMomentRow {
        ActivityMomentRow {
            id: id.to_owned(),
            captured_at_ms: at,
            application_name: Some(app.to_owned()),
            bundle_identifier: Some(bundle.to_owned()),
            window_title: title.map(ToOwned::to_owned),
            url: url.map(ToOwned::to_owned),
            document: document.map(ToOwned::to_owned),
        }
    }

    #[test]
    fn safari_header_fixture_exposes_url() {
        let snapshot = br#"{
            "application_name": "Safari",
            "bundle_identifier": "com.apple.Safari",
            "window_title": "Example Domain",
            "url": "https://example.com/",
            "root": {"role": "AXApplication", "children": []}
        }"#;
        let context = parse_accessibility_context(snapshot);
        assert_eq!(context.application_name.as_deref(), Some("Safari"));
        assert_eq!(context.window_title.as_deref(), Some("Example Domain"));
        assert_eq!(context.url.as_deref(), Some("https://example.com/"));
        assert!(context.document.is_none());
    }

    #[test]
    fn chrome_web_area_fixture_fills_url_from_tree() {
        let snapshot = br#"{
            "application_name": "Google Chrome",
            "bundle_identifier": "com.google.Chrome",
            "root": {
                "role": "AXApplication",
                "children": [{
                    "role": "AXWindow",
                    "title": "Example Domain",
                    "children": [{
                        "role": "AXWebArea",
                        "title": "Example Domain",
                        "url": "https://example.com/"
                    }]
                }]
            }
        }"#;
        let context = parse_accessibility_context(snapshot);
        assert_eq!(context.url.as_deref(), Some("https://example.com/"));
        assert_eq!(context.window_title.as_deref(), Some("Example Domain"));
    }

    #[test]
    fn private_browsing_fixture_never_exposes_header_or_tree_url() {
        let snapshot = br#"{
            "application_name": "Google Chrome",
            "bundle_identifier": "com.google.Chrome",
            "private_browsing": true,
            "window_title": "Private account",
            "url": "https://private.example/account",
            "root": {
                "role": "AXWindow",
                "children": [{
                    "role": "AXWebArea",
                    "url": "https://private.example/account"
                }]
            }
        }"#;

        let context = parse_accessibility_context(snapshot);

        assert_eq!(context.window_title.as_deref(), Some("Private account"));
        assert!(context.url.is_none());
    }

    #[test]
    fn document_path_becomes_file_url() {
        let snapshot = br#"{
            "document": "/Users/ada/Notes.txt",
            "root": {"role": "AXWindow", "title": "Notes"}
        }"#;
        let context = parse_accessibility_context(snapshot);
        assert_eq!(
            context.document.as_deref(),
            Some("file:///Users/ada/Notes.txt")
        );
        assert_eq!(context.window_title.as_deref(), Some("Notes"));
        assert!(context.url.is_none());
    }

    #[test]
    fn spans_merge_same_bundle_and_url_and_split_on_change() {
        let moments = [
            row(
                "m1",
                0,
                "com.apple.Safari",
                "Safari",
                Some("Example Domain"),
                Some("https://example.com/"),
                None,
            ),
            row(
                "m2",
                10_000,
                "com.apple.Safari",
                "Safari",
                Some("Example Domain"),
                Some("https://example.com/"),
                None,
            ),
            row(
                "m3",
                1_560_000,
                "com.apple.Safari",
                "Safari",
                Some("Example Domain"),
                Some("https://example.com/"),
                None,
            ),
            row(
                "m4",
                1_570_000,
                "com.apple.dt.Xcode",
                "Xcode",
                Some("Package.swift"),
                None,
                Some("file:///tmp/Package.swift"),
            ),
            row(
                "m5",
                1_580_000,
                "com.apple.Safari",
                "Safari",
                Some("Other"),
                Some("https://other.example/"),
                None,
            ),
        ];
        let spans = fold_activity_spans(&moments, 10);
        assert_eq!(spans.len(), 3);
        assert_eq!(spans[0].url.as_deref(), Some("https://example.com/"));
        assert_eq!(spans[0].start_ms, 0);
        assert_eq!(spans[0].end_ms, 1_570_000);
        assert_eq!(spans[0].duration_ms, 1_570_000);
        assert_eq!(spans[0].moment_ids, ["m1", "m2", "m3"]);
        assert_eq!(
            spans[1].document.as_deref(),
            Some("file:///tmp/Package.swift")
        );
        assert_eq!(spans[1].duration_ms, 10_000);
        assert_eq!(spans[2].url.as_deref(), Some("https://other.example/"));
        assert_eq!(spans[2].duration_ms, 0);
    }

    #[test]
    fn span_moment_ids_are_bounded_and_keep_the_latest() {
        let moments: Vec<_> = (0..40)
            .map(|index| {
                row(
                    &format!("m{index}"),
                    i64::from(index) * 1_000,
                    "com.apple.Safari",
                    "Safari",
                    None,
                    Some("https://example.com/"),
                    None,
                )
            })
            .collect();
        let spans = fold_activity_spans(&moments, 1);
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].moment_ids.len(), MAX_SPAN_MOMENT_IDS);
        assert_eq!(spans[0].moment_ids[0], "m0");
        assert_eq!(spans[0].moment_ids[MAX_SPAN_MOMENT_IDS - 1], "m39");
    }
}
