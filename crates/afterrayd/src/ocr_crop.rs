//! Cropping OCR regions to the frontmost window, and dropping the fragments
//! that survive the crop by accident.
//!
//! OCR reads the whole screen, but a moment is about one window. On a measured
//! `WeChat` frame 58 of 123 regions (47%) came from outside the app window: the
//! menu bar, a weather widget, and text of background windows clipped at the
//! window edge (`Conversatio`, `ter`, `• Gi`). That app's own accessibility
//! tree has zero text nodes, so OCR is the only text source for apps like it
//! and the noise flows straight into cards. See
//! `docs/event-capture-v2-plan.md` §7.
//!
//! **Fail open is the rule here.** Every geometric input — the accessibility
//! snapshot, the window frame, the captured display's size — can be missing or
//! ambiguous, and a wrong crop deletes evidence that nothing else in the system
//! can recover. Whenever this module cannot answer with confidence it keeps
//! every region exactly as the worker produced it.
//!
//! Everything here is pure: fixed input, fixed output, no clock, no vault.

use afterray_models::OcrRegion;
use afterray_store::{
    accessibility_scope_tree,
    acts::{AxRect, window_node},
};

/// How close to the window edge a box has to be before it counts as touching
/// it. Accessibility window frames exclude the drop shadow but not every app's
/// own chrome padding, so an exact-equality test would never fire; two points
/// is under one physical pixel of slack on a Retina display.
const BOUNDARY_TOLERANCE_POINTS: f64 = 2.0;

/// Below this length a region that also touches the window boundary is read as
/// a neighbouring window clipped by the frontmost one rather than as UI text.
/// Short text *away* from the edge (`Issues`, `19`) is kept: length alone says
/// nothing, it is length plus position that identifies a clipped fragment.
const FRAGMENT_MAX_CHARS: usize = 8;

/// The captured display's logical size, in points.
///
/// Points, not pixels: the shim reports `SCDisplay.width`/`height`, which are
/// logical, and accessibility frames are in the same unit. The two would differ
/// by the backing scale factor on a Retina display if either were in pixels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DisplayPoints {
    width: f64,
    height: f64,
}

impl DisplayPoints {
    /// `None` for a degenerate size — a zero-width display cannot map a
    /// normalized box onto anything, and mapping it anyway would put every
    /// region at the origin.
    #[must_use]
    pub fn new(width: usize, height: usize) -> Option<Self> {
        let width = f64::from(u32::try_from(width).ok()?);
        let height = f64::from(u32::try_from(height).ok()?);
        (width > 0.0 && height > 0.0).then_some(Self { width, height })
    }
}

/// What the crop decided.
#[derive(Debug, Clone, PartialEq)]
pub struct Cropped {
    /// The regions to keep, in their original order.
    pub regions: Vec<OcrRegion>,
    /// How many the crop and the fragment filter removed between them. Zero
    /// means the caller must not rewrite anything.
    pub dropped: usize,
}

/// The frontmost window's frame, in global top-left screen points.
///
/// The snapshot is scoped to the frontmost application by construction, so the
/// first window-roled node in tree order is that application's window. `None`
/// whenever the snapshot will not parse, holds no window, or the window carries
/// no measurable geometry — each of those is a fail-open signal for the caller,
/// never a reason to guess a frame.
#[must_use]
pub fn frontmost_window_frame(snapshot: &[u8]) -> Option<AxRect> {
    let tree = accessibility_scope_tree(snapshot)?;
    let window = window_node(&tree, 0)?;
    tree.nodes.get(window)?.frame.filter(AxRect::is_measurable)
}

/// Drops the OCR regions that do not belong to the frontmost window.
///
/// Returns every input region untouched (`dropped: 0`) when any of the geometry
/// is missing or ambiguous:
///
/// - no window frame (no accessibility snapshot, no window node, no geometry);
/// - no display size (the shim never reported one);
/// - the window frame does not intersect the captured display's bounds, which
///   means the window is on another display and the frame's coordinates cannot
///   be compared with regions normalized against *this* one.
///
/// The fragment filter only runs on regions a successful crop decided to keep:
/// with no window frame there is no boundary to be clipped against, and length
/// on its own is not evidence of junk.
#[must_use]
pub fn crop_to_window(
    regions: Vec<OcrRegion>,
    window: Option<AxRect>,
    display: Option<DisplayPoints>,
) -> Cropped {
    let (Some(window), Some(display)) = (window, display) else {
        return Cropped {
            regions,
            dropped: 0,
        };
    };
    if !window.is_measurable() || !intersects_display(window, display) {
        return Cropped {
            regions,
            dropped: 0,
        };
    }
    let before = regions.len();
    let kept: Vec<OcrRegion> = regions
        .into_iter()
        .filter(|region| keeps_region(region, window, display))
        .collect();
    let dropped = before - kept.len();
    Cropped {
        regions: kept,
        dropped,
    }
}

/// The flat text for a set of regions, in the exact shape the Vision worker
/// produces it (`regions.map(\.text).joined(separator: "\n")`,
/// `apps/AfterRayNativeModelWorker/Sources/main.swift`). Keeping the two in
/// step is what lets the daemon rewrite the text after a crop without the FTS
/// row and the layout disagreeing about what was on screen.
#[must_use]
pub fn regions_text(regions: &[OcrRegion]) -> String {
    regions
        .iter()
        .map(|region| region.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

fn keeps_region(region: &OcrRegion, window: AxRect, display: DisplayPoints) -> bool {
    let rect = region_rect(region, display);
    let (x, y) = rect.center();
    if !window.contains(x, y) {
        return false;
    }
    let text = region.text.trim();
    if !carries_content(text) {
        return false;
    }
    !(text.chars().count() < FRAGMENT_MAX_CHARS && touches_boundary(rect, window))
}

/// Maps a Vision box onto global top-left screen points.
///
/// Vision's unit square has its origin at the **bottom** left and `y` is the
/// box's lower edge, so the top edge in screen coordinates is
/// `1 - (y + height)` scaled by the display height.
fn region_rect(region: &OcrRegion, display: DisplayPoints) -> AxRect {
    let width = f64::from(region.width) * display.width;
    let height = f64::from(region.height) * display.height;
    let left = f64::from(region.x) * display.width;
    let top = (1.0 - f64::from(region.y) - f64::from(region.height)) * display.height;
    AxRect::new(left, top, width, height)
}

/// Whether the window is on the display the regions were normalized against.
///
/// Accessibility coordinates are global and span every display, while the
/// captured display is assumed to sit at the global origin. A window with no
/// overlap at all is on some other display, and comparing it with these regions
/// would be comparing two different coordinate spaces.
fn intersects_display(window: AxRect, display: DisplayPoints) -> bool {
    window.x < display.width
        && window.y < display.height
        && window.x + window.width > 0.0
        && window.y + window.height > 0.0
}

fn touches_boundary(rect: AxRect, window: AxRect) -> bool {
    rect.x <= window.x + BOUNDARY_TOLERANCE_POINTS
        || rect.y <= window.y + BOUNDARY_TOLERANCE_POINTS
        || rect.x + rect.width >= window.x + window.width - BOUNDARY_TOLERANCE_POINTS
        || rect.y + rect.height >= window.y + window.height - BOUNDARY_TOLERANCE_POINTS
}

/// Whether a region holds anything a person could read as a word or a number.
///
/// Bullets, box-drawing, stray punctuation and the rare ideographs Vision emits
/// for a dense pixel blob (`㗊`) carry no meaning on their own. Digits do —
/// badge counts, prices and clocks are evidence — so a numeric region is kept.
fn carries_content(text: &str) -> bool {
    text.chars().any(is_content_char)
}

/// Rare ideographs are deliberately absent: `㗊` and its neighbours in the
/// extension blocks are what Vision returns when it cannot read a dense patch
/// of pixels, and a region made only of them says nothing. A rare character
/// inside real text is unaffected — one common character anywhere in the region
/// keeps the whole of it.
fn is_content_char(character: char) -> bool {
    if character.is_numeric() {
        return true;
    }
    if matches!(character,
        '\u{3040}'..='\u{30FF}'   // hiragana + katakana
        | '\u{4E00}'..='\u{9FFF}' // CJK unified ideographs
        | '\u{AC00}'..='\u{D7A3}' // hangul syllables
        | '\u{F900}'..='\u{FAFF}' // CJK compatibility ideographs
    ) {
        return true;
    }
    character.is_alphabetic() && (character as u32) < 0x2E80
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 1000x1000 display with a window inset 200pt from every edge keeps the
    /// arithmetic legible: a normalized coordinate is a per-mille of a point.
    const DISPLAY: (usize, usize) = (1000, 1000);

    fn display() -> Option<DisplayPoints> {
        DisplayPoints::new(DISPLAY.0, DISPLAY.1)
    }

    fn window() -> AxRect {
        AxRect::new(200.0, 200.0, 600.0, 600.0)
    }

    /// `y` is Vision's lower edge, measured up from the bottom of the image.
    fn region(text: &str, x: f32, y: f32, width: f32, height: f32) -> OcrRegion {
        OcrRegion {
            text: text.to_owned(),
            confidence: 0.9,
            x,
            y,
            width,
            height,
        }
    }

    /// Comfortably inside the window: screen box x 400..500, y 400..430.
    fn inside(text: &str) -> OcrRegion {
        region(text, 0.4, 0.57, 0.1, 0.03)
    }

    fn texts(cropped: &Cropped) -> Vec<&str> {
        cropped
            .regions
            .iter()
            .map(|region| region.text.as_str())
            .collect()
    }

    #[test]
    fn a_region_centred_outside_the_window_is_dropped() {
        let cropped = crop_to_window(
            vec![
                inside("Conversation with Alice"),
                region("Weather", 0.8, 0.9, 0.15, 0.03),
            ],
            Some(window()),
            display(),
        );
        assert_eq!(texts(&cropped), vec!["Conversation with Alice"]);
        assert_eq!(cropped.dropped, 1);
    }

    #[test]
    fn a_region_centred_inside_the_window_is_kept() {
        let cropped = crop_to_window(
            vec![inside("Conversation with Alice")],
            Some(window()),
            display(),
        );
        assert_eq!(texts(&cropped), vec!["Conversation with Alice"]);
        assert_eq!(cropped.dropped, 0);
    }

    /// The measured menu-bar case. Vision's `y` near 1 is the *top* of the
    /// screen, so without the flip this region would land at the bottom — well
    /// inside a window that occupies the middle of the display.
    #[test]
    fn vision_y_near_one_is_the_top_of_the_screen() {
        let menu_bar = region("File Edit View", 0.3, 0.97, 0.2, 0.02);
        let rect = region_rect(&menu_bar, display().unwrap());
        // f32 inputs, so compare within a point rather than exactly.
        assert!((rect.x - 300.0).abs() < 1.0, "{rect:?}");
        assert!((rect.y - 10.0).abs() < 1.0, "{rect:?}");
        assert!((rect.width - 200.0).abs() < 1.0, "{rect:?}");
        assert!((rect.height - 20.0).abs() < 1.0, "{rect:?}");
        let cropped = crop_to_window(vec![menu_bar], Some(window()), display());
        assert!(cropped.regions.is_empty());
        assert_eq!(cropped.dropped, 1);
    }

    #[test]
    fn a_region_with_no_letter_digit_or_cjk_is_dropped() {
        let cropped = crop_to_window(
            vec![inside("• "), inside("㗊"), inside("——|——")],
            Some(window()),
            display(),
        );
        assert!(cropped.regions.is_empty());
        assert_eq!(cropped.dropped, 3);
    }

    #[test]
    fn cjk_and_digits_are_content() {
        let cropped = crop_to_window(
            vec![inside("会话记录"), inside("19"), inside("Issues")],
            Some(window()),
            display(),
        );
        assert_eq!(texts(&cropped), vec!["会话记录", "19", "Issues"]);
        assert_eq!(cropped.dropped, 0);
    }

    /// A background window clipped by the frontmost one leaves a stub against
    /// the window edge. Screen box x 200..250 starts exactly on the window's
    /// left edge.
    #[test]
    fn a_short_fragment_against_the_window_edge_is_dropped() {
        let clipped = region("ter", 0.2, 0.57, 0.05, 0.03);
        let cropped = crop_to_window(vec![clipped], Some(window()), display());
        assert!(cropped.regions.is_empty());
        assert_eq!(cropped.dropped, 1);
    }

    /// The same stub, long enough to be a sentence rather than a shard, stays:
    /// the boundary is only evidence when the text is too short to judge.
    #[test]
    fn a_long_run_against_the_window_edge_is_kept() {
        let edge = region("Conversation with Alice", 0.2, 0.57, 0.05, 0.03);
        let cropped = crop_to_window(vec![edge], Some(window()), display());
        assert_eq!(texts(&cropped), vec!["Conversation with Alice"]);
        assert_eq!(cropped.dropped, 0);
    }

    #[test]
    fn short_text_away_from_the_edge_is_kept() {
        let cropped = crop_to_window(
            vec![inside("Issues"), inside("19")],
            Some(window()),
            display(),
        );
        assert_eq!(texts(&cropped), vec!["Issues", "19"]);
        assert_eq!(cropped.dropped, 0);
    }

    #[test]
    fn no_window_frame_keeps_everything() {
        let all = vec![inside("• "), region("Weather", 0.8, 0.9, 0.15, 0.03)];
        let cropped = crop_to_window(all.clone(), None, display());
        assert_eq!(cropped.regions, all);
        assert_eq!(cropped.dropped, 0);
    }

    #[test]
    fn no_display_size_keeps_everything() {
        let all = vec![inside("• "), region("Weather", 0.8, 0.9, 0.15, 0.03)];
        let cropped = crop_to_window(all.clone(), Some(window()), None);
        assert_eq!(cropped.regions, all);
        assert_eq!(cropped.dropped, 0);
    }

    #[test]
    fn a_degenerate_display_is_no_display() {
        assert_eq!(DisplayPoints::new(0, 900), None);
        assert_eq!(DisplayPoints::new(1440, 0), None);
    }

    #[test]
    fn an_unmeasurable_window_keeps_everything() {
        let all = vec![region("Weather", 0.8, 0.9, 0.15, 0.03)];
        let cropped = crop_to_window(
            all.clone(),
            Some(AxRect::new(200.0, 200.0, 0.0, 0.0)),
            display(),
        );
        assert_eq!(cropped.regions, all);
        assert_eq!(cropped.dropped, 0);
    }

    /// A window on the second display: its frame is past the captured
    /// display's right edge, so nothing here can be compared and everything
    /// survives.
    #[test]
    fn a_window_on_another_display_keeps_everything() {
        let all = vec![inside("Conversation with Alice"), inside("• ")];
        let cropped = crop_to_window(
            all.clone(),
            Some(AxRect::new(1000.0, 100.0, 600.0, 600.0)),
            display(),
        );
        assert_eq!(cropped.regions, all);
        assert_eq!(cropped.dropped, 0);
    }

    /// A window straddling the origin (negative x, as a display to the left
    /// puts it) still overlaps and is still croppable.
    #[test]
    fn a_window_overlapping_the_origin_still_crops() {
        let cropped = crop_to_window(
            vec![inside("Conversation with Alice")],
            Some(AxRect::new(-100.0, 200.0, 600.0, 600.0)),
            display(),
        );
        assert_eq!(texts(&cropped), vec!["Conversation with Alice"]);
    }

    #[test]
    fn no_regions_is_not_a_crop() {
        let cropped = crop_to_window(Vec::new(), Some(window()), display());
        assert!(cropped.regions.is_empty());
        assert_eq!(cropped.dropped, 0);
    }

    #[test]
    fn the_rebuilt_text_matches_the_workers_join() {
        let regions = vec![inside("Issues"), inside("19")];
        assert_eq!(regions_text(&regions), "Issues\n19");
        assert_eq!(regions_text(&[]), "");
    }

    #[test]
    fn the_frontmost_window_frame_comes_from_the_snapshot() {
        let snapshot = br#"{
            "applicationName":"WeChat",
            "root":{"role":"AXApplication",
                "frame":{"x":0,"y":0,"width":1440,"height":900},
                "children":[
                    {"role":"AXWindow",
                     "frame":{"x":120,"y":38,"width":1000,"height":760},
                     "children":[]}
                ]}
        }"#;
        assert_eq!(
            frontmost_window_frame(snapshot),
            Some(AxRect::new(120.0, 38.0, 1000.0, 760.0))
        );
    }

    #[test]
    fn a_snapshot_with_no_window_has_no_frame() {
        let snapshot = br#"{"root":{"role":"AXApplication","children":[]}}"#;
        assert_eq!(frontmost_window_frame(snapshot), None);
        assert_eq!(frontmost_window_frame(b"not json"), None);
    }

    #[test]
    fn a_window_without_geometry_has_no_frame() {
        let snapshot = br#"{"root":{"role":"AXWindow","children":[]}}"#;
        assert_eq!(frontmost_window_frame(snapshot), None);
    }
}
