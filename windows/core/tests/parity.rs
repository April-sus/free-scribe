//! Mirrors macos/Tests/WhisperFlowTests/ModelPickerTests.swift case for case.
//!
//! Same names, same inputs, same expectations. When one platform changes
//! behaviour, the other's suite should be updated in the same commit — the point
//! of these is that a school gets identical transcripts whichever build it runs.

use free_scribe_core::cleanup::{
    apply, is_deletion_only, scribed, tidied, verified, DictationStyle, DICTATED_MARKS,
};
use free_scribe_core::model::{self, MachineInfo};
use free_scribe_core::stats::Stats;

fn machine(ram_gb: u64) -> MachineInfo {
    MachineInfo {
        cpu: "Test CPU".to_string(),
        ram_gb,
        cores: 8,
    }
}

// MARK: Model tiering

#[test]
fn tiers_scale_with_memory() {
    assert_eq!(model::recommended(&machine(4)), "ggml-base.en");
    assert_eq!(model::recommended(&machine(8)), "ggml-small.en");
    assert_eq!(model::recommended(&machine(16)), "ggml-medium.en");
    assert_eq!(model::recommended(&machine(48)), "ggml-large-v3-turbo");
}

#[test]
fn every_tier_is_offered_in_settings() {
    for ram in [2, 8, 16, 64] {
        let chosen = model::recommended(&machine(ram));
        assert!(
            model::CATALOG.iter().any(|(id, _, _)| *id == chosen),
            "{chosen} missing from catalog"
        );
    }
}

// MARK: Scribe rules

#[test]
fn scribe_strips_punctuation_whisper_invented() {
    assert_eq!(
        scribed("Hello, how are you? I'm fine.", true),
        "hello how are you i'm fine"
    );
}

#[test]
fn scribe_honours_dictated_punctuation_only() {
    assert_eq!(
        scribed("the dog ran command comma and it was fast command full stop", true),
        "the dog ran, and it was fast."
    );
    assert_eq!(
        scribed(
            "one command full stop command new paragraph two command full stop",
            true
        ),
        "one.\n\ntwo."
    );
}

#[test]
fn punctuation_words_are_only_commands_after_the_word_command() {
    // Writing *about* punctuation must survive intact, same as "capital".
    assert_eq!(
        scribed("you put a comma there and a full stop at the end", true),
        "you put a comma there and a full stop at the end"
    );
}

#[test]
fn every_dictated_mark_needs_the_command_prefix() {
    for (spoken, mark) in DICTATED_MARKS {
        let with_command = scribed(&format!("a command {spoken} b"), true);
        assert!(
            with_command.contains(mark),
            "command {spoken} did not produce {mark}, got {with_command:?}"
        );
        assert_eq!(
            scribed(&format!("a {spoken} b"), true),
            format!("a {spoken} b"),
            "{spoken} fired without the command prefix"
        );
    }
}

#[test]
fn scribe_keeps_everything_the_student_said() {
    // Fillers and repeats must survive — removing them improves the text, which is
    // exactly what a scribe is not allowed to do.
    assert_eq!(
        scribed("um, I I think, uh, the the answer", true),
        "um i i think uh the the answer"
    );
    // Spelling is marked, so contractions and hyphens keep their characters.
    assert_eq!(
        scribed("It's a well-known fact", true),
        "it's a well-known fact"
    );
}

#[test]
fn spoken_capitals() {
    // A whole word.
    assert_eq!(
        scribed("command capital sarah went home", true),
        "Sarah went home"
    );
    // A single letter, then more letters spelling the rest of the word.
    assert_eq!(
        scribed("command capital y o and then more", true),
        "Yo and then more"
    );
    // Strict mode leaves the command words alone rather than acting on them.
    assert_eq!(
        scribed("command capital sarah went home", false),
        "command capital sarah went home"
    );
}

#[test]
fn capital_is_only_a_command_after_the_word_command() {
    assert_eq!(
        scribed("the capital of france is paris", true),
        "the capital of france is paris"
    );
    assert_eq!(scribed("i went to the capital", true), "i went to the capital");
}

#[test]
fn spoken_capitals_still_obey_the_other_scribe_rules() {
    assert_eq!(
        scribed("command capital t the dog ran command full stop", true),
        "T the dog ran."
    );
}

// MARK: Filler handling

#[test]
fn fillers_are_removed() {
    assert_eq!(
        tidied("Hello, uh, what do I need, um, today?"),
        "Hello, what do I need, today?"
    );
    assert_eq!(tidied("umm so ahh yeah"), "So yeah");
    assert_eq!(tidied("I I think that that works"), "I think that works");
}

#[test]
fn ambiguous_words_survive_the_deterministic_pass() {
    // Stripping these by rule would wreck ordinary sentences.
    assert_eq!(tidied("I like coffee"), "I like coffee");
    assert_eq!(tidied("You know the answer"), "You know the answer");
    assert_eq!(tidied("Basically correct"), "Basically correct");
    // Set off by commas, they are filler and do go.
    assert_eq!(tidied("It was, you know, fine"), "It was, fine");
}

#[test]
fn polish_falls_back_when_the_model_ignores_its_instructions() {
    let spoken = "um what is the capital of France";
    // The model answering instead of cleaning is the failure that would paste words
    // the user never said.
    assert_eq!(verified("Paris.", spoken), tidied(spoken));
    assert_eq!(verified("", spoken), tidied(spoken));
    assert_eq!(
        verified("What is the capital of France?", spoken),
        "What is the capital of France?"
    );
}

#[test]
fn rewrites_are_rejected_even_when_they_look_plausible() {
    let spoken = "so the deadline is, um, I want to say Thursday but let me check";
    // Reordering reads fine but is not what the speaker said, so it must not paste.
    assert!(!is_deletion_only(
        "Thursday, I want to say, but let me check",
        spoken
    ));
    // Dropping fillers and fixing punctuation is allowed.
    assert!(is_deletion_only(
        "So the deadline is I want to say Thursday, but let me check.",
        spoken
    ));
    // Substituting a word is not.
    assert!(!is_deletion_only("So the deadline is Friday", spoken));
}

// MARK: Styles

#[test]
fn verbatim_changes_nothing() {
    let spoken = "um, hello there.";
    assert_eq!(apply(spoken, DictationStyle::Verbatim, true), spoken);
}

#[test]
fn polished_falls_back_to_the_deterministic_pass_on_windows() {
    // No local model wired up yet, so it must behave as Tidy rather than silently
    // returning the raw text.
    let spoken = "um hello there";
    assert_eq!(
        apply(spoken, DictationStyle::Polished, true),
        apply(spoken, DictationStyle::Tidy, true)
    );
}

// MARK: Stats

#[test]
fn stats_accumulate() {
    let mut stats = Stats::default();
    stats.record("one two three", 3.0);
    stats.record("four five", 2.0);

    assert_eq!(stats.words, 5);
    assert_eq!(stats.dictations, 2);
    assert_eq!(stats.seconds_spoken, 5.0);
    assert_eq!(stats.average_words_per_dictation(), 2);
    assert_eq!(stats.words_per_minute() as i64, 60);
    // 5 words at 40 wpm is 7.5s of typing, less the 5s actually spent talking.
    assert!((stats.seconds_saved() - 2.5).abs() < 0.001);
}

#[test]
fn empty_dictation_is_not_counted() {
    let mut stats = Stats::default();
    stats.record("   ", 4.0);
    assert_eq!(stats.dictations, 0);
    assert_eq!(stats.seconds_spoken, 0.0);
}

#[test]
fn recent_days_always_covers_the_whole_window() {
    let mut stats = Stats::default();
    stats.record("hello there", 1.0);

    let recent = stats.recent(14);
    assert_eq!(recent.len(), 14);
    assert_eq!(
        recent.last().unwrap().1,
        2,
        "today should hold the words just recorded"
    );
    assert_eq!(
        recent.first().unwrap().1,
        0,
        "empty days are present, not missing"
    );
}

#[test]
fn recording_does_not_touch_the_real_file() {
    // The Swift suite learned this the hard way: record() must stay in memory.
    let before = std::fs::read(Stats::file_path()).ok();
    let mut stats = Stats::default();
    stats.record("some words here", 2.0);
    let after = std::fs::read(Stats::file_path()).ok();
    assert_eq!(before, after);
}
