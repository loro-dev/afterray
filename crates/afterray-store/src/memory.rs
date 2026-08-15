//! Compact Accessibility digests used to produce local memories.

use serde::Deserialize;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

const VISIBLE_TEXT_LIMIT: usize = 16;
const VISIBLE_TEXT_CHARS: usize = 80;
const FOCUSED_VALUE_CHARS: usize = 280;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AccessibilityDigest {
    pub application_name: Option<String>,
    pub bundle_identifier: Option<String>,
    pub window_title: Option<String>,
    pub url: Option<String>,
    pub document: Option<String>,
    pub focused_role: Option<String>,
    pub focused_title: Option<String>,
    pub focused_value: Option<String>,
    pub selected_text: Option<String>,
    pub headings: Vec<String>,
    pub visible_text: Vec<String>,
}

impl AccessibilityDigest {
    #[must_use]
    pub fn identity_key(&self) -> String {
        format!(
            "{}|{}|{}",
            self.bundle_identifier.as_deref().unwrap_or(""),
            self.url
                .as_deref()
                .or(self.document.as_deref())
                .unwrap_or(""),
            self.window_title.as_deref().unwrap_or("")
        )
    }

    #[must_use]
    pub fn compact_text(&self) -> String {
        let mut lines = Vec::new();
        if let Some(app) = &self.application_name {
            lines.push(format!("app: {app}"));
        }
        if let Some(title) = &self.window_title {
            lines.push(format!("window: {title}"));
        }
        if let Some(url) = &self.url {
            lines.push(format!("url: {url}"));
        }
        if let Some(document) = &self.document {
            lines.push(format!("document: {document}"));
        }
        if self.focused_role.is_some()
            || self.focused_title.is_some()
            || self.focused_value.is_some()
        {
            lines.push(format!(
                "focused: {} {} {}",
                self.focused_role.as_deref().unwrap_or("-"),
                self.focused_title.as_deref().unwrap_or("-"),
                self.focused_value.as_deref().unwrap_or("-")
            ));
        }
        if let Some(selected) = &self.selected_text {
            lines.push(format!("selected: {selected}"));
        }
        if !self.headings.is_empty() {
            lines.push(format!("headings: {}", self.headings.join(" · ")));
        }
        if !self.visible_text.is_empty() {
            lines.push(format!("visible: {}", self.visible_text.join(" · ")));
        }
        lines.join("\n")
    }

    #[must_use]
    pub fn fallback_summary(&self) -> String {
        let app = self.application_name.as_deref().unwrap_or("an app");
        let place = self
            .url
            .as_deref()
            .or(self.document.as_deref())
            .or(self.window_title.as_deref());
        match place {
            Some(place) => format!("Used {app} on {place}."),
            None => format!("Used {app}."),
        }
    }
}

#[must_use]
pub fn digest_fingerprint(digest: &AccessibilityDigest) -> String {
    let mut hasher = DefaultHasher::new();
    digest.identity_key().hash(&mut hasher);
    digest.focused_role.hash(&mut hasher);
    digest.focused_title.hash(&mut hasher);
    digest.focused_value.hash(&mut hasher);
    digest.selected_text.hash(&mut hasher);
    digest.headings.hash(&mut hasher);
    digest.visible_text.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

#[must_use]
pub fn is_idle_digest(digest: &AccessibilityDigest) -> bool {
    let bundle = digest.bundle_identifier.as_deref().unwrap_or("");
    if matches!(
        bundle,
        "com.apple.loginwindow" | "com.apple.ScreenSaver.Engine" | "com.apple.controlcenter"
    ) {
        return true;
    }
    digest.application_name.is_none()
        && digest.window_title.is_none()
        && digest.url.is_none()
        && digest.document.is_none()
        && digest.focused_value.is_none()
        && digest.visible_text.is_empty()
}

/// Roles whose text is document content rather than app chrome. Buttons,
/// menus and toolbars are deliberately absent: their labels repeat on every
/// frame of every app and carry no narrative.
const TEXT_ROLES: &[&str] = &[
    "AXStaticText",
    "AXTextArea",
    "AXTextField",
    "AXHeading",
    "AXLink",
];

/// Extracts content text lines from the full accessibility tree, in tree
/// order. Values are split on newlines so a multi-paragraph `AXTextArea` does
/// not arrive as one enormous line. Exact where OCR is noisy; scoped to the
/// frontmost application by construction of the snapshot.
#[must_use]
pub fn accessibility_text_lines(snapshot: &[u8]) -> Vec<String> {
    const LINE_CLIP_CHARS: usize = 500;
    let Ok(header) = serde_json::from_slice::<SnapshotHeader>(snapshot) else {
        return Vec::new();
    };
    let private_browsing = header.private_browsing;
    let Some(root) = header.root else {
        return Vec::new();
    };
    let mut lines = Vec::new();
    collect_text_lines(&root, &mut lines, LINE_CLIP_CHARS, private_browsing);
    lines
}

fn collect_text_lines(
    node: &SnapshotNode,
    lines: &mut Vec<String>,
    clip_chars: usize,
    private_browsing: bool,
) {
    let role = node.role.as_deref().unwrap_or("");
    if TEXT_ROLES.contains(&role) {
        let text = node
            .value
            .as_deref()
            .filter(|value| !value.trim().is_empty())
            .or(node.title.as_deref());
        if let Some(text) = text
            && !(private_browsing && is_location_field(role) && looks_like_web_location(text))
        {
            for line in text.lines() {
                let trimmed = line.trim();
                if trimmed.chars().count() >= 2 {
                    lines.push(clip(trimmed, clip_chars));
                }
            }
        }
    }
    for child in &node.children {
        collect_text_lines(child, lines, clip_chars, private_browsing);
    }
}

#[must_use]
pub fn parse_accessibility_digest(snapshot: &[u8]) -> AccessibilityDigest {
    let Ok(header) = serde_json::from_slice::<SnapshotHeader>(snapshot) else {
        return AccessibilityDigest::default();
    };
    let private_browsing = header.private_browsing;
    if let Some(digest) = header.digest {
        let mut parsed = AccessibilityDigest {
            application_name: nonempty(header.application_name).or(digest.application_name),
            bundle_identifier: nonempty(header.bundle_identifier).or(digest.bundle_identifier),
            window_title: nonempty(header.window_title).or(digest.window_title),
            url: nonempty(header.url).or(digest.url),
            document: nonempty(header.document).or(digest.document),
            focused_role: digest.focused_role,
            focused_title: digest.focused_title,
            focused_value: digest
                .focused_value
                .map(|value| clip(&value, FOCUSED_VALUE_CHARS)),
            selected_text: digest.selected_text,
            headings: digest.headings,
            visible_text: digest.visible_text,
        };
        if private_browsing {
            redact_private_digest_locations(&mut parsed);
        }
        return parsed;
    }
    let mut digest = AccessibilityDigest {
        application_name: nonempty(header.application_name),
        bundle_identifier: nonempty(header.bundle_identifier),
        window_title: nonempty(header.window_title),
        url: nonempty(header.url),
        document: nonempty(header.document),
        ..AccessibilityDigest::default()
    };
    if let Some(root) = header.root {
        fill_digest(&mut digest, &root);
    }
    if private_browsing {
        redact_private_digest_locations(&mut digest);
    }
    digest
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
    digest: Option<SnapshotDigest>,
    #[serde(default)]
    root: Option<SnapshotNode>,
}

#[derive(Debug, Default, Deserialize)]
struct SnapshotDigest {
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
    focused_role: Option<String>,
    #[serde(default)]
    focused_title: Option<String>,
    #[serde(default)]
    focused_value: Option<String>,
    #[serde(default)]
    selected_text: Option<String>,
    #[serde(default)]
    headings: Vec<String>,
    #[serde(default)]
    visible_text: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct SnapshotNode {
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    subrole: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    value: Option<String>,
    #[serde(default)]
    focused: Option<bool>,
    #[serde(default)]
    children: Vec<SnapshotNode>,
}

fn fill_digest(digest: &mut AccessibilityDigest, node: &SnapshotNode) {
    if node.focused == Some(true) && digest.focused_role.is_none() {
        digest.focused_role = nonempty(node.role.clone());
        digest.focused_title = nonempty(node.title.clone());
        digest.focused_value =
            nonempty(node.value.clone()).map(|value| clip(&value, FOCUSED_VALUE_CHARS));
    }
    let role = node.role.as_deref().unwrap_or("");
    let subrole = node.subrole.as_deref().unwrap_or("");
    if (role == "AXHeading" || subrole == "AXHeading")
        && digest.headings.len() < 8
        && let Some(title) = first_text(node)
    {
        push_unique(&mut digest.headings, title, 8);
    }
    if matches!(
        role,
        "AXStaticText" | "AXTextField" | "AXTextArea" | "AXLink"
    ) && let Some(text) = first_text(node)
    {
        push_unique(
            &mut digest.visible_text,
            clip(&text, VISIBLE_TEXT_CHARS),
            VISIBLE_TEXT_LIMIT,
        );
    }
    for child in &node.children {
        if digest.visible_text.len() >= VISIBLE_TEXT_LIMIT && digest.focused_role.is_some() {
            return;
        }
        fill_digest(digest, child);
    }
}

fn first_text(node: &SnapshotNode) -> Option<String> {
    nonempty(node.title.clone()).or_else(|| nonempty(node.value.clone()))
}

fn is_location_field(role: &str) -> bool {
    matches!(role, "AXTextField" | "AXSearchField" | "AXComboBox")
}

fn looks_like_web_location(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty()
        || value.starts_with("file://")
        || (value.starts_with('/') && !value.starts_with("//"))
    {
        return false;
    }
    let lower = value.to_ascii_lowercase();
    lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("www.")
        || (!value.chars().any(char::is_whitespace) && value.contains('.'))
}

fn redact_private_digest_locations(digest: &mut AccessibilityDigest) {
    digest.url = None;
    if is_location_field(digest.focused_role.as_deref().unwrap_or(""))
        && digest
            .focused_value
            .as_deref()
            .is_some_and(looks_like_web_location)
    {
        digest.focused_value = None;
    }
    digest
        .visible_text
        .retain(|value| !looks_like_web_location(value));
}

fn push_unique(items: &mut Vec<String>, value: String, limit: usize) {
    if items.len() >= limit || items.iter().any(|item| item == &value) {
        return;
    }
    items.push(value);
}

fn nonempty(value: Option<String>) -> Option<String> {
    value.and_then(|item| {
        let trimmed = item.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_owned())
        }
    })
}

fn clip(value: &str, max_chars: usize) -> String {
    let trimmed = value.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_owned();
    }
    format!(
        "{}…",
        trimmed
            .chars()
            .take(max_chars.saturating_sub(1))
            .collect::<String>()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_digest_is_preferred() {
        let snapshot = br#"{
            "application_name":"Safari",
            "bundle_identifier":"com.apple.Safari",
            "digest":{
                "url":"https://example.com/",
                "focused_role":"AXWebArea",
                "visible_text":["Example Domain"]
            }
        }"#;
        let digest = parse_accessibility_digest(snapshot);
        assert_eq!(digest.url.as_deref(), Some("https://example.com/"));
        assert_eq!(digest.focused_role.as_deref(), Some("AXWebArea"));
        assert_eq!(digest.visible_text, ["Example Domain"]);
        assert!(!is_idle_digest(&digest));
    }

    #[test]
    fn tree_fallback_reads_focused_and_visible_text() {
        let snapshot = br#"{
            "application_name":"Xcode",
            "bundle_identifier":"com.apple.dt.Xcode",
            "window_title":"main.rs",
            "root":{
                "role":"AXApplication",
                "children":[{
                    "role":"AXTextArea",
                    "focused":true,
                    "value":"fn main() {}"
                },{
                    "role":"AXStaticText",
                    "value":"Package.swift"
                }]
            }
        }"#;
        let digest = parse_accessibility_digest(snapshot);
        assert_eq!(digest.focused_role.as_deref(), Some("AXTextArea"));
        assert_eq!(digest.focused_value.as_deref(), Some("fn main() {}"));
        assert!(
            digest
                .visible_text
                .iter()
                .any(|text| text == "Package.swift")
        );
        assert_eq!(digest_fingerprint(&digest), digest_fingerprint(&digest));
    }

    #[test]
    fn text_lines_take_content_roles_and_split_multiline_values() {
        let snapshot = br#"{
            "application_name":"Lody",
            "root":{
                "role":"AXApplication",
                "children":[
                    {"role":"AXButton","title":"Send"},
                    {"role":"AXTextArea","value":"first paragraph\nsecond paragraph"},
                    {"role":"AXStaticText","value":"a visible sentence"},
                    {"role":"AXMenuItem","title":"Preferences"}
                ]
            }
        }"#;
        let lines = accessibility_text_lines(snapshot);
        assert_eq!(
            lines,
            ["first paragraph", "second paragraph", "a visible sentence"],
            "buttons and menus are chrome, not content"
        );
    }

    #[test]
    fn private_browsing_digest_and_text_lines_drop_web_locations() {
        let snapshot = br#"{
            "application_name":"Google Chrome",
            "private_browsing":true,
            "url":"https://private.example/account",
            "digest":{
                "url":"https://private.example/account",
                "focused_role":"AXTextField",
                "focused_value":"private.example/account",
                "visible_text":["private.example/account", "Account settings"]
            },
            "root":{
                "role":"AXApplication",
                "children":[
                    {"role":"AXTextField","value":"private.example/account"},
                    {"role":"AXStaticText","value":"Account settings"}
                ]
            }
        }"#;

        let digest = parse_accessibility_digest(snapshot);

        assert!(digest.url.is_none());
        assert!(digest.focused_value.is_none());
        assert_eq!(digest.visible_text, ["Account settings"]);
        assert_eq!(accessibility_text_lines(snapshot), ["Account settings"]);

        let fallback = br#"{
            "private_browsing":true,
            "url":"https://private.example/account",
            "root":{"role":"AXTextField","focused":true,"value":"private.example/account"}
        }"#;
        let fallback_digest = parse_accessibility_digest(fallback);
        assert!(fallback_digest.url.is_none());
        assert!(fallback_digest.focused_value.is_none());
        assert!(fallback_digest.visible_text.is_empty());
    }

    #[test]
    fn lock_screen_is_idle() {
        let digest = AccessibilityDigest {
            bundle_identifier: Some("com.apple.loginwindow".into()),
            ..AccessibilityDigest::default()
        };
        assert!(is_idle_digest(&digest));
    }
}
