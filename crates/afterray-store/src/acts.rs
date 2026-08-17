//! The join between the two fact streams.
//!
//! The vault holds two independent observations of a stretch of time: screen
//! state (the accessibility tree — what could be *seen*) and input events
//! (what the user *did*). This module joins them by time and tree position and
//! nothing else. It never infers agency from screen content: every heuristic
//! that tried — geometry rules, placeholder parsing, text churn — was wrong on
//! some app, and the group-chat corpus made churn point the wrong way outright.
//! See `docs/input-events-and-t1-acts-plan.md`.
//!
//! Everything here is pure: fixed input, fixed output, no clock, no model.

use crate::memory::AxScopeTree;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// How large a region must be, as a share of its window, to be called the
/// engaged scope. The landing point's lowest common ancestor is often a single
/// label; the region a person would name is the pane around it.
///
/// **The only tuning knob in the whole join**, pinned against real corpora
/// (IM 1:1, group chat, editor, terminal). Anything else that wants to be a
/// knob is a heuristic in disguise.
pub const ENGAGED_MIN_WINDOW_AREA_RATIO: f64 = 0.10;

/// Roles that bound a scope search. Expansion never walks past the window:
/// "the whole screen" is not a region a person operated.
const WINDOW_ROLES: &[&str] = &["AXWindow", "AXStandardWindow"];

/// A rectangle in global top-left screen points.
///
/// `f64` because the two producers disagree on encoding and neither is wrong:
/// tree nodes carry doubles, the shim's event targets carry rounded ints. Both
/// deserialise into this without a second shape to keep in step.
#[derive(Debug, Clone, Copy, Default, PartialEq, Deserialize, Serialize)]
pub struct AxRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl AxRect {
    #[must_use]
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    /// The point a hit test uses. A click's target rect is the *element* the
    /// shim resolved, not the pointer position — its centre is the honest
    /// stand-in, and it stays meaningful for a zero-size rect.
    #[must_use]
    pub fn center(&self) -> (f64, f64) {
        (self.x + self.width / 2.0, self.y + self.height / 2.0)
    }

    #[must_use]
    pub fn area(&self) -> f64 {
        if self.width <= 0.0 || self.height <= 0.0 {
            0.0
        } else {
            self.width * self.height
        }
    }

    /// Inclusive on both edges, but never true for a degenerate rect: a node
    /// with no area cannot be the region something landed in.
    #[must_use]
    pub fn contains(&self, x: f64, y: f64) -> bool {
        self.area() > 0.0
            && x >= self.x
            && x <= self.x + self.width
            && y >= self.y
            && y <= self.y + self.height
    }

    /// True when the rect carries usable geometry at all.
    #[must_use]
    pub fn is_measurable(&self) -> bool {
        self.area() > 0.0 && self.x.is_finite() && self.y.is_finite()
    }
}

/// Deepest node whose frame contains the centre of `rect`.
///
/// Ties break on smaller area, then lower index, so two frames of the same UI
/// resolve to the same node — determinism is what lets a card be rebuilt.
#[must_use]
pub fn hit_test(tree: &AxScopeTree, rect: AxRect) -> Option<usize> {
    let (x, y) = rect.center();
    if !x.is_finite() || !y.is_finite() {
        return None;
    }
    let mut best: Option<(usize, u16, f64)> = None;
    for (index, node) in tree.nodes.iter().enumerate() {
        let Some(frame) = node.frame else { continue };
        if !frame.contains(x, y) {
            continue;
        }
        let area = frame.area();
        let better = match best {
            None => true,
            Some((_, depth, best_area)) => {
                node.depth > depth || (node.depth == depth && area < best_area)
            }
        };
        if better {
            best = Some((index, node.depth, area));
        }
    }
    best.map(|(index, _, _)| index)
}

/// Lowest common ancestor of `nodes`, or `None` when the slice is empty or
/// holds an index the tree does not have.
#[must_use]
pub fn lca(tree: &AxScopeTree, nodes: &[usize]) -> Option<usize> {
    let mut cursor = *nodes.first()?;
    if cursor >= tree.nodes.len() {
        return None;
    }
    for &node in &nodes[1..] {
        if node >= tree.nodes.len() {
            return None;
        }
        cursor = lca_pair(tree, cursor, node)?;
    }
    Some(cursor)
}

fn lca_pair(tree: &AxScopeTree, mut left: usize, mut right: usize) -> Option<usize> {
    // Bounded by the arena size: a cycle in a malformed tree must not hang a
    // card build.
    let mut guard = tree.nodes.len().saturating_mul(2) + 2;
    while tree.nodes.get(left)?.depth > tree.nodes.get(right)?.depth {
        left = tree.nodes.get(left)?.parent?;
        guard = guard.checked_sub(1)?;
    }
    while tree.nodes.get(right)?.depth > tree.nodes.get(left)?.depth {
        right = tree.nodes.get(right)?.parent?;
        guard = guard.checked_sub(1)?;
    }
    while left != right {
        left = tree.nodes.get(left)?.parent?;
        right = tree.nodes.get(right)?.parent?;
        guard = guard.checked_sub(1)?;
    }
    Some(left)
}

/// True when `node` is `ancestor` or sits inside its subtree.
#[must_use]
pub fn is_within(tree: &AxScopeTree, ancestor: usize, node: usize) -> bool {
    let mut cursor = Some(node);
    let mut guard = tree.nodes.len() + 1;
    while let Some(index) = cursor {
        if index == ancestor {
            return true;
        }
        guard = match guard.checked_sub(1) {
            Some(next) => next,
            None => return false,
        };
        cursor = tree.nodes.get(index).and_then(|held| held.parent);
    }
    false
}

/// Nearest window at or above `node`; falls back to the first window-roled
/// node anywhere in the tree, since a snapshot rooted below the window still
/// has one somewhere.
#[must_use]
pub fn window_node(tree: &AxScopeTree, node: usize) -> Option<usize> {
    let is_window = |index: usize| {
        tree.nodes.get(index).is_some_and(|held| {
            WINDOW_ROLES.contains(&held.role.as_str())
                || held
                    .subrole
                    .as_deref()
                    .is_some_and(|subrole| WINDOW_ROLES.contains(&subrole))
        })
    };
    let mut cursor = Some(node);
    let mut guard = tree.nodes.len() + 1;
    while let Some(index) = cursor {
        if is_window(index) {
            return Some(index);
        }
        guard = guard.checked_sub(1)?;
        cursor = tree.nodes.get(index).and_then(|held| held.parent);
    }
    (0..tree.nodes.len()).find(|&index| is_window(index))
}

/// Walks up from `seed` until the node covers `ratio` of the window, stopping
/// at the window itself.
#[must_use]
pub fn expand_to_region(tree: &AxScopeTree, seed: usize, window: usize, window_area: f64) -> usize {
    let threshold = window_area * ENGAGED_MIN_WINDOW_AREA_RATIO;
    let mut cursor = seed;
    let mut guard = tree.nodes.len() + 1;
    loop {
        let Some(node) = tree.nodes.get(cursor) else {
            return cursor;
        };
        if node.frame.map_or(0.0, |frame| frame.area()) >= threshold || cursor == window {
            return cursor;
        }
        match node.parent {
            Some(parent) if guard > 0 => {
                cursor = parent;
                guard -= 1;
            }
            _ => return cursor,
        }
    }
}

/// The region of this frame the user was operating: the landing points' lowest
/// common ancestor, grown to the smallest ancestor covering
/// [`ENGAGED_MIN_WINDOW_AREA_RATIO`] of its window.
///
/// `None` whenever the join cannot answer honestly — nothing landed in this
/// tree, or the window has no measurable frame. There is no fallback: an
/// invented scope is worse than no scope, because everything downstream reads
/// a scope as "the user was here".
#[must_use]
pub fn engaged_scope(tree: &AxScopeTree, rects: &[AxRect]) -> Option<usize> {
    let hits: Vec<usize> = rects
        .iter()
        .filter_map(|rect| hit_test(tree, *rect))
        .collect();
    if hits.is_empty() {
        return None;
    }
    let seed = lca(tree, &hits)?;
    let window = window_node(tree, seed)?;
    let window_area = tree.nodes.get(window)?.frame.filter(AxRect::is_measurable)?.area();
    Some(expand_to_region(tree, seed, window, window_area))
}

/// Stable identity for a scope across frames of the same UI.
///
/// Node indices are per-snapshot, so segmenting an event stream by scope needs
/// a key the next heartbeat will reproduce: the `role:label` path from the
/// window down. Labels, not indices — a list that gained a row must not read
/// as a different region.
#[must_use]
pub fn scope_key(tree: &AxScopeTree, node: usize) -> String {
    let mut chain: Vec<String> = Vec::new();
    let window = window_node(tree, node);
    let mut cursor = Some(node);
    let mut guard = tree.nodes.len() + 1;
    while let Some(index) = cursor {
        let Some(held) = tree.nodes.get(index) else {
            break;
        };
        chain.push(match held.label.as_deref() {
            Some(label) => format!("{}:{}", held.role, clip(label, 40)),
            None => held.role.clone(),
        });
        if Some(index) == window || guard == 0 {
            break;
        }
        guard -= 1;
        cursor = held.parent;
    }
    chain.reverse();
    chain.join(">")
}

/// A sibling region of the engaged scope: what else was on screen at the same
/// level, and how much text it held.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Region {
    pub label: String,
    pub lines: usize,
    /// True for the region the input landed in.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub engaged: bool,
}

/// The engaged scope's siblings, with the line count of each subtree.
///
/// This is the field that flipped weak models in the corpus experiment: told
/// "region 2 holds 40 lines and was never touched", a 4B model stops writing
/// the sidebar into the card. It is only honest because it is derived from
/// events, never from what the text looks like.
#[must_use]
pub fn sibling_regions(tree: &AxScopeTree, scope: usize) -> Vec<Region> {
    let Some(node) = tree.nodes.get(scope) else {
        return Vec::new();
    };
    // The scope is the whole window: there is no "elsewhere" at its level.
    let Some(parent) = node.parent else {
        return Vec::new();
    };
    let mut counts: HashMap<usize, usize> = HashMap::new();
    for &owner in &tree.line_node {
        let mut cursor = Some(owner);
        let mut guard = tree.nodes.len() + 1;
        while let Some(index) = cursor {
            if tree.nodes.get(index).and_then(|held| held.parent) == Some(parent) {
                *counts.entry(index).or_insert(0) += 1;
                break;
            }
            guard = match guard.checked_sub(1) {
                Some(next) => next,
                None => break,
            };
            cursor = tree.nodes.get(index).and_then(|held| held.parent);
        }
    }
    let mut regions: Vec<Region> = (0..tree.nodes.len())
        .filter(|&index| tree.nodes.get(index).and_then(|held| held.parent) == Some(parent))
        .map(|index| Region {
            label: region_label(tree, index),
            lines: counts.get(&index).copied().unwrap_or(0),
            engaged: index == scope,
        })
        .collect();
    regions.retain(|region| region.engaged || region.lines > 0);
    regions
}

/// A region's name: its own label, else the first label below it, else its
/// role. Never its text — a label is what a region is called.
fn region_label(tree: &AxScopeTree, index: usize) -> String {
    let Some(node) = tree.nodes.get(index) else {
        return String::new();
    };
    if let Some(label) = node.label.as_deref() {
        return clip(label, 60);
    }
    let descendant = (index + 1..tree.nodes.len())
        .take_while(|&candidate| is_within(tree, index, candidate))
        .find_map(|candidate| {
            tree.nodes
                .get(candidate)
                .and_then(|held| held.label.as_deref())
        });
    descendant.map_or_else(|| node.role.clone(), |label| clip(label, 60))
}

fn clip(value: &str, max_chars: usize) -> String {
    let trimmed = value.trim();
    if trimmed.chars().count() <= max_chars {
        return trimmed.to_owned();
    }
    trimmed.chars().take(max_chars).collect()
}

// ------------------------------------------------------------------ acts

/// The synthetic row the daemon writes when the shim reports its input tap
/// stalled or never started. Not an act: a hole in the observation of acts.
///
/// The vault stores `kind` uninterpreted, so this needs no schema change — and
/// it must ride in the same stream as the events, because a gap is only
/// meaningful in its place in time.
pub const SIGNAL_GAP_KIND: &str = "signal_gap";

/// Events must sustain a new scope this long, or this many events, before the
/// stream splits. Rapid alternation between panes is triage — one stretch of
/// work — not a run per glance.
pub const RUN_HYSTERESIS_MIN_EVENTS: usize = 2;
/// The time half of the same rule.
pub const RUN_HYSTERESIS_MIN_MS: i64 = 15_000;

/// How much time a point event is taken to occupy when measuring input
/// coverage. A click is instantaneous as recorded and obviously not as lived.
const POINT_EVENT_MS: i64 = 1_000;

/// Cap on the submits listed for one run; the key and scroll counts already
/// carry volume, and an unbounded list would spend the prompt on ⌘S.
const MAX_SUBMITS: usize = 12;
/// Cap on distinct click targets listed for one run.
const MAX_CLICK_TARGETS: usize = 8;

/// What the user did, over one stretch. Deterministic, aggregated from events
/// alone — nothing here is read off the screen.
///
/// The shape is fixed: every field is always serialised, because a reader (the
/// T2 prompt, a materialised card) must be able to tell "zero keys" from "keys
/// unknown", and a missing field cannot.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Acts {
    /// Keystrokes, summed over typing bursts. Never their content.
    pub keys: u32,
    pub submits: Vec<Submit>,
    pub clicks: Vec<ClickTally>,
    pub scrolls: u32,
    pub signal: ActsSignal,
}

/// One command key: "submit/execute" in whatever the app calls it — send in a
/// chat, run in a terminal, save in an editor. The single sharpest read-vs-write
/// discriminator the input stream carries.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Submit {
    pub at_ms: i64,
    pub kind: String,
}

/// Clicks on one target, by the target's own label.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClickTally {
    pub label: String,
    pub count: u32,
}

/// Whether the input stream can be trusted over this stretch.
///
/// `Unavailable` is not "no input": it is "we could not observe input", and the
/// two must never collapse. Reading a dead tap as an idle user is the exact
/// failure this pipeline exists to prevent, so an unavailable stretch may carry
/// no engaged assertion at all.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActsSignal {
    #[default]
    Ok,
    Unavailable,
}

impl Acts {
    /// Whether anything at all was observed. A run with an `Ok` signal and
    /// nothing observed is a real, useful fact ("22 minutes here, no input").
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.keys == 0 && self.submits.is_empty() && self.clicks.is_empty() && self.scrolls == 0
    }

    /// Folds `other` in, keeping the caps and the worse signal.
    pub fn merge(&mut self, other: &Self) {
        self.keys = self.keys.saturating_add(other.keys);
        self.scrolls = self.scrolls.saturating_add(other.scrolls);
        self.submits.extend(other.submits.iter().cloned());
        self.submits.sort_by(|left, right| {
            left.at_ms
                .cmp(&right.at_ms)
                .then_with(|| left.kind.cmp(&right.kind))
        });
        self.submits.truncate(MAX_SUBMITS);
        for click in &other.clicks {
            match self
                .clicks
                .iter_mut()
                .find(|held| held.label == click.label)
            {
                Some(held) => held.count = held.count.saturating_add(click.count),
                None => self.clicks.push(click.clone()),
            }
        }
        sort_clicks(&mut self.clicks);
        if other.signal == ActsSignal::Unavailable {
            self.signal = ActsSignal::Unavailable;
        }
    }
}

fn sort_clicks(clicks: &mut Vec<ClickTally>) {
    clicks.sort_by(|left, right| {
        right
            .count
            .cmp(&left.count)
            .then_with(|| left.label.cmp(&right.label))
    });
    clicks.truncate(MAX_CLICK_TARGETS);
}

/// What kind of act a stored row describes.
///
/// `Other` exists because the vault stores `kind` uninterpreted and the shim
/// may ship ahead of its reader: an unrecognised kind still counts as "the user
/// did something here" for coverage, and contributes to nothing it cannot be
/// read into.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActKind {
    Burst,
    Command,
    Click,
    Scroll,
    SignalGap,
    Other,
}

/// One stored row, decoded: the act, when, where it landed, and — once the
/// per-frame join has run — which region of the screen that was.
#[derive(Debug, Clone, PartialEq)]
pub struct ActEvent {
    pub at_ms: i64,
    /// End of a span, normalised to be at or after `at_ms`; `None` is a point.
    pub end_ms: Option<i64>,
    pub kind: ActKind,
    pub count: u32,
    /// The named command of a `command` row.
    pub command: Option<String>,
    pub bundle_identifier: Option<String>,
    /// The target element's label, never its value.
    pub label: Option<String>,
    pub role: Option<String>,
    pub frame: Option<AxRect>,
    /// Engaged scope resolved against the nearest frame's tree. `None` means
    /// unresolved, which never forces a run boundary — an unknown scope is not
    /// evidence of a new one.
    pub scope: Option<String>,
}

impl ActEvent {
    /// Last instant this event occupies.
    #[must_use]
    pub fn until_ms(&self) -> i64 {
        self.end_ms.unwrap_or(self.at_ms).max(self.at_ms)
    }

    /// True when the row is an act rather than a hole in the observation.
    #[must_use]
    pub fn is_input(&self) -> bool {
        self.kind != ActKind::SignalGap
    }

    /// Whether the event touches `[from_ms, to_ms)` — the same half-open rule
    /// the vault's window query uses, so a run and a slot agree on an instant.
    #[must_use]
    pub fn overlaps(&self, from_ms: i64, to_ms: i64) -> bool {
        self.at_ms < to_ms && self.until_ms() >= from_ms
    }
}

#[derive(Debug, Deserialize)]
struct StoredTarget {
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    frame: Option<AxRect>,
}

/// Decodes one stored row. Never fails: a target that will not parse costs the
/// event its geometry, not its existence.
#[must_use]
pub fn parse_event(row: &crate::InputEventRow) -> ActEvent {
    let target = row
        .target_json
        .as_deref()
        .and_then(|json| serde_json::from_str::<StoredTarget>(json).ok());
    let kind = match row.kind.as_str() {
        "burst" => ActKind::Burst,
        "command" => ActKind::Command,
        "click" => ActKind::Click,
        "scroll" => ActKind::Scroll,
        SIGNAL_GAP_KIND => ActKind::SignalGap,
        _ => ActKind::Other,
    };
    ActEvent {
        at_ms: row.at_ms,
        end_ms: row.end_ms.filter(|end| *end >= row.at_ms),
        kind,
        count: row.count.unwrap_or(0),
        command: row.command.clone(),
        bundle_identifier: row.bundle_identifier.clone(),
        label: target.as_ref().and_then(|held| held.label.clone()),
        role: target.as_ref().and_then(|held| held.role.clone()),
        frame: target
            .and_then(|held| held.frame)
            .filter(AxRect::is_measurable),
        scope: None,
    }
}

#[must_use]
pub fn parse_events(rows: &[crate::InputEventRow]) -> Vec<ActEvent> {
    rows.iter().map(parse_event).collect()
}

/// Aggregates events into one `Acts`.
///
/// A `burst`'s `ended_with` is deliberately *not* a submit: the shim emits a
/// separate `command` row for the key that closed the burst, and counting both
/// would double every Return in the slot.
#[must_use]
pub fn fold_acts(events: &[ActEvent]) -> Acts {
    let mut acts = Acts::default();
    for event in events {
        match event.kind {
            ActKind::Burst => acts.keys = acts.keys.saturating_add(event.count),
            ActKind::Command => {
                if acts.submits.len() < MAX_SUBMITS {
                    acts.submits.push(Submit {
                        at_ms: event.at_ms,
                        kind: event
                            .command
                            .clone()
                            .unwrap_or_else(|| "command".to_owned()),
                    });
                }
            }
            ActKind::Click => {
                let label = click_label(event);
                match acts.clicks.iter_mut().find(|held| held.label == label) {
                    Some(held) => held.count = held.count.saturating_add(1),
                    None => acts.clicks.push(ClickTally { label, count: 1 }),
                }
            }
            // A coalesced scroll with no count is still one scroll.
            ActKind::Scroll => acts.scrolls = acts.scrolls.saturating_add(event.count.max(1)),
            ActKind::SignalGap => acts.signal = ActsSignal::Unavailable,
            ActKind::Other => {}
        }
    }
    sort_clicks(&mut acts.clicks);
    acts
}

/// A click's target: its label, else its role, else honestly unknown.
fn click_label(event: &ActEvent) -> String {
    event
        .label
        .as_deref()
        .map(str::trim)
        .filter(|label| !label.is_empty())
        .or_else(|| event.role.as_deref().filter(|role| !role.is_empty()))
        .map_or_else(|| "unknown".to_owned(), |label| clip(label, 60))
}

/// One stretch of the event stream on one engaged scope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActRun {
    /// The scope key these events shared, or `None` when it was never resolved.
    pub scope: Option<String>,
    pub start_ms: i64,
    pub end_ms: i64,
    pub acts: Acts,
}

/// Splits an event stream (in time order) into runs by engaged scope, with
/// hysteresis.
///
/// The rule the corpus forced: a new scope becomes a boundary only once it is
/// sustained — [`RUN_HYSTERESIS_MIN_EVENTS`] events or
/// [`RUN_HYSTERESIS_MIN_MS`] of span. Without it, triage (glancing at four
/// conversations and answering one) shatters into four runs of one click each,
/// and the card reads as a "multi-group scan" — the exact failure that started
/// this work. Un-promoted excursions fold back into the surrounding run, where
/// their clicked labels survive as the honest record of the glancing.
#[must_use]
pub fn split_act_runs(events: &[ActEvent]) -> Vec<ActRun> {
    let mut runs: Vec<ActRun> = Vec::new();
    // Indices into `events`; `pending` is an excursion not yet promoted.
    let mut current: Vec<usize> = Vec::new();
    let mut current_scope: Option<String> = None;
    let mut pending: Vec<usize> = Vec::new();
    let mut pending_scope: Option<String> = None;

    let close = |runs: &mut Vec<ActRun>, indices: &[usize], scope: Option<String>| {
        if indices.is_empty() {
            return;
        }
        let picked: Vec<ActEvent> = indices.iter().map(|&index| events[index].clone()).collect();
        let start_ms = picked.iter().map(|event| event.at_ms).min().unwrap_or(0);
        let end_ms = picked
            .iter()
            .map(ActEvent::until_ms)
            .max()
            .unwrap_or(start_ms);
        runs.push(ActRun {
            scope,
            start_ms,
            end_ms,
            acts: fold_acts(&picked),
        });
    };
    let sustained = |pending: &[usize]| {
        if pending.len() >= RUN_HYSTERESIS_MIN_EVENTS {
            return true;
        }
        let span = pending
            .iter()
            .map(|&index| events[index].until_ms())
            .max()
            .unwrap_or(0)
            - pending
                .iter()
                .map(|&index| events[index].at_ms)
                .min()
                .unwrap_or(0);
        span >= RUN_HYSTERESIS_MIN_MS
    };

    for (index, event) in events.iter().enumerate() {
        if current.is_empty() && pending.is_empty() {
            current_scope.clone_from(&event.scope);
            current.push(index);
            continue;
        }
        // An unresolved scope, or the scope already running, belongs to the
        // current run — and pulls any un-promoted excursion back into it.
        if event.scope.is_none() || event.scope == current_scope {
            current.append(&mut pending);
            pending_scope = None;
            current.push(index);
            continue;
        }
        if !pending.is_empty() && pending_scope != event.scope {
            // A third scope before the second was sustained: the second was
            // triage after all.
            current.append(&mut pending);
        }
        pending_scope.clone_from(&event.scope);
        pending.push(index);
        if sustained(&pending) {
            close(&mut runs, &current, current_scope.take());
            current = std::mem::take(&mut pending);
            current_scope = pending_scope.take();
        }
    }
    // Whatever never sustained itself ends inside the run it interrupted.
    current.append(&mut pending);
    close(&mut runs, &current, current_scope);
    runs
}

/// Stretches over which input could not be observed: from a gap marker to the
/// next real event, or to `to_ms` when the gap is the last thing in the window.
///
/// The end is the next observed act because that is when the tap demonstrably
/// worked again. Nothing shorter can be claimed.
#[must_use]
pub fn unavailable_spans(events: &[ActEvent], to_ms: i64) -> Vec<(i64, i64)> {
    let mut spans: Vec<(i64, i64)> = Vec::new();
    for (index, event) in events.iter().enumerate() {
        if event.kind != ActKind::SignalGap {
            continue;
        }
        let recovered = events[index + 1..]
            .iter()
            .find(|later| later.is_input())
            .map_or(to_ms.max(event.at_ms), |later| later.at_ms);
        spans.push((event.at_ms, recovered));
    }
    spans
}

/// True when `at_ms` falls in a stretch where input could not be observed.
#[must_use]
pub fn is_unavailable_at(spans: &[(i64, i64)], at_ms: i64) -> bool {
    spans
        .iter()
        .any(|&(from, until)| at_ms >= from && at_ms <= until)
}

/// Share of `[from_ms, to_ms)` with no observed input.
///
/// `None` when the window holds no input event at all — the honest answer,
/// because with nothing observed this is unmeasured rather than zero.
///
/// Known blind spot in v1: a slot where the user genuinely sat still and one
/// where the tap was off both have events elsewhere or none at all, and a slot
/// with a single click at its start reads as 99.8% no-input either way. The
/// gap markers are the only thing that distinguishes them, and they only exist
/// when the shim noticed.
#[must_use]
#[allow(clippy::cast_precision_loss)]
pub fn no_input_ratio(events: &[ActEvent], from_ms: i64, to_ms: i64) -> Option<f32> {
    let duration = to_ms.saturating_sub(from_ms);
    if duration <= 0 {
        return None;
    }
    let mut spans: Vec<(i64, i64)> = events
        .iter()
        .filter(|event| event.is_input())
        .map(|event| {
            let start = event.at_ms.max(from_ms);
            let end = event
                .end_ms
                .unwrap_or_else(|| event.at_ms.saturating_add(POINT_EVENT_MS))
                .max(event.at_ms.saturating_add(POINT_EVENT_MS))
                .min(to_ms);
            (start, end)
        })
        .filter(|(start, end)| end > start)
        .collect();
    if spans.is_empty() {
        return None;
    }
    spans.sort_unstable();
    let mut covered: i64 = 0;
    let mut cursor = spans[0];
    for span in spans.into_iter().skip(1) {
        if span.0 <= cursor.1 {
            cursor.1 = cursor.1.max(span.1);
        } else {
            covered += cursor.1 - cursor.0;
            cursor = span;
        }
    }
    covered += cursor.1 - cursor.0;
    let ratio = 1.0 - (covered as f32 / duration as f32);
    Some(ratio.clamp(0.0, 1.0))
}

/// What one frame's tree says about where that frame's input landed.
///
/// Computed per frame, next to the single decryption of that frame's tree —
/// the only place the tree is in hand — and carried on the moment row so the
/// pure card build can partition text without touching a vault.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FrameJoin {
    /// Stable identity of the engaged region, `None` when nothing resolved.
    pub scope: Option<String>,
    /// Parallel to the frame's accessibility text lines: `true` when the line
    /// sits inside the engaged region. Empty when there is no region, which
    /// means "do not partition" rather than "nothing is engaged".
    pub engaged: Vec<bool>,
    /// Sibling regions of the engaged one, with their line counts.
    pub regions: Vec<Region>,
}

impl FrameJoin {
    /// Whether this frame resolved a region at all. Without one, every line
    /// stays in the main bucket: an unpartitioned frame is honest, a frame
    /// partitioned against a guess is not.
    #[must_use]
    pub fn has_scope(&self) -> bool {
        self.scope.is_some() && !self.engaged.is_empty()
    }

    /// Whether the line at `index` is inside the engaged region. Lines the join
    /// never saw count as engaged, so a mismatch can only ever widen the
    /// budget, never silently drop text.
    #[must_use]
    pub fn line_is_engaged(&self, index: usize) -> bool {
        self.engaged.get(index).copied().unwrap_or(true)
    }
}

/// Indices of the events this frame can speak for.
///
/// A heartbeat frame is a snapshot of a moving screen, so an event is only
/// attributable to it if it happened within one capture interval — beyond that
/// the tree has probably moved on, and hit-testing against a stale layout would
/// invent a region. Bundle identifiers must agree when both are known: a click
/// in another app never landed in this window.
#[must_use]
pub fn frame_event_indices(
    events: &[ActEvent],
    at_ms: i64,
    step_ms: i64,
    bundle: Option<&str>,
) -> Vec<usize> {
    let window = step_ms.max(1_000);
    events
        .iter()
        .enumerate()
        .filter(|(_, event)| event.is_input() && event.frame.is_some())
        .filter(|(_, event)| event.overlaps(at_ms - window, at_ms + window))
        .filter(|(_, event)| match (event.bundle_identifier.as_deref(), bundle) {
            (Some(left), Some(right)) => left == right,
            _ => true,
        })
        .map(|(index, _)| index)
        .collect()
}

/// The region one event landed in, as a stable key.
#[must_use]
pub fn event_scope(tree: &AxScopeTree, rect: AxRect) -> Option<String> {
    engaged_scope(tree, &[rect]).map(|node| scope_key(tree, node))
}

/// Joins one frame's tree against the events attributable to it.
///
/// Returns `None` whenever the join cannot answer — no events landed in this
/// tree, or no window bounds the region — because everything downstream reads a
/// `Some` as "the user was in this region and not the others".
#[must_use]
pub fn join_frame(tree: &AxScopeTree, rects: &[AxRect]) -> Option<FrameJoin> {
    let scope = engaged_scope(tree, rects)?;
    let engaged: Vec<bool> = tree
        .line_node
        .iter()
        .map(|&owner| is_within(tree, scope, owner))
        .collect();
    Some(FrameJoin {
        scope: Some(scope_key(tree, scope)),
        engaged,
        regions: sibling_regions(tree, scope),
    })
}

/// Per-run acts frozen into `slot_summaries.acts_json` before the events they
/// came from expire.
///
/// Keyed by the run's own moment id rather than its position: a card is rebuilt
/// from frames, and a deleted frame would renumber every run after it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MaterializedActs {
    pub runs: Vec<MaterializedRun>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub no_input_ratio: Option<f32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MaterializedRun {
    /// The run's `moment_id`.
    pub id: String,
    pub acts: Acts,
}

impl MaterializedActs {
    #[must_use]
    pub fn acts_for(&self, moment_id: &str) -> Option<&Acts> {
        self.runs
            .iter()
            .find(|run| run.id == moment_id)
            .map(|run| &run.acts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `(parent, role, label, frame)` — one synthetic node.
    type NodeSpec<'a> = (Option<usize>, &'a str, Option<&'a str>, Option<AxRect>);

    /// Builds a scope tree from node specs plus the node each text line hangs
    /// off. Pre-order by construction: a parent is always declared before its
    /// children.
    fn tree(nodes: &[NodeSpec<'_>], lines: &[(usize, &str)]) -> AxScopeTree {
        let mut built = AxScopeTree::default();
        for (parent, role, label, frame) in nodes {
            let depth = parent.map_or(0, |index| built.nodes[index].depth + 1);
            built.nodes.push(crate::memory::AxScopeNode {
                parent: *parent,
                depth,
                role: (*role).to_owned(),
                subrole: None,
                label: label.map(ToOwned::to_owned),
                frame: *frame,
            });
        }
        for (owner, text) in lines {
            built.lines.push((*text).to_owned());
            built.line_node.push(*owner);
        }
        built
    }

    fn rect(x: f64, y: f64, width: f64, height: f64) -> AxRect {
        AxRect::new(x, y, width, height)
    }

    /// A window split into a narrow sidebar and a wide conversation pane, each
    /// holding one leaf. Window area 1000x1000; the sidebar is 20% of it, the
    /// conversation 80%, and every leaf far below the 10% floor.
    fn two_pane() -> AxScopeTree {
        tree(
            &[
                (None, "AXWindow", Some("Lark"), Some(rect(0.0, 0.0, 1000.0, 1000.0))),
                (Some(0), "AXSplitGroup", None, Some(rect(0.0, 0.0, 1000.0, 1000.0))),
                (Some(1), "AXGroup", Some("Conversations"), Some(rect(0.0, 0.0, 200.0, 1000.0))),
                (Some(2), "AXStaticText", None, Some(rect(10.0, 10.0, 100.0, 20.0))),
                (Some(1), "AXGroup", Some("Chat"), Some(rect(200.0, 0.0, 800.0, 1000.0))),
                (Some(4), "AXStaticText", None, Some(rect(210.0, 10.0, 100.0, 20.0))),
                (Some(4), "AXTextArea", Some("Message"), Some(rect(210.0, 900.0, 700.0, 80.0))),
            ],
            &[(3, "赵亮"), (5, "shipped the fix"), (5, "thanks"), (6, "typing")],
        )
    }

    #[test]
    fn hit_test_takes_the_deepest_containing_node() {
        let tree = two_pane();
        assert_eq!(hit_test(&tree, rect(210.0, 10.0, 100.0, 20.0)), Some(5));
        // A point inside the pane but in no leaf stops at the pane.
        assert_eq!(hit_test(&tree, rect(600.0, 500.0, 0.0, 0.0)), Some(4));
    }

    #[test]
    fn a_rect_outside_every_node_hits_nothing() {
        let tree = two_pane();
        assert_eq!(hit_test(&tree, rect(5_000.0, 5_000.0, 10.0, 10.0)), None);
        assert_eq!(engaged_scope(&tree, &[rect(5_000.0, 5_000.0, 10.0, 10.0)]), None);
    }

    #[test]
    fn a_degenerate_node_frame_is_never_hit() {
        let flat = tree(
            &[
                (None, "AXWindow", None, Some(rect(0.0, 0.0, 100.0, 100.0))),
                (Some(0), "AXGroup", None, Some(rect(50.0, 50.0, 0.0, 0.0))),
            ],
            &[],
        );
        assert_eq!(hit_test(&flat, rect(50.0, 50.0, 0.0, 0.0)), Some(0));
    }

    #[test]
    fn one_landing_point_expands_from_its_leaf_to_the_pane() {
        let tree = two_pane();
        // The leaf alone is the LCA (2000 px², 0.2% of the window), so the
        // scope has to grow: the conversation pane is the first ancestor over
        // 10% of 1_000_000 px².
        assert_eq!(hit_test(&tree, rect(210.0, 10.0, 100.0, 20.0)), Some(5));
        assert_eq!(engaged_scope(&tree, &[rect(210.0, 10.0, 100.0, 20.0)]), Some(4));
    }

    #[test]
    fn points_spanning_two_panes_rise_to_the_split() {
        let tree = two_pane();
        let scope = engaged_scope(
            &tree,
            &[rect(10.0, 10.0, 100.0, 20.0), rect(210.0, 10.0, 100.0, 20.0)],
        );
        assert_eq!(scope, Some(1), "the LCA of both panes is already over 10%");
    }

    #[test]
    fn a_pane_already_over_the_ratio_does_not_expand() {
        let tree = two_pane();
        // The sidebar is 200_000 px² = 20% of the window: expansion stops there
        // rather than swallowing the whole split group.
        assert_eq!(engaged_scope(&tree, &[rect(10.0, 10.0, 100.0, 20.0)]), Some(2));
    }

    #[test]
    fn expansion_stops_at_the_window_even_when_nothing_is_big_enough() {
        let thin = tree(
            &[
                (None, "AXWindow", None, Some(rect(0.0, 0.0, 1000.0, 1000.0))),
                (Some(0), "AXGroup", None, Some(rect(0.0, 0.0, 10.0, 10.0))),
                (Some(1), "AXStaticText", None, Some(rect(0.0, 0.0, 5.0, 5.0))),
            ],
            &[],
        );
        assert_eq!(engaged_scope(&thin, &[rect(1.0, 1.0, 2.0, 2.0)]), Some(0));
    }

    #[test]
    fn no_window_frame_means_no_scope() {
        let unmeasured = tree(
            &[
                (None, "AXWindow", None, None),
                (Some(0), "AXGroup", None, Some(rect(0.0, 0.0, 10.0, 10.0))),
            ],
            &[],
        );
        assert_eq!(
            engaged_scope(&unmeasured, &[rect(1.0, 1.0, 2.0, 2.0)]),
            None,
            "fail open: an unmeasurable window cannot bound a region"
        );
        let windowless = tree(
            &[(None, "AXGroup", None, Some(rect(0.0, 0.0, 10.0, 10.0)))],
            &[],
        );
        assert_eq!(engaged_scope(&windowless, &[rect(1.0, 1.0, 2.0, 2.0)]), None);
    }

    #[test]
    fn lca_of_one_node_is_itself_and_of_a_missing_node_is_none() {
        let tree = two_pane();
        assert_eq!(lca(&tree, &[5]), Some(5));
        assert_eq!(lca(&tree, &[]), None);
        assert_eq!(lca(&tree, &[5, 99]), None);
        assert_eq!(lca(&tree, &[3, 6]), Some(1));
    }

    #[test]
    fn is_within_walks_up_the_arena() {
        let tree = two_pane();
        assert!(is_within(&tree, 4, 6));
        assert!(is_within(&tree, 4, 4));
        assert!(!is_within(&tree, 2, 6));
    }

    #[test]
    fn scope_keys_name_the_path_from_the_window_down() {
        let tree = two_pane();
        assert_eq!(
            scope_key(&tree, 4),
            "AXWindow:Lark>AXSplitGroup>AXGroup:Chat"
        );
        // Two frames of the same UI agree even though the arena grew a row.
        let mut grown = two_pane();
        grown.nodes.push(crate::memory::AxScopeNode {
            parent: Some(2),
            depth: 3,
            role: "AXStaticText".to_owned(),
            subrole: None,
            label: None,
            frame: Some(rect(10.0, 40.0, 100.0, 20.0)),
        });
        assert_eq!(scope_key(&tree, 4), scope_key(&grown, 4));
    }

    #[test]
    fn sibling_regions_count_lines_per_pane_and_mark_the_engaged_one() {
        let tree = two_pane();
        let regions = sibling_regions(&tree, 4);
        assert_eq!(
            regions,
            vec![
                Region {
                    label: "Conversations".to_owned(),
                    lines: 1,
                    engaged: false,
                },
                Region {
                    label: "Chat".to_owned(),
                    lines: 3,
                    engaged: true,
                },
            ]
        );
    }

    #[test]
    fn a_window_scope_has_no_siblings() {
        let tree = two_pane();
        assert!(sibling_regions(&tree, 0).is_empty());
    }

    // ------------------------------------------------------------ acts

    fn row(at_ms: i64, kind: &str) -> crate::InputEventRow {
        crate::InputEventRow {
            at_ms,
            end_ms: None,
            kind: kind.to_owned(),
            count: None,
            ended_with: None,
            command: None,
            bundle_identifier: Some("com.example.app".to_owned()),
            target_json: None,
        }
    }

    fn event(at_ms: i64, kind: ActKind, scope: Option<&str>) -> ActEvent {
        ActEvent {
            at_ms,
            end_ms: None,
            kind,
            count: 0,
            command: None,
            bundle_identifier: None,
            label: None,
            role: None,
            frame: None,
            scope: scope.map(ToOwned::to_owned),
        }
    }

    fn click(at_ms: i64, label: &str, scope: Option<&str>) -> ActEvent {
        ActEvent {
            label: Some(label.to_owned()),
            ..event(at_ms, ActKind::Click, scope)
        }
    }

    #[test]
    fn a_stored_row_decodes_with_its_target_geometry() {
        let mut stored = row(1_000, "click");
        stored.target_json = Some(
            r#"{"role":"AXStaticText","label":"0817.log",
                "frame":{"x":831,"y":899,"width":541,"height":22},
                "ancestors":[{"role":"AXGroup","label":null}]}"#
                .to_owned(),
        );
        let parsed = parse_event(&stored);
        assert_eq!(parsed.kind, ActKind::Click);
        assert_eq!(parsed.label.as_deref(), Some("0817.log"));
        assert_eq!(parsed.frame, Some(rect(831.0, 899.0, 541.0, 22.0)));
        assert!(parsed.scope.is_none(), "the join resolves scope, not the parse");

        // A target that will not parse costs geometry, never the event.
        let mut broken = row(2_000, "click");
        broken.target_json = Some("{not json".to_owned());
        let parsed = parse_event(&broken);
        assert_eq!(parsed.kind, ActKind::Click);
        assert!(parsed.frame.is_none());

        // A zero-area frame is not geometry.
        let mut flat = row(3_000, "click");
        flat.target_json = Some(r#"{"frame":{"x":1,"y":2,"width":0,"height":0}}"#.to_owned());
        assert!(parse_event(&flat).frame.is_none());
    }

    #[test]
    fn an_unknown_kind_is_carried_but_read_into_nothing() {
        let parsed = parse_event(&row(1_000, "hover_dwell"));
        assert_eq!(parsed.kind, ActKind::Other, "a newer shim may ship ahead");
        assert!(parsed.is_input(), "still evidence the user was present");
        let acts = fold_acts(&[parsed]);
        assert_eq!(acts, Acts::default(), "and contributes to no count");
        assert_eq!(acts.signal, ActsSignal::Ok);
    }

    #[test]
    fn a_burst_ending_in_return_counts_its_keys_once_and_its_submit_once() {
        // The shim emits both a burst carrying `ended_with` and a separate
        // command row for the key that closed it. Counting the submit twice is
        // the obvious bug here, so it is pinned.
        let mut burst = row(1_000, "burst");
        burst.end_ms = Some(4_000);
        burst.count = Some(42);
        burst.ended_with = Some("return".to_owned());
        let mut command = row(4_000, "command");
        command.command = Some("return".to_owned());

        let acts = fold_acts(&parse_events(&[burst, command]));
        assert_eq!(acts.keys, 42);
        assert_eq!(
            acts.submits,
            vec![Submit {
                at_ms: 4_000,
                kind: "return".to_owned()
            }]
        );
    }

    #[test]
    fn clicks_tally_by_label_and_scrolls_by_tick() {
        let mut scroll = row(9_000, "scroll");
        scroll.count = Some(7);
        let mut untargeted = row(10_000, "click");
        untargeted.target_json = Some(r#"{"role":"AXRow"}"#.to_owned());
        let mut uncounted_scroll = row(11_000, "scroll");
        uncounted_scroll.count = None;

        let mut events = vec![
            click(1_000, "0817.log", None),
            click(2_000, "Lody Team", None),
            click(3_000, "0817.log", None),
        ];
        events.extend(parse_events(&[scroll, untargeted, uncounted_scroll]));
        let acts = fold_acts(&events);

        assert_eq!(
            acts.clicks,
            vec![
                ClickTally {
                    label: "0817.log".to_owned(),
                    count: 2,
                },
                ClickTally {
                    label: "AXRow".to_owned(),
                    count: 1,
                },
                ClickTally {
                    label: "Lody Team".to_owned(),
                    count: 1,
                },
            ],
            "ordered by count, then label, so a card is reproducible"
        );
        assert_eq!(acts.scrolls, 8, "an uncounted coalesced scroll is still one");
    }

    #[test]
    fn a_signal_gap_makes_the_stretch_unavailable_not_idle() {
        let events = parse_events(&[row(1_000, "click"), row(2_000, SIGNAL_GAP_KIND)]);
        let acts = fold_acts(&events);
        assert_eq!(acts.signal, ActsSignal::Unavailable);
        assert_eq!(acts.clicks.len(), 1, "the observed act still stands");

        // The gap runs until input is observed again, and no further.
        let events = parse_events(&[
            row(1_000, SIGNAL_GAP_KIND),
            row(5_000, "click"),
            row(9_000, SIGNAL_GAP_KIND),
        ]);
        let spans = unavailable_spans(&events, 60_000);
        assert_eq!(spans, vec![(1_000, 5_000), (9_000, 60_000)]);
        assert!(is_unavailable_at(&spans, 3_000));
        assert!(!is_unavailable_at(&spans, 6_000));
        assert!(is_unavailable_at(&spans, 30_000));
    }

    #[test]
    fn a_sustained_scope_change_splits_the_run() {
        // Two events in the sidebar is enough to be a run of its own.
        let events = vec![
            click(1_000, "msg", Some("chat")),
            click(2_000, "msg", Some("chat")),
            click(3_000, "Lody Team", Some("sidebar")),
            click(4_000, "Design", Some("sidebar")),
        ];
        let runs = split_act_runs(&events);
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].scope.as_deref(), Some("chat"));
        assert_eq!(runs[0].start_ms, 1_000);
        assert_eq!(runs[0].end_ms, 2_000);
        assert_eq!(runs[1].scope.as_deref(), Some("sidebar"));
        assert_eq!(runs[1].start_ms, 3_000);
    }

    #[test]
    fn one_long_event_sustains_a_scope_change_on_its_own() {
        let mut long = event(3_000, ActKind::Burst, Some("editor"));
        long.end_ms = Some(3_000 + RUN_HYSTERESIS_MIN_MS);
        long.count = 300;
        let events = vec![click(1_000, "msg", Some("chat")), long];
        let runs = split_act_runs(&events);
        assert_eq!(runs.len(), 2, "a 15s burst is not a glance");
        assert_eq!(runs[1].scope.as_deref(), Some("editor"));
        assert_eq!(runs[1].acts.keys, 300);

        // One short excursion is not a boundary in either direction.
        let mut brief = event(3_000, ActKind::Burst, Some("editor"));
        brief.end_ms = Some(3_500);
        brief.count = 4;
        let runs = split_act_runs(&[click(1_000, "msg", Some("chat")), brief]);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].scope.as_deref(), Some("chat"));
        assert_eq!(runs[0].acts.keys, 4);
    }

    #[test]
    fn rapid_alternation_merges_into_one_run_carrying_the_clicked_labels() {
        // Triage: four conversations glanced at, one answered. The card must
        // read as one stretch whose acts name what was clicked, not as four
        // runs of one click — the "multi-group scan" failure.
        let events = vec![
            click(1_000, "Lody Team", Some("sidebar")),
            click(2_000, "赵亮", Some("chat-a")),
            click(3_000, "Design", Some("sidebar")),
            click(4_000, "Ops", Some("chat-b")),
            click(5_000, "Lody Team", Some("sidebar")),
        ];
        let runs = split_act_runs(&events);
        assert_eq!(runs.len(), 1, "no scope was ever sustained");
        assert_eq!(runs[0].scope.as_deref(), Some("sidebar"));
        assert_eq!(runs[0].start_ms, 1_000);
        assert_eq!(runs[0].end_ms, 5_000);
        let labels: Vec<&str> = runs[0]
            .acts
            .clicks
            .iter()
            .map(|click| click.label.as_str())
            .collect();
        assert_eq!(
            labels,
            ["Lody Team", "Design", "Ops", "赵亮"],
            "every glanced target survives as the record of the triage"
        );
    }

    #[test]
    fn an_unresolved_scope_never_forces_a_boundary() {
        let events = vec![
            click(1_000, "msg", Some("chat")),
            click(2_000, "msg", None),
            click(3_000, "msg", None),
            click(4_000, "msg", Some("chat")),
        ];
        let runs = split_act_runs(&events);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].acts.clicks[0].count, 4);
    }

    #[test]
    fn an_empty_stream_has_no_runs() {
        assert!(split_act_runs(&[]).is_empty());
        assert_eq!(no_input_ratio(&[], 0, 600_000), None);
    }

    #[test]
    fn no_input_ratio_is_the_complement_of_observed_coverage() {
        // One 60s burst plus one point click in a 600s slot: 61s covered.
        let mut burst = event(0, ActKind::Burst, None);
        burst.end_ms = Some(60_000);
        let events = vec![burst, click(300_000, "x", None)];
        let ratio = no_input_ratio(&events, 0, 600_000).expect("events exist");
        assert!(
            (ratio - (1.0 - 61_000.0 / 600_000.0)).abs() < 1e-6,
            "unexpected ratio {ratio}"
        );

        // Overlapping spans are counted once.
        let mut first = event(0, ActKind::Burst, None);
        first.end_ms = Some(100_000);
        let mut second = event(50_000, ActKind::Burst, None);
        second.end_ms = Some(150_000);
        let ratio = no_input_ratio(&[first, second], 0, 600_000).expect("events exist");
        assert!((ratio - 0.75).abs() < 1e-6, "unexpected ratio {ratio}");

        // A gap marker alone is not an input observation.
        let gap = event(1_000, ActKind::SignalGap, None);
        assert_eq!(no_input_ratio(&[gap], 0, 600_000), None);
    }

    #[test]
    fn merging_acts_keeps_the_worse_signal_and_one_tally_per_label() {
        let mut left = fold_acts(&[click(1_000, "a", None), click(2_000, "b", None)]);
        let right = Acts {
            keys: 5,
            submits: vec![Submit {
                at_ms: 500,
                kind: "return".to_owned(),
            }],
            clicks: vec![ClickTally {
                label: "a".to_owned(),
                count: 3,
            }],
            scrolls: 2,
            signal: ActsSignal::Unavailable,
        };
        left.merge(&right);
        assert_eq!(left.keys, 5);
        assert_eq!(left.scrolls, 2);
        assert_eq!(left.signal, ActsSignal::Unavailable);
        assert_eq!(left.submits[0].at_ms, 500);
        assert_eq!(
            left.clicks,
            vec![
                ClickTally {
                    label: "a".to_owned(),
                    count: 4,
                },
                ClickTally {
                    label: "b".to_owned(),
                    count: 1,
                },
            ]
        );
        assert!(!left.is_empty());
        assert!(Acts::default().is_empty());
    }

    #[test]
    fn the_acts_shape_serialises_every_field() {
        // Fixed shape: a reader must be able to tell "no keys" from "unknown".
        let json = serde_json::to_string(&Acts::default()).expect("serialises");
        assert_eq!(
            json,
            r#"{"keys":0,"submits":[],"clicks":[],"scrolls":0,"signal":"ok"}"#
        );
        let round: Acts = serde_json::from_str(&json).expect("round trips");
        assert_eq!(round, Acts::default());
    }

    #[test]
    fn materialized_acts_are_addressed_by_moment_id() {
        let frozen = MaterializedActs {
            runs: vec![MaterializedRun {
                id: "moment-2".to_owned(),
                acts: Acts {
                    keys: 9,
                    ..Acts::default()
                },
            }],
            no_input_ratio: Some(0.5),
        };
        let json = serde_json::to_string(&frozen).expect("serialises");
        let round: MaterializedActs = serde_json::from_str(&json).expect("round trips");
        assert_eq!(round, frozen);
        assert_eq!(round.acts_for("moment-2").map(|acts| acts.keys), Some(9));
        assert!(round.acts_for("moment-1").is_none());
    }
}
