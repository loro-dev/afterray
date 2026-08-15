//! Makes CJK text reachable through FTS5.
//!
//! FTS5's `unicode61` tokenizer splits on punctuation and whitespace, which is
//! everything Latin script needs and nothing Chinese, Japanese, or Kana needs:
//! a whole run of Han characters carries no separators, so it lands in the
//! index as one enormous token. `搜索` inside `今天的搜索结果` was therefore
//! unfindable — the only query that could ever match was the full run,
//! verbatim.
//!
//! Rather than depend on a custom tokenizer, both sides of the index are
//! folded through the same function here: text is rewritten into overlapping
//! bigrams before it is stored, and a query is rewritten into the phrase of
//! bigrams that a substring of the original text would have produced. Matching
//! a bigram phrase is equivalent to matching the substring.
//!
//! ```text
//! 会议纪要  →  index: "会议 议纪 纪要 要"   query: "会议 议纪 纪要"
//! ```
//!
//! Every run also emits its **last character alone**. That single unigram does
//! two jobs: it makes one-character queries findable at the end of a run (a
//! bare `会` cannot be the first half of any bigram in `开会`), and because it
//! is never a bigram it fences one run off from the next, so a phrase can
//! never straddle the boundary between two runs that happened to be adjacent.

/// Characters whose scripts are written without spaces, so FTS5 cannot break
/// them apart on its own. Hangul is deliberately absent: Korean is written with
/// spaces between words and tokenizes correctly already.
///
/// `々`, `〆` and `〇` have to be in here even though they live in the
/// punctuation block. They stand in for an ideograph mid-word — `人々`, `時々`,
/// `二〇二五` — and Rust calls them alphabetic, so leaving them out did not just
/// split the run, it fed the halves to the Latin path as separate `AND` terms.
/// `時々` then matched any text holding a 時 and a 々 anywhere.
fn is_scriptio_continua(character: char) -> bool {
    matches!(u32::from(character),
        0x3005..=0x3007        // 々 iteration, 〆 closing, 〇 ideographic zero
        | 0x3040..=0x30FF      // hiragana, katakana
        | 0x3400..=0x4DBF      // CJK unified ideographs extension A
        | 0x4E00..=0x9FFF      // CJK unified ideographs
        | 0xF900..=0xFAFF      // CJK compatibility ideographs
        | 0x20000..=0x2FA1F    // extensions B–F, compatibility supplement
    )
}

/// Rewrites text into the form that actually goes into `evidence_fts`.
///
/// Latin text passes through untouched; unsegmented runs become bigrams. Runs
/// are also fenced with spaces so a mixed `abc中文` no longer tokenizes as one
/// word.
#[must_use]
pub fn index_text(text: &str) -> String {
    let mut folded = String::with_capacity(text.len() * 2);
    let mut run: Vec<char> = Vec::new();

    for character in text.chars() {
        if is_scriptio_continua(character) {
            run.push(character);
            continue;
        }
        flush_run(&mut run, &mut folded);
        folded.push(character);
    }
    flush_run(&mut run, &mut folded);
    folded
}

fn flush_run(run: &mut Vec<char>, out: &mut String) {
    if run.is_empty() {
        return;
    }
    if !out.is_empty() && !out.ends_with(' ') {
        out.push(' ');
    }
    for gram in run_grams(run) {
        out.push_str(&gram);
        out.push(' ');
    }
    run.clear();
}

/// `[会, 议, 纪, 要]` → `["会议", "议纪", "纪要", "要"]`.
fn run_grams(run: &[char]) -> Vec<String> {
    if run.len() == 1 {
        return vec![run[0].to_string()];
    }
    let mut grams: Vec<String> = run
        .windows(2)
        .map(|pair| pair.iter().collect::<String>())
        .collect();
    // The fence, and the only way a run's final character is reachable alone.
    grams.push(run[run.len() - 1].to_string());
    grams
}

/// Turns what the user typed into an FTS5 `MATCH` expression.
///
/// Returns `None` when nothing searchable is left, so callers report "no
/// matches" instead of handing `SQLite` a query it will reject. Every term is
/// quoted, which is what keeps FTS5 operators the user did not mean to type
/// (`AND`, `foo-bar`, a lone `"`) from being read as syntax — or from raising
/// an error that silently turned the whole search into a semantic guess.
///
/// **Only whitespace separates terms.** Words joined by punctuation are one
/// phrase, because that is what the user typed and what they will look for on
/// screen: `retry-count` has to mean "these two, in this order, touching", not
/// "a retry somewhere and a count somewhere". FTS5 drops the hyphen when it
/// indexes, so the phrase is how the adjacency survives.
#[must_use]
pub fn match_query(query: &str) -> Option<String> {
    let mut terms: Vec<String> = Vec::new();
    let mut run: Vec<char> = Vec::new();
    let mut word = String::new();
    let mut phrase: Vec<String> = Vec::new();

    for character in query.chars() {
        if is_scriptio_continua(character) {
            // A CJK run cannot join the phrase around it: its own fence unigram
            // sits between the two, so no phrase could span them anyway.
            end_word(&mut word, &mut phrase);
            push_phrase_term(&mut phrase, &mut terms);
            run.push(character);
        } else if character.is_alphanumeric() || character == '_' || character == '\'' {
            push_run_term(&mut run, &mut terms);
            word.push(character);
        } else if character.is_whitespace() {
            end_word(&mut word, &mut phrase);
            push_phrase_term(&mut phrase, &mut terms);
            push_run_term(&mut run, &mut terms);
        } else {
            // Punctuation ends the word but holds the phrase open.
            end_word(&mut word, &mut phrase);
            push_run_term(&mut run, &mut terms);
        }
    }
    end_word(&mut word, &mut phrase);
    push_phrase_term(&mut phrase, &mut terms);
    push_run_term(&mut run, &mut terms);

    if terms.is_empty() {
        return None;
    }
    Some(terms.join(" AND "))
}

fn end_word(word: &mut String, phrase: &mut Vec<String>) {
    if word.is_empty() {
        return;
    }
    phrase.push(word.clone());
    word.clear();
}

fn push_phrase_term(phrase: &mut Vec<String>, terms: &mut Vec<String>) {
    if phrase.is_empty() {
        return;
    }
    // One quoted string either way; FTS5 reads several tokens inside the quotes
    // as a phrase, which is exactly the adjacency the punctuation implied.
    terms.push(quote(&phrase.join(" ")));
    phrase.clear();
}

fn push_run_term(run: &mut Vec<char>, terms: &mut Vec<String>) {
    if run.is_empty() {
        return;
    }
    if run.len() == 1 {
        // A lone character is only ever the head of a bigram or a run's final
        // unigram; a prefix match reaches both.
        terms.push(format!("{}*", quote(&run[0].to_string())));
    } else {
        // Consecutive positions, so the phrase means "this exact substring".
        let phrase = run
            .windows(2)
            .map(|pair| pair.iter().collect::<String>())
            .collect::<Vec<_>>()
            .join(" ");
        terms.push(quote(&phrase));
    }
    run.clear();
}

fn quote(term: &str) -> String {
    format!("\"{}\"", term.replace('"', "\"\""))
}

#[cfg(test)]
mod tests {
    use super::{index_text, match_query};

    #[test]
    fn latin_text_is_left_alone() {
        assert_eq!(index_text("hello world"), "hello world");
        assert_eq!(
            match_query("hello world"),
            Some("\"hello\" AND \"world\"".into())
        );
    }

    #[test]
    fn cjk_runs_become_bigrams_plus_a_closing_unigram() {
        assert_eq!(index_text("会议纪要"), "会议 议纪 纪要 要 ");
        assert_eq!(index_text("会"), "会 ");
    }

    #[test]
    fn mixed_scripts_are_fenced_so_they_tokenize_apart() {
        assert_eq!(index_text("abc中文"), "abc 中文 文 ");
        assert_eq!(index_text("中文abc"), "中文 文 abc");
    }

    /// The whole point: a substring query has to reach text it sits inside.
    #[test]
    fn a_cjk_substring_query_is_a_phrase_of_the_same_bigrams() {
        let indexed = index_text("今天的会议纪要写完了");
        let query = match_query("会议纪要").unwrap();
        assert_eq!(query, "\"会议 议纪 纪要\"");
        for gram in ["会议", "议纪", "纪要"] {
            assert!(indexed.contains(gram), "{indexed} is missing {gram}");
        }
    }

    #[test]
    fn one_character_queries_use_a_prefix_so_run_endings_still_match() {
        assert_eq!(match_query("会"), Some("\"会\"*".into()));
        // 会 is the run's last character, reachable only as the lone unigram.
        assert!(index_text("开会").split(' ').any(|token| token == "会"));
    }

    #[test]
    fn fts_syntax_the_user_typed_is_quoted_not_obeyed() {
        assert_eq!(match_query("AND"), Some("\"AND\"".into()));
        assert_eq!(match_query("say \"hi\""), Some("\"say\" AND \"hi\"".into()));
    }

    /// `retry-count` is one thing the user saw, not two things they want
    /// co-located. Only whitespace is allowed to split terms.
    #[test]
    fn punctuation_binds_words_into_a_phrase() {
        assert_eq!(match_query("retry-count"), Some("\"retry count\"".into()));
        assert_eq!(match_query("a*b"), Some("\"a b\"".into()));
        assert_eq!(match_query("v1.2.3"), Some("\"v1 2 3\"".into()));
        // Whitespace still separates, even with punctuation next to it.
        assert_eq!(
            match_query("build, retry"),
            Some("\"build\" AND \"retry\"".into())
        );
    }

    /// The iteration mark is a stand-in for the ideograph before it, so it
    /// belongs to the run. Treated as Latin it split `時々` into two terms that
    /// matched a 時 and a 々 anywhere in the same evidence row.
    #[test]
    fn iteration_marks_stay_inside_the_run() {
        assert_eq!(match_query("時々"), Some("\"時々\"".into()));
        assert_eq!(match_query("人々"), Some("\"人々\"".into()));
        assert_eq!(match_query("二〇二五"), Some("\"二〇 〇二 二五\"".into()));
        assert_eq!(index_text("時々"), "時々 々 ");
    }

    /// Both fixes are the same promise: a hit has the query in it, contiguously.
    #[test]
    fn non_adjacent_characters_do_not_match() {
        // 時 and 々 both occur, never touching.
        let scattered = index_text("時計と長々しい話");
        assert!(!scattered.contains("時々"));
        assert_eq!(match_query("時々"), Some("\"時々\"".into()));
        // And where they do touch, the bigram is there to be found.
        assert!(index_text("時々雨が降る").contains("時々"));
    }

    #[test]
    fn a_query_with_nothing_searchable_matches_nothing() {
        assert_eq!(match_query("   "), None);
        assert_eq!(match_query("***"), None);
        assert_eq!(match_query(""), None);
    }

    #[test]
    fn mixed_query_keeps_both_halves() {
        assert_eq!(
            match_query("Figma 设计稿"),
            Some("\"Figma\" AND \"设计 计稿\"".into())
        );
    }
}
