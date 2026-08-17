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
}
