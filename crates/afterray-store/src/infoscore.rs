//! Deterministic information-value scoring for slot-card lines.
//!
//! The T1 card holds far more screen text than any prompt budget can carry,
//! so something must decide which lines represent a run. Before this module
//! that decision was positional — the first lines of every run — and the
//! first lines of an application window are its navigation. Everything here
//! is classical corpus statistics: a line is worth inlining when it is rare
//! against the user's own history (IDF), carries identifier-shaped tokens,
//! and is not a near-duplicate of something already chosen.
//!
//! No model is involved. Every function is pure so tests can pin exact
//! selections, and the Visual Lab shares the behaviour of production.

use std::collections::{HashMap, HashSet};
use std::hash::{Hash as _, Hasher as _};

/// Document frequencies over the user's own slot history. `slots` is the
/// corpus size; a line or token seen in a large share of those slots is the
/// user's everyday chrome, whatever it says.
#[derive(Debug, Clone, Default)]
pub struct BackgroundStats {
    pub slots: u32,
    /// True when the scored slot itself has already been folded into the
    /// corpus (re-scoring history); its own contribution is subtracted so a
    /// line unique to the slot still counts as unique.
    pub corpus_includes_slot: bool,
    pub line_df: HashMap<String, u32>,
    pub token_df: HashMap<String, u32>,
}

impl BackgroundStats {
    #[must_use]
    pub fn empty() -> Self {
        Self::default()
    }

    fn effective_df(&self, df: u32) -> f64 {
        let df = if self.corpus_includes_slot {
            df.saturating_sub(1)
        } else {
            df
        };
        f64::from(df)
    }

    /// 0 (everyday chrome) … 1 (never seen before).
    #[must_use]
    pub fn token_idf(&self, token: &str) -> f64 {
        let total = f64::from(self.slots.max(1));
        let df = self.effective_df(self.token_df.get(token).copied().unwrap_or(0));
        ((total + 1.0) / (df + 1.0)).ln() / (total + 1.0).ln()
    }

    /// A whole line the history keeps repeating: menu bars, sidebars, tab
    /// strips. The threshold scales with corpus size so three sightings in
    /// a young corpus do not condemn a line forever.
    #[must_use]
    pub fn line_is_boilerplate(&self, dedup_key: &str) -> bool {
        if self.slots < 8 {
            return false; // cold start: not enough history to judge
        }
        let df = self.effective_df(self.line_df.get(dedup_key).copied().unwrap_or(0));
        df >= f64::from(self.slots) * 0.2 && df >= 4.0
    }
}

// ---------------------------------------------------------------- tokenizer

const ASCII_TOKEN_MAX_CHARS: usize = 32;

/// Mixed-script tokenizer: ASCII runs become lowercase word tokens, CJK runs
/// become character bigrams. Bigrams make Chinese countable without a
/// segmenter — enough for frequency statistics, which is all we do.
#[must_use]
pub fn tokenize(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut ascii = String::new();
    let mut cjk_prev: Option<char> = None;
    for c in text.chars() {
        if c.is_ascii_alphanumeric() || (ascii_joiner(c) && !ascii.is_empty()) {
            ascii.push(c.to_ascii_lowercase());
            cjk_prev = None;
            continue;
        }
        flush_ascii(&mut ascii, &mut tokens);
        if is_cjk(c) {
            if let Some(prev) = cjk_prev {
                tokens.push(format!("{prev}{c}"));
            }
            cjk_prev = Some(c);
        } else {
            cjk_prev = None;
        }
    }
    flush_ascii(&mut ascii, &mut tokens);
    tokens
}

fn flush_ascii(ascii: &mut String, tokens: &mut Vec<String>) {
    if ascii.is_empty() {
        return;
    }
    let token = std::mem::take(ascii);
    let token = token.trim_matches(|c: char| !c.is_ascii_alphanumeric());
    if token.chars().count() >= 2
        && token.chars().count() <= ASCII_TOKEN_MAX_CHARS
        && !token.chars().all(|c| c.is_ascii_digit())
    {
        tokens.push(token.to_owned());
    }
}

/// Characters that keep an identifier together as one token: `qwen3.5:4b`,
/// `fix/overlay-chrome-recovery`, `slot_summaries`.
const fn ascii_joiner(c: char) -> bool {
    matches!(c, '.' | ':' | '/' | '-' | '_')
}

const fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0x3040..=0x30FF | 0xAC00..=0xD7AF)
}

// ---------------------------------------------------------------- signals

/// Identifier-shaped: the token classes a user searches for days later, and
/// the ones a model must never re-spell. Detected by shape, not vocabulary.
#[must_use]
pub fn is_identifier_like(token: &str) -> bool {
    let chars = token.chars().count();
    if chars < 4 || chars > ASCII_TOKEN_MAX_CHARS {
        return false;
    }
    let has_alpha = token.chars().any(|c| c.is_ascii_alphabetic());
    if !has_alpha {
        return false;
    }
    let has_digit = token.chars().any(|c| c.is_ascii_digit());
    let has_join = token.contains(['/', ':', '.', '_', '-']);
    (has_digit && has_join)                       // qwen3.5:4b, v0.31.4
        || token.contains("://")                  // urls
        || token.contains('/')                    // paths, branches, repos
        || (has_join && chars >= 8)               // slot_summaries, kebab-names
}

/// One line's standing on its own, before corpus coverage is considered.
#[must_use]
pub fn line_base_score(line: &str, background: &BackgroundStats, frames: u32) -> f64 {
    let tokens = tokenize(line);
    if tokens.is_empty() {
        return 0.0;
    }
    let idf_sum: f64 = tokens.iter().map(|t| background.token_idf(t)).sum();
    // Sub-linear in length: a paragraph should beat a label, but not by the
    // ratio of their character counts.
    let mut score = idf_sum / (tokens.len() as f64).sqrt();
    if tokens.iter().any(|t| is_identifier_like(t)) {
        score *= 1.6;
    }
    // Persistence × rarity: a line that stayed on screen across many frames
    // and is rare in history is the document being worked on. (The other
    // diagonal — persistent and common — is chrome, killed by IDF already.)
    if frames >= 3 {
        score *= 1.3;
    }
    score
}

// ---------------------------------------------------------------- near-dup

const SHINGLE: usize = 3;
const SIGNATURE: usize = 64;
const BANDS: usize = 16; // × 4 rows

/// MinHash index over character 3-gram shingles, with LSH banding so lookup
/// does not compare against every stored line. Catches what exact dedup
/// cannot: the same sentence re-captured with shifted line breaks or one
/// OCR-mangled character.
#[derive(Debug, Default)]
pub struct NearDupIndex {
    buckets: HashMap<(usize, u64), Vec<usize>>,
    signatures: Vec<[u64; SIGNATURE]>,
}

impl NearDupIndex {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Inserts and returns `Some(existing)` when a stored line is close
    /// enough (est. Jaccard ≥ ~0.7) to make this one redundant.
    pub fn insert(&mut self, line: &str) -> Option<usize> {
        let sig = signature(line)?;
        let mut candidates: HashSet<usize> = HashSet::new();
        let mut keys = [(0_usize, 0_u64); BANDS];
        for (band, key) in keys.iter_mut().enumerate() {
            let rows = &sig[band * (SIGNATURE / BANDS)..(band + 1) * (SIGNATURE / BANDS)];
            let mut hasher = std::collections::hash_map::DefaultHasher::new();
            rows.hash(&mut hasher);
            *key = (band, hasher.finish());
            if let Some(ids) = self.buckets.get(key) {
                candidates.extend(ids.iter().copied());
            }
        }
        for &candidate in &candidates {
            let shared = sig
                .iter()
                .zip(self.signatures[candidate].iter())
                .filter(|(a, b)| a == b)
                .count();
            if shared * 10 >= SIGNATURE * 7 {
                return Some(candidate);
            }
        }
        let id = self.signatures.len();
        self.signatures.push(sig);
        for key in keys {
            self.buckets.entry(key).or_default().push(id);
        }
        None
    }
}

fn signature(line: &str) -> Option<[u64; SIGNATURE]> {
    let chars: Vec<char> = line
        .chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(|c| c.to_lowercase())
        .collect();
    if chars.len() < SHINGLE + 1 {
        return None; // too short to shingle; exact dedup owns this case
    }
    let mut sig = [u64::MAX; SIGNATURE];
    for window in chars.windows(SHINGLE) {
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        window.hash(&mut hasher);
        let base = hasher.finish();
        for (i, slot) in sig.iter_mut().enumerate() {
            // Cheap universal-ish family: mix the base hash per permutation.
            let mixed = (base ^ SEEDS[i]).wrapping_mul(0x9E37_79B9_7F4A_7C15);
            if mixed < *slot {
                *slot = mixed;
            }
        }
    }
    Some(sig)
}

/// Fixed odd seeds; values are arbitrary but must never change across a
/// session, or signatures stop being comparable.
static SEEDS: [u64; SIGNATURE] = {
    let mut seeds = [0_u64; SIGNATURE];
    let mut i = 0;
    while i < SIGNATURE {
        seeds[i] = 0x517C_C1B7_2722_0A95_u64
            .wrapping_mul(i as u64 + 1)
            .wrapping_add(0x2545_F491_4F6C_DD1D);
        i += 1;
    }
    seeds
};

// ---------------------------------------------------------------- selection

/// One run's candidate lines for selection.
pub struct RunCandidates<'a> {
    pub lines: &'a [String],
    /// Frames each line stayed visible; parallel to `lines`, may be empty.
    pub frames: &'a [u32],
}

/// Greedy budgeted selection maximising covered token IDF — a submodular
/// objective, so greedy is within (1 − 1/e) of optimal and redundancy
/// suppresses itself: the second copy of a token adds nothing.
///
/// Guarantees, in order:
/// 1. every run keeps its single best line (coverage floor),
/// 2. remaining budget flows to marginal information per character,
///    wherever it lives — a fragmented half hour no longer starves.
///
/// Returns selected indices per run, ascending (original screen order).
#[must_use]
pub fn select_lines(
    runs: &[RunCandidates<'_>],
    background: &BackgroundStats,
    budget_chars: usize,
    per_run_cap_chars: usize,
) -> Vec<Vec<usize>> {
    struct Candidate {
        run: usize,
        index: usize,
        cost: usize,
        tokens: Vec<String>,
        base: f64,
        /// Near-duplicate of an earlier candidate. Excluded from the global
        /// pass, but still allowed as a run's floor line: the floor exists so
        /// no run is invisible, and that promise outranks redundancy.
        dup: bool,
    }

    let mut candidates: Vec<Candidate> = Vec::new();
    let mut near_dup = NearDupIndex::new();
    for (run_index, run) in runs.iter().enumerate() {
        for (line_index, line) in run.lines.iter().enumerate() {
            let frames = run.frames.get(line_index).copied().unwrap_or(1);
            let key = crate::slot::dedup_key_of(line);
            if background.line_is_boilerplate(&key) {
                continue;
            }
            let dup = near_dup.insert(line).is_some();
            let cost = line.chars().count().max(1);
            candidates.push(Candidate {
                run: run_index,
                index: line_index,
                cost,
                tokens: tokenize(line),
                base: line_base_score(line, background, frames),
                dup,
            });
        }
    }

    let mut selected: Vec<Vec<usize>> = vec![Vec::new(); runs.len()];
    let mut run_used: Vec<usize> = vec![0; runs.len()];
    let mut budget = budget_chars;
    let mut covered: HashSet<String> = HashSet::new();
    let mut taken: Vec<bool> = vec![false; candidates.len()];

    let marginal = |candidate: &Candidate, covered: &HashSet<String>| -> f64 {
        let fresh: f64 = candidate
            .tokens
            .iter()
            .filter(|token| !covered.contains(*token))
            .map(|token| background.token_idf(token))
            .sum();
        // `base` keeps identifier and persistence bonuses alive even when
        // most tokens are covered; fresh coverage dominates otherwise.
        fresh + candidate.base * 0.25
    };

    let commit = |candidate_id: usize,
                      candidates: &[Candidate],
                      taken: &mut Vec<bool>,
                      selected: &mut Vec<Vec<usize>>,
                      run_used: &mut Vec<usize>,
                      budget: &mut usize,
                      covered: &mut HashSet<String>| {
        let candidate = &candidates[candidate_id];
        taken[candidate_id] = true;
        selected[candidate.run].push(candidate.index);
        run_used[candidate.run] += candidate.cost;
        *budget = budget.saturating_sub(candidate.cost);
        covered.extend(candidate.tokens.iter().cloned());
    };

    // Pass 1 — coverage floor: each run's best affordable line. A unique
    // line beats a near-duplicate at equal footing; a run whose only lines
    // are near-duplicates still keeps one.
    let mut floor: Vec<Option<usize>> = vec![None; runs.len()];
    for (id, candidate) in candidates.iter().enumerate() {
        let slot = &mut floor[candidate.run];
        let better = slot.is_none_or(|held: usize| {
            let held = &candidates[held];
            match (held.dup, candidate.dup) {
                (true, false) => true,  // a unique line always beats a duplicate
                (false, true) => false,
                _ => candidate.base > held.base,
            }
        });
        if better {
            *slot = Some(id);
        }
    }
    let mut floor_ids: Vec<usize> = floor.into_iter().flatten().collect();
    floor_ids.sort_by(|&a, &b| {
        candidates[b]
            .base
            .partial_cmp(&candidates[a].base)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    for id in floor_ids {
        if candidates[id].cost <= budget {
            commit(
                id,
                &candidates,
                &mut taken,
                &mut selected,
                &mut run_used,
                &mut budget,
                &mut covered,
            );
        }
    }

    // Pass 2 — greedy marginal gain per character.
    loop {
        let mut best: Option<(usize, f64)> = None;
        for (id, candidate) in candidates.iter().enumerate() {
            if taken[id]
                || candidate.dup
                || candidate.cost > budget
                || run_used[candidate.run] + candidate.cost > per_run_cap_chars
            {
                continue;
            }
            let ratio = marginal(candidate, &covered) / candidate.cost as f64;
            if best.is_none_or(|(_, held)| ratio > held) {
                best = Some((id, ratio));
            }
        }
        let Some((id, ratio)) = best else { break };
        if ratio <= 0.000_1 {
            break; // nothing left adds information
        }
        commit(
            id,
            &candidates,
            &mut taken,
            &mut selected,
            &mut run_used,
            &mut budget,
            &mut covered,
        );
    }

    for lines in &mut selected {
        lines.sort_unstable();
    }
    selected
}

// ---------------------------------------------------------------- keyness

/// Dunning's log-likelihood (G²) of a token in this slot against the
/// background corpus: what is *characteristically here*. Feeds the entity
/// candidate list — deterministic strings the model may cite but not spell.
#[must_use]
pub fn entity_candidates(
    slot_token_counts: &HashMap<String, u32>,
    background: &BackgroundStats,
    cap: usize,
) -> Vec<String> {
    let slot_total: f64 = slot_token_counts.values().map(|&c| f64::from(c)).sum();
    let corpus_total: f64 = f64::from(background.slots.max(1));
    let mut scored: Vec<(f64, &String)> = slot_token_counts
        .iter()
        .filter(|(token, count)| **count >= 2 && is_identifier_like(token))
        .map(|(token, &count)| {
            let observed = f64::from(count);
            let df = background.effective_df(
                background.token_df.get(token).copied().unwrap_or(0),
            );
            let expected =
                (observed + df) * slot_total / (slot_total + corpus_total).max(1.0);
            let g2 = if expected > 0.0 && observed > expected {
                2.0 * observed * (observed / expected).ln()
            } else {
                0.0
            };
            (g2, token)
        })
        .filter(|(g2, _)| *g2 > 0.0)
        .collect();
    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
    scored
        .into_iter()
        .take(cap)
        .map(|(_, token)| token.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn background(slots: u32, tokens: &[(&str, u32)], lines: &[(&str, u32)]) -> BackgroundStats {
        BackgroundStats {
            slots,
            corpus_includes_slot: false,
            line_df: lines
                .iter()
                .map(|(k, v)| (crate::slot::dedup_key_of(k), *v))
                .collect(),
            token_df: tokens.iter().map(|(k, v)| ((*k).to_owned(), *v)).collect(),
        }
    }

    #[test]
    fn tokenizer_keeps_identifiers_whole_and_bigrams_cjk() {
        let tokens = tokenize("跑通 qwen3.5:4b 的 fix/overlay-chrome-recovery 分支");
        assert!(tokens.contains(&"qwen3.5:4b".to_owned()), "{tokens:?}");
        assert!(
            tokens.contains(&"fix/overlay-chrome-recovery".to_owned()),
            "{tokens:?}"
        );
        assert!(tokens.contains(&"跑通".to_owned()), "{tokens:?}");
        assert!(tokens.contains(&"分支".to_owned()), "{tokens:?}");
    }

    #[test]
    fn identifier_shapes_are_recognised() {
        for good in [
            "qwen3.5:4b",
            "fix/overlay-chrome-recovery",
            "https://x.com/home",
            "slot_summaries",
            "v0.31.4",
            "docs/evals",
        ] {
            assert!(is_identifier_like(good), "{good}");
        }
        for bad in ["the", "hello", "12345", "工作", "New", "chat"] {
            assert!(!is_identifier_like(bad), "{bad}");
        }
    }

    #[test]
    fn common_history_lines_score_below_fresh_content() {
        let bg = background(
            100,
            &[("new", 90), ("chat", 90), ("projects", 88)],
            &[("New chat", 90)],
        );
        let chrome = line_base_score("New chat", &bg, 30);
        let content =
            line_base_score("error: GOP header still failing the IVF length check", &bg, 2);
        assert!(
            content > chrome * 3.0,
            "content {content} should dwarf chrome {chrome}"
        );
    }

    #[test]
    fn boilerplate_lines_need_history_before_they_are_condemned() {
        let young = background(4, &[], &[("New chat", 3)]);
        assert!(!young.line_is_boilerplate(&crate::slot::dedup_key_of("New chat")));
        let old = background(100, &[], &[("New chat", 60)]);
        assert!(old.line_is_boilerplate(&crate::slot::dedup_key_of("New chat")));
        assert!(!old.line_is_boilerplate(&crate::slot::dedup_key_of("unique line")));
    }

    #[test]
    fn near_dup_catches_ocr_jitter_but_not_different_lines() {
        let mut index = NearDupIndex::new();
        assert!(index
            .insert("The daemon should own storage while the interface stays replaceable")
            .is_none());
        assert!(index
            .insert("The daemon should own storage while the 1nterface stays replaceable")
            .is_some());
        assert!(index
            .insert("Completely different sentence about timeline scrolling performance")
            .is_none());
    }

    #[test]
    fn selection_prefers_information_over_position() {
        // Run 0 opens with chrome; the content sits later. Positional
        // selection took the chrome; score-based must not.
        let run0 = vec![
            "New chat".to_owned(),
            "Projects".to_owned(),
            "为什么 Agent 调用工具都失败了，检查 harness 和 tool call 实现".to_owned(),
        ];
        let run1 = vec!["cargo test -p afterrayd --bin afterrayd 全部通过".to_owned()];
        let bg = background(
            50,
            &[("new", 45), ("chat", 45), ("projects", 40)],
            &[("New chat", 45), ("Projects", 40)],
        );
        let picked = select_lines(
            &[
                RunCandidates {
                    lines: &run0,
                    frames: &[],
                },
                RunCandidates {
                    lines: &run1,
                    frames: &[],
                },
            ],
            &bg,
            200,
            150,
        );
        assert!(picked[0].contains(&2), "{picked:?}");
        assert!(!picked[0].contains(&0), "chrome selected: {picked:?}");
        assert_eq!(picked[1], vec![0]);
    }

    #[test]
    fn every_run_keeps_its_best_line_under_pressure() {
        let runs: Vec<Vec<String>> = (0..6)
            .map(|i| vec![format!("独立线索{i} unique-work-item-{i}/detail")])
            .collect();
        let candidates: Vec<RunCandidates<'_>> = runs
            .iter()
            .map(|lines| RunCandidates { lines, frames: &[] })
            .collect();
        let picked = select_lines(&candidates, &BackgroundStats::empty(), 400, 100);
        for (run, indices) in picked.iter().enumerate() {
            assert_eq!(indices.len(), 1, "run {run} lost its floor line");
        }
    }

    #[test]
    fn selection_respects_budget_and_cap() {
        let lines: Vec<String> = (0..50)
            .map(|i| format!("line-{i} with some distinct content token{i}"))
            .collect();
        let picked = select_lines(
            &[RunCandidates {
                lines: &lines,
                frames: &[],
            }],
            &BackgroundStats::empty(),
            300,
            200,
        );
        let total: usize = picked[0]
            .iter()
            .map(|&i| lines[i].chars().count())
            .sum();
        assert!(total <= 200, "per-run cap violated: {total}");
    }

    #[test]
    fn entity_candidates_rank_slot_specific_identifiers() {
        let mut counts = HashMap::new();
        counts.insert("qwen3.5:4b".to_owned(), 6_u32);
        counts.insert("x.com/home".to_owned(), 5); // constant background presence
        counts.insert("the".to_owned(), 40);
        counts.insert("工作".to_owned(), 9);
        let bg = background(80, &[("x.com/home", 70), ("the", 80)], &[]);
        let picked = entity_candidates(&counts, &bg, 4);
        assert_eq!(picked.first().map(String::as_str), Some("qwen3.5:4b"));
        assert!(!picked.contains(&"the".to_owned()));
        assert!(!picked.contains(&"工作".to_owned()), "not identifier-shaped");
    }
}
