//! Token estimation for context budgets.
//!
//! Every budget in the loop used to be a character count, which means the same
//! number bought three times as much English as Chinese. Nothing here is exact
//! — we do not have the model's tokenizer, and for a remote provider we never
//! will — so the estimate is deliberately biased **high**. Over-counting costs
//! a little unused window; under-counting silently overflows the context and
//! the model answers from a prompt whose head the runtime quietly dropped.

/// Non-dense characters per token. Latin text runs about four characters to a
/// BPE token across every tokenizer we target.
const LATIN_CHARS_PER_TOKEN: usize = 4;

/// Estimated tokens in `text`.
///
/// CJK and Hangul are counted one token per character. Real tokenizers manage
/// roughly one token per 1.3–1.7 hanzi, so this over-counts by up to ~40%; that
/// is the safe direction, see the module note.
#[must_use]
pub fn estimate_tokens(text: &str) -> usize {
    let mut dense = 0_usize;
    let mut latin = 0_usize;
    for ch in text.chars() {
        if is_dense_script(ch) {
            dense += 1;
        } else {
            latin += 1;
        }
    }
    dense + latin.div_ceil(LATIN_CHARS_PER_TOKEN)
}

/// Incremental form of [`estimate_tokens`] for callers growing a string one
/// character at a time.
///
/// The estimate is not linear in characters, so a caller that wants the longest
/// prefix within a budget cannot compute an offset — without this it would have
/// to re-measure the whole prefix per character, which is quadratic on the one
/// input that matters (a single enormous OCR line).
#[derive(Debug, Default, Clone, Copy)]
pub struct TokenCounter {
    dense: usize,
    latin: usize,
}

impl TokenCounter {
    /// Tokens counted so far. Agrees exactly with [`estimate_tokens`] over the
    /// same characters.
    #[must_use]
    pub fn tokens(self) -> usize {
        self.dense + self.latin.div_ceil(LATIN_CHARS_PER_TOKEN)
    }

    /// What [`Self::tokens`] would return after pushing `ch`.
    #[must_use]
    pub fn peek(self, ch: char) -> usize {
        let mut probe = self;
        probe.push(ch);
        probe.tokens()
    }

    pub fn push(&mut self, ch: char) {
        if is_dense_script(ch) {
            self.dense += 1;
        } else {
            self.latin += 1;
        }
    }
}

/// True for scripts that tokenize at roughly one token per character.
///
/// The ranges are deliberately coarse: this feeds a budget, not a renderer.
fn is_dense_script(ch: char) -> bool {
    matches!(ch as u32,
        0x3000..=0x303F   // CJK symbols and punctuation
        | 0x3040..=0x30FF // Hiragana, Katakana
        | 0x3400..=0x4DBF // CJK extension A
        | 0x4E00..=0x9FFF // CJK unified ideographs
        | 0xAC00..=0xD7AF // Hangul syllables
        | 0xF900..=0xFAFF // CJK compatibility ideographs
        | 0xFF00..=0xFFEF // Halfwidth and fullwidth forms
        | 0x20000..=0x2FA1F // CJK extensions B..F and compatibility supplement
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latin_runs_about_four_characters_to_a_token() {
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("abcde"), 2);
        assert_eq!(estimate_tokens(""), 0);
    }

    /// The whole point of the module: the same character count must not buy the
    /// same budget in both scripts.
    #[test]
    fn chinese_costs_far_more_than_latin_per_character() {
        let hanzi = "我今天下午在干嘛";
        assert_eq!(hanzi.chars().count(), 8);
        assert_eq!(estimate_tokens(hanzi), 8);
        assert_eq!(estimate_tokens("abcdefgh"), 2);
    }

    #[test]
    fn mixed_text_adds_both_halves() {
        // 4 hanzi + 8 latin characters ("app: Safari" is 11, trimmed here).
        assert_eq!(estimate_tokens("打开了浏览器abcdefgh"), 6 + 2);
    }

    /// A budget that under-counts overflows the window silently, so the
    /// estimate must never come in below a plain characters/4 floor.
    #[test]
    fn never_under_counts_the_latin_floor() {
        for text in ["", "x", "hello world", "我", "混合 mixed 文本"] {
            assert!(estimate_tokens(text) >= text.chars().count().div_ceil(4), "{text}");
        }
    }
}
