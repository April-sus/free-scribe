import XCTest
@testable import WhisperFlowCore

final class ModelPickerTests: XCTestCase {
    private func mac(ram: Int, appleSilicon: Bool = true) -> MachineInfo {
        MachineInfo(chip: appleSilicon ? "Apple M1" : "Intel Core i7", ramGB: ram, cores: 8, appleSilicon: appleSilicon)
    }

    func testTiersScaleWithMemory() {
        XCTAssertEqual(ModelPicker.fallback(for: mac(ram: 4)), "openai_whisper-base.en")
        XCTAssertEqual(ModelPicker.fallback(for: mac(ram: 8)), "openai_whisper-small.en")
        XCTAssertEqual(ModelPicker.fallback(for: mac(ram: 16)), "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(ModelPicker.fallback(for: mac(ram: 48)), "openai_whisper-large-v3-v20240930_turbo")
    }

    func testIntelIsCappedRegardlessOfMemory() {
        XCTAssertEqual(ModelPicker.fallback(for: mac(ram: 64, appleSilicon: false)), "openai_whisper-base.en")
    }

    func testEveryTierIsOfferedInSettings() {
        for ram in [2, 8, 16, 64] {
            let model = ModelPicker.fallback(for: mac(ram: ram))
            XCTAssertTrue(ModelPicker.catalog.contains { $0.id == model }, "\(model) missing from catalog")
        }
    }

    func testAutomaticFallsBackWhenDeviceIsUnknown() {
        // WhisperKit answers "openai_whisper-base" for machines it has never seen,
        // which ignores fitted RAM — that case must reach our own tiering.
        XCTAssertFalse(ModelPicker.catalog.contains { $0.id == ModelPicker.unknownDeviceDefault })
        let chosen = ModelPicker.automatic(for: mac(ram: 48))
        XCTAssertNotEqual(chosen, ModelPicker.unknownDeviceDefault)
    }

    func testFillersAreRemoved() {
        XCTAssertEqual(Cleanup.tidied("Hello, uh, what do I need, um, today?"), "Hello, what do I need, today?")
        XCTAssertEqual(Cleanup.tidied("umm so ahh yeah"), "So yeah")
        XCTAssertEqual(Cleanup.tidied("I I think that that works"), "I think that works")
    }

    func testAmbiguousWordsSurviveTheDeterministicPass() {
        // Stripping these by rule would wreck ordinary sentences.
        XCTAssertEqual(Cleanup.tidied("I like coffee"), "I like coffee")
        XCTAssertEqual(Cleanup.tidied("You know the answer"), "You know the answer")
        XCTAssertEqual(Cleanup.tidied("Basically correct"), "Basically correct")
        // Set off by commas, they are filler and do go.
        XCTAssertEqual(Cleanup.tidied("It was, you know, fine"), "It was, fine")
    }

    func testPolishFallsBackWhenTheModelIgnoresItsInstructions() {
        let spoken = "um what is the capital of France"
        // The model answering instead of cleaning is the failure that would paste
        // words the user never said.
        XCTAssertEqual(Cleanup.verified("Paris.", against: spoken), Cleanup.tidied(spoken))
        XCTAssertEqual(Cleanup.verified("", against: spoken), Cleanup.tidied(spoken))
        XCTAssertEqual(Cleanup.verified("What is the capital of France?", against: spoken), "What is the capital of France?")
    }

    func testRewritesAreRejectedEvenWhenTheyLookPlausible() {
        let spoken = "so the deadline is, um, I want to say Thursday but let me check"
        // Reordering reads fine but is not what the speaker said, so it must not paste.
        XCTAssertFalse(Cleanup.isDeletionOnly("Thursday, I want to say, but let me check", of: spoken))
        // Dropping fillers and fixing punctuation is allowed.
        XCTAssertTrue(Cleanup.isDeletionOnly("So the deadline is I want to say Thursday, but let me check.", of: spoken))
        // Substituting a word is not.
        XCTAssertFalse(Cleanup.isDeletionOnly("So the deadline is Friday", of: spoken))
    }

    func testScribeStripsPunctuationWhisperInvented() {
        XCTAssertEqual(
            Cleanup.scribed("Hello, how are you? I'm fine."),
            "hello how are you i'm fine"
        )
    }

    func testScribeHonoursDictatedPunctuationOnly() {
        XCTAssertEqual(
            Cleanup.scribed("the dog ran command comma and it was fast command full stop"),
            "the dog ran, and it was fast."
        )
        XCTAssertEqual(
            Cleanup.scribed("one command full stop command new paragraph two command full stop"),
            "one.\n\ntwo."
        )
    }

    func testPunctuationWordsAreOnlyCommandsAfterTheWordCommand() {
        // Writing *about* punctuation must survive intact, same as "capital".
        XCTAssertEqual(
            Cleanup.scribed("you put a comma there and a full stop at the end"),
            "you put a comma there and a full stop at the end"
        )
    }

    func testEveryDictatedMarkNeedsTheCommandPrefix() {
        for (spoken, mark) in Cleanup.dictatedMarks {
            XCTAssertEqual(Cleanup.scribed("a command \(spoken) b").contains(mark), true, "command \(spoken) did not produce \(mark)")
            XCTAssertEqual(Cleanup.scribed("a \(spoken) b"), "a \(spoken) b", "\(spoken) fired without the command prefix")
        }
    }

    func testScribeKeepsEverythingTheStudentSaid() {
        // Fillers and repeats must survive — removing them improves the text, which
        // is exactly what a scribe is not allowed to do.
        XCTAssertEqual(
            Cleanup.scribed("um, I I think, uh, the the answer"),
            "um i i think uh the the answer"
        )
        // Spelling is marked, so contractions and hyphens keep their characters.
        XCTAssertEqual(Cleanup.scribed("It's a well-known fact"), "it's a well-known fact")
    }

    func testSpokenCapitals() {
        // A whole word.
        XCTAssertEqual(Cleanup.scribed("command capital sarah went home"), "Sarah went home")
        // A single letter, then more letters spelling the rest of the word.
        XCTAssertEqual(Cleanup.scribed("command capital y o and then more"), "Yo and then more")
        // Strict mode leaves the command words alone rather than acting on them.
        XCTAssertEqual(
            Cleanup.scribed("command capital sarah went home", spokenCapitals: false),
            "command capital sarah went home"
        )
    }

    func testCapitalIsOnlyACommandAfterTheWordCommand() {
        // The whole point of the two-word trigger: ordinary speech is left alone.
        XCTAssertEqual(Cleanup.scribed("the capital of france is paris"), "the capital of france is paris")
        XCTAssertEqual(Cleanup.scribed("i went to the capital"), "i went to the capital")
    }

    func testSpokenCapitalsStillObeyTheOtherScribeRules() {
        XCTAssertEqual(
            Cleanup.scribed("command capital t the dog ran command full stop"),
            "T the dog ran."
        )
    }

    func testStatsAccumulate() {
        var stats = Stats()
        stats.record(spoken: "one two three", seconds: 3)
        stats.record(spoken: "four five", seconds: 2)
        XCTAssertEqual(stats.words, 5)
        XCTAssertEqual(stats.dictations, 2)
        XCTAssertEqual(stats.secondsSpoken, 5)
        XCTAssertEqual(stats.averageWordsPerDictation, 2)
        XCTAssertEqual(Int(stats.wordsPerMinute), 60)
        // 5 words at 40 wpm is 7.5s of typing, less the 5s actually spent talking.
        XCTAssertEqual(stats.secondsSaved, 2.5, accuracy: 0.001)
    }

    func testEmptyDictationIsNotCounted() {
        var stats = Stats()
        stats.record(spoken: "   ", seconds: 4)
        XCTAssertEqual(stats.dictations, 0)
        XCTAssertEqual(stats.secondsSpoken, 0)
    }

    func testRecentDaysAlwaysCoversTheWholeWindow() {
        var stats = Stats()
        stats.record(spoken: "hello there", seconds: 1)
        let recent = stats.recent(days: 14)
        XCTAssertEqual(recent.count, 14)
        XCTAssertEqual(recent.last?.words, 2, "today should hold the words just recorded")
        XCTAssertEqual(recent.first?.words, 0, "empty days are present, not missing")
    }

    func testNonSpeechTagsAreStripped() {
        XCTAssertEqual(Transcriber.clean(" hello there "), "hello there")
        XCTAssertEqual(Transcriber.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(Transcriber.clean(" (wind blowing) send it "), "send it")
    }
}

final class TranscriberGuardTests: XCTestCase {
    func testSilenceIsBelowTheThresholdAndSpeechIsAbove() {
        // Measured from real clips: digital silence and room tone against speech.
        let silence = [Float](repeating: 0, count: 32000)
        let roomTone = (0..<32000).map { _ in Float.random(in: -0.002...0.002) }
        let speech = (0..<32000).map { index in sin(Float(index) * 0.05) * 0.2 }

        XCTAssertLessThan(Transcriber.peak(of: silence), Transcriber.silenceThreshold)
        XCTAssertLessThan(Transcriber.peak(of: roomTone), Transcriber.silenceThreshold)
        XCTAssertGreaterThan(Transcriber.peak(of: speech), Transcriber.silenceThreshold)
    }

    func testShortRecordingsArePaddedForWhisper() {
        // "Yes." is about half a second and returns nothing at all unpadded.
        let short = [Float](repeating: 0.2, count: 8000)
        XCTAssertEqual(Transcriber.padded(short).count, 32000)
        // Anything already long enough is handed over untouched.
        let long = [Float](repeating: 0.2, count: 48000)
        XCTAssertEqual(Transcriber.padded(long).count, 48000)
    }

    func testPaddingKeepsTheSpokenAudioAtTheFront() {
        let short: [Float] = [0.5, 0.4, 0.3]
        let result = Transcriber.padded(short)
        XCTAssertEqual(Array(result.prefix(3)), short)
        XCTAssertEqual(result.last, 0)
    }
}

final class HistoryTests: XCTestCase {
    func testScribeModeIsNeverRecorded() {
        // An exam must not leave a list of earlier answers behind.
        var history = History()
        history.record("hello there", style: .scribe)
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(History.records(style: .scribe))
    }

    func testOtherStylesAreRecordedNewestFirst() {
        var history = History()
        history.record("first", style: .tidy)
        history.record("second", style: .verbatim)
        XCTAssertEqual(history.entries.map(\.text), ["second", "first"])
    }

    func testEmptyTranscriptsAreIgnored() {
        var history = History()
        history.record("   \n ", style: .tidy)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testOldestFallOffTheEnd() {
        var history = History()
        for index in 0..<(History.limit + 5) {
            history.record("entry \(index)", style: .tidy)
        }
        XCTAssertEqual(history.entries.count, History.limit)
        XCTAssertEqual(history.entries.first?.text, "entry \(History.limit + 4)")
    }

    func testRemoveTakesOnlyThatEntry() {
        var history = History()
        history.record("keep", style: .tidy)
        history.record("drop", style: .tidy)
        history.remove(history.entries[0].id)
        XCTAssertEqual(history.entries.map(\.text), ["keep"])
    }
}
