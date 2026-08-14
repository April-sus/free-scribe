//! Transcript processing, ported from the macOS app's `Cleanup.swift`.
//!
//! Two deliberate implementation differences from the Swift original, because
//! Rust's `regex` crate has neither lookaround nor backreferences:
//!
//! * protecting apostrophes and hyphens inside words is done by walking the
//!   characters rather than with `(?<=\p{L})['’](?=\p{L})`;
//! * collapsing repeated words is done over a word list rather than with
//!   `\b(\w+)(?:\s+\1\b)+`.
//!
//! Both produce the same output. The test suite mirrors the Swift one case for
//! case so any divergence shows up as a failure rather than a surprise.

use regex::{NoExpand, Regex};
use std::sync::LazyLock;

/// Placeholders that survive the punctuation strip, standing in for characters
/// that are part of a word rather than punctuation around it.
const APOSTROPHE_HOLD: char = '\u{FFFC}';
const HYPHEN_HOLD: char = '\u{FFFD}';

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DictationStyle {
    /// Exactly what Whisper heard, fillers and all.
    Verbatim,
    /// Verbatim plus the NAPLAN/NESA scribe rules for the Writing test.
    Scribe,
    /// Strips every filler by rule. No judgement involved.
    Tidy,
    /// Decides filler by filler using a language model.
    Polished,
}

impl DictationStyle {
    pub const ALL: [DictationStyle; 4] = [
        DictationStyle::Verbatim,
        DictationStyle::Scribe,
        DictationStyle::Tidy,
        DictationStyle::Polished,
    ];

    pub fn label(self) -> &'static str {
        match self {
            DictationStyle::Verbatim => "Verbatim",
            DictationStyle::Scribe => "Scribe (NAPLAN rules)",
            DictationStyle::Tidy => "Remove every filler",
            DictationStyle::Polished => "Decide filler by filler",
        }
    }

    pub fn detail(self) -> &'static str {
        match self {
            DictationStyle::Verbatim => "Every word as spoken, including \"um\" and \"uh\".",
            DictationStyle::Scribe => {
                "Word for word in lower case, with no punctuation the student did not dictate. \
                 Every mark needs the word \"command\" in front — \"command comma\", \
                 \"command full stop\", \"command new paragraph\", \"command capital y\". \
                 Nothing is added, removed or improved."
            }
            DictationStyle::Tidy => {
                "Strips all \"um\", \"uh\", stray \"you know\" and repeated words by rule. \
                 Instant, but it judges nothing."
            }
            DictationStyle::Polished => {
                "Keeps the \"um\"s you meant and drops the ones that were only stalling. \
                 Also fixes false starts and punctuation."
            }
        }
    }
}

/// Every mark the student can dictate, each reached only via "command …".
/// Longest phrases first so "exclamation mark" is not shadowed by a shorter entry.
pub const DICTATED_MARKS: &[(&str, &str)] = &[
    ("open parenthesis", "("),
    ("close parenthesis", ")"),
    ("exclamation point", "!"),
    ("exclamation mark", "!"),
    ("quotation mark", "\""),
    ("question mark", "?"),
    ("next paragraph", "\n\n"),
    ("new paragraph", "\n\n"),
    ("open bracket", "("),
    ("close bracket", ")"),
    ("close quote", "\""),
    ("open quote", "\""),
    ("apostrophe", "'"),
    ("semicolon", ";"),
    ("new line", "\n"),
    ("full stop", "."),
    ("ellipsis", "…"),
    ("asterisk", "*"),
    ("fullstop", "."),
    ("unquote", "\""),
    ("period", "."),
    ("hyphen", "-"),
    ("comma", ","),
    ("colon", ":"),
    ("quote", "\""),
    ("slash", "/"),
    ("dash", "-"),
];

static MARK_PATTERNS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    DICTATED_MARKS
        .iter()
        .map(|(spoken, mark)| {
            let pattern = format!(r"\bcommand {}\b", regex::escape(spoken));
            (Regex::new(&pattern).expect("mark pattern"), *mark)
        })
        .collect()
});

static NON_WORD: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^\p{L}\p{N}\s\x{FFFC}\x{FFFD}]").unwrap());

/// Applies the style. `Polished` has no local model on Windows yet, so it falls
/// back to the deterministic pass — the same behaviour macOS has when Apple
/// Intelligence is switched off.
pub fn apply(text: &str, style: DictationStyle, spoken_capitals: bool) -> String {
    match style {
        DictationStyle::Verbatim => text.to_string(),
        // Never routed through a language model: under the scribe rules, anything
        // that could suggest a word or improve the text is a breach.
        DictationStyle::Scribe => scribed(text, spoken_capitals),
        DictationStyle::Tidy | DictationStyle::Polished => tidied(text),
    }
}

// MARK: NAPLAN / NESA scribe rules

/// Word for word in the student's own language, printed in lower case, with no
/// punctuation except what they dictated.
///
/// Fillers, repeats and false starts are all kept deliberately — removing them
/// would be improving the student's performance rather than providing access.
pub fn scribed(text: &str, spoken_capitals: bool) -> String {
    let lowered = text.to_lowercase();

    // Apostrophes and hyphens inside a word are part of its spelling, and the
    // student is marked on spelling — so those survive the punctuation strip.
    let held = hold_intraword_marks(&lowered);

    // Everything Whisper punctuated for them goes.
    let mut result = NON_WORD.replace_all(&held, " ").into_owned();

    // Capitals the student asked for, while the text is still plain words.
    if spoken_capitals {
        let words: Vec<&str> = result.split(' ').collect();
        result = apply_spoken_capitals(&words).join(" ");
    }

    // Then, and only then, the marks they asked for out loud.
    for (pattern, mark) in MARK_PATTERNS.iter() {
        result = pattern.replace_all(&result, NoExpand(mark)).into_owned();
    }

    result = result
        .replace(APOSTROPHE_HOLD, "'")
        .replace(HYPHEN_HOLD, "-");

    tidy_spacing(&result)
}

fn hold_intraword_marks(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());

    for (index, &character) in chars.iter().enumerate() {
        let hold = match character {
            '\'' | '\u{2019}' => Some(APOSTROPHE_HOLD),
            '-' => Some(HYPHEN_HOLD),
            _ => None,
        };

        let between_letters = index > 0
            && index + 1 < chars.len()
            && chars[index - 1].is_alphabetic()
            && chars[index + 1].is_alphabetic();

        match hold {
            Some(marker) if between_letters => out.push(marker),
            _ => out.push(character),
        }
    }

    out
}

/// "command capital t" uppercases the next word. When that next word is a single
/// letter the student is spelling, so following single letters join it:
/// "command capital y", "o" becomes "Yo".
///
/// The two-word trigger is what keeps ordinary speech safe — "the capital of
/// France" is dictation, "command capital f" is an instruction.
pub fn apply_spoken_capitals(words: &[&str]) -> Vec<String> {
    let mut result: Vec<String> = Vec::with_capacity(words.len());
    let mut index = 0;

    while index < words.len() {
        let is_command = words[index] == "command"
            && index + 2 < words.len()
            && words[index + 1] == "capital";

        if !is_command {
            result.push(words[index].to_string());
            index += 1;
            continue;
        }

        let mut target = words[index + 2].to_string();
        index += 3;

        if target.chars().count() == 1 {
            while index < words.len()
                && words[index].chars().count() == 1
                && words[index].chars().next().is_some_and(char::is_alphabetic)
            {
                target.push_str(words[index]);
                index += 1;
            }
        }

        result.push(uppercase_first(&target));
    }

    result
}

// MARK: Deterministic filler pass

static FILLERS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)\b(?:u+m+|u+h+|e+r+m*|a+h+|hm+|mm+|mhm)\b[\s,]*").unwrap());

static DISCOURSE_MARKERS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i),\s*(?:you know|i mean|sort of|kind of|like|basically|literally)\s*,").unwrap()
});

/// Only patterns that cannot be anything but filler. Ambiguous ones ("like",
/// "basically") are left alone, because stripping them by rule breaks sentences
/// like "I like coffee".
pub fn tidied(text: &str) -> String {
    let without_fillers = FILLERS.replace_all(text, "");
    let without_markers = DISCOURSE_MARKERS.replace_all(&without_fillers, NoExpand(","));
    normalise(&collapse_repeats(&without_markers))
}

/// Rust's regex has no backreferences, so the Swift `\b(\w+)(?:\s+\1\b)+` becomes
/// a walk over the words.
///
/// Like the original it also collapses real doubles such as "had had". Rare enough
/// in speech that the false positives cost less than leaving every stutter in.
fn collapse_repeats(text: &str) -> String {
    let mut out: Vec<&str> = Vec::new();

    for word in text.split_whitespace() {
        if out.last().is_some_and(|last| last.eq_ignore_ascii_case(word)) {
            continue;
        }
        out.push(word);
    }

    out.join(" ")
}

// MARK: Shared tidying

static REPEATED_SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s{2,}").unwrap());
static SPACE_BEFORE_MARK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+([,.!?;:])").unwrap());
static DOUBLED_MARK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([,;:])\s*([,.!?;:])").unwrap());
static LEADING_PUNCTUATION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[\s,;:.]+").unwrap());

/// Removing words leaves double spaces, orphaned commas and a lowercased start.
pub fn normalise(text: &str) -> String {
    let text = REPEATED_SPACE.replace_all(text, " ");
    let text = SPACE_BEFORE_MARK.replace_all(&text, "$1");
    let text = DOUBLED_MARK.replace_all(&text, "$2");
    let text = LEADING_PUNCTUATION.replace_all(&text, "");
    uppercase_first(text.trim())
}

static SPACES_ONLY: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ \t]+").unwrap());
static AROUND_MARK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r" *([,.;:!?]) *").unwrap());
static AROUND_NEWLINE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r" *\n *").unwrap());

/// Spacing only, never newlines: in scribe mode those are dictated paragraph breaks.
fn tidy_spacing(text: &str) -> String {
    let text = SPACES_ONLY.replace_all(text, " ");
    let text = AROUND_MARK.replace_all(&text, "$1 ");
    let text = AROUND_NEWLINE.replace_all(&text, "\n");
    text.trim().to_string()
}

fn uppercase_first(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) if first.is_lowercase() => {
            first.to_uppercase().collect::<String>() + chars.as_str()
        }
        _ => text.to_string(),
    }
}

// MARK: Guarding a language-model pass

/// A model can ignore its instructions and answer the dictation, or quietly
/// rewrite it — either way the user would be pasting words they never said. A
/// legitimate cleanup only ever *deletes*, so anything else falls back.
pub fn verified(candidate: &str, original: &str) -> String {
    let cleaned = normalise(candidate);
    if cleaned.is_empty() {
        return tidied(original);
    }

    let ratio = cleaned.chars().count() as f64 / original.chars().count().max(1) as f64;
    if !(0.4..1.5).contains(&ratio) || !is_deletion_only(&cleaned, original) {
        return tidied(original);
    }

    cleaned
}

/// True when every word kept appears in the original, in the same order. Catches
/// added words, substitutions and reordering in one pass; punctuation and
/// capitalisation are ignored because a model is allowed to change those.
pub fn is_deletion_only(candidate: &str, original: &str) -> bool {
    let original_words = words(original);
    let mut remaining = original_words.as_slice();

    for word in words(candidate) {
        match remaining.iter().position(|existing| *existing == word) {
            Some(index) => remaining = &remaining[index + 1..],
            None => return false,
        }
    }

    true
}

static NON_WORD_CHARS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^\p{L}\p{N}']").unwrap());

fn words(text: &str) -> Vec<String> {
    NON_WORD_CHARS
        .replace_all(&text.to_lowercase(), " ")
        .split_whitespace()
        .map(str::to_string)
        .collect()
}
