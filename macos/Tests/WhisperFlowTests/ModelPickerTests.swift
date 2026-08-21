import AVFoundation
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
    func testEveryStyleIsRecorded() {
        // Including scribe: the history is kept whatever mode produced it. If exam
        // use ever needs an exception, this is the test that has to change first.
        var history = History()
        history.record("hello there", style: .scribe)
        history.record("and this", style: .tidy)
        XCTAssertEqual(history.entries.count, 2)
    }

    func testNewestFirst() {
        var history = History()
        history.record("first", style: .tidy)
        history.record("second", style: .verbatim)
        XCTAssertEqual(history.entries.map(\.text), ["second", "first"])
    }

    func testEmptyTranscriptsAreIgnored() {
        var history = History()
        XCTAssertNil(history.record("   \n ", style: .tidy))
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testNothingIsTrimmedAway() {
        // Permanent by design: something dictated last month is still there.
        var history = History()
        for index in 0..<250 {
            history.record("entry \(index)", style: .tidy)
        }
        XCTAssertEqual(history.entries.count, 250)
        XCTAssertEqual(history.entries.last?.text, "entry 0")
    }

    func testRemoveTakesOnlyThatEntry() {
        var history = History()
        history.record("keep", style: .tidy)
        history.record("drop", style: .tidy)
        history.remove(history.entries[0].id)
        XCTAssertEqual(history.entries.map(\.text), ["keep"])
    }

    func testRetranscribingReplacesTextButKeepsWhenAndHow() {
        var history = History()
        let original = history.record("wrong wrods", style: .tidy)!
        history.update(original.id, text: "wrong words")

        let updated = history.entries[0]
        XCTAssertEqual(updated.text, "wrong words")
        XCTAssertEqual(updated.id, original.id, "the id names its recording, so it must survive")
        XCTAssertEqual(updated.date, original.date)
        XCTAssertEqual(updated.style, original.style)
    }

    func testUpdatingSomethingAlreadyDeletedDoesNothing() {
        var history = History()
        history.record("here", style: .tidy)
        history.update(UUID(), text: "should not appear")
        XCTAssertEqual(history.entries.map(\.text), ["here"])
    }
}

final class AudioCacheTests: XCTestCase {
    /// Writes to a temporary file rather than the real cache: a test must never
    /// touch recordings belonging to the person using the app.
    func testRecordingsSurviveTheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "free-scribe-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // A recognisable ramp, so a channel or endianness mistake would show up.
        let samples = (0..<16000).map { Float($0) / 16000.0 * 0.5 }
        try AudioCache.write(samples, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, 16000, "every sample should be written, not a padded or truncated buffer")
    }
}

final class FailedTranscriptTests: XCTestCase {
    func testAFailureIsKeptSoItCanBeRetried() {
        var history = History()
        let failure = history.recordFailure("Nothing could be made out", style: .tidy)

        XCTAssertTrue(failure.failed)
        XCTAssertEqual(history.entries.first?.failureReason, "Nothing could be made out")
        XCTAssertTrue(history.entries.first?.text.isEmpty == true)
    }

    func testASuccessfulRetryClearsTheFailure() {
        var history = History()
        let failure = history.recordFailure("Nothing could be made out", style: .tidy)
        history.update(failure.id, text: "there it is")

        let entry = history.entries[0]
        XCTAssertFalse(entry.failed, "a retry that worked must stop offering one")
        XCTAssertNil(entry.failureReason)
        XCTAssertEqual(entry.text, "there it is")
        XCTAssertEqual(entry.id, failure.id, "the id names the recording, so it has to survive the retry")
    }

    func testEntriesWrittenBeforeFailuresExistedStillDecode() throws {
        // Old history files have no failureReason key at all.
        let json = """
        {"entries":[{"id":"\(UUID().uuidString)","text":"older entry","date":768000000,"style":"Verbatim"}]}
        """
        let history = try JSONDecoder().decode(History.self, from: Data(json.utf8))
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertFalse(history.entries[0].failed)
    }
}

final class RecordingGroupingTests: XCTestCase {
    /// Built in the local calendar rather than from UTC strings: grouping is by
    /// local day, so a UTC literal lands on a different date depending on where the
    /// machine is, and the test would pass or fail by timezone.
    private func recording(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, bytes: Int64 = 1000) -> Recording {
        let components = DateComponents(year: year, month: month, day: day, hour: hour)
        return Recording(id: UUID(), date: Calendar.current.date(from: components)!, bytes: bytes)
    }

    func testDaysGroupSeparatelyAndNewestComesFirst() {
        let items = [
            recording(2026, 8, 21, 9),
            recording(2026, 8, 21, 17),
            recording(2026, 8, 19, 9),
        ]
        let groups = Grouping.day.group(items)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].recordings.count, 2, "both of the 21st belong together")
        XCTAssertGreaterThan(groups[0].date, groups[1].date, "newest group first")
    }

    func testMonthAndYearCollapseTheSameItemsFurther() {
        let items = [
            recording(2026, 8, 21, 9),
            recording(2026, 8, 2, 9),
            recording(2026, 3, 2, 9),
            recording(2025, 3, 2, 9),
        ]
        XCTAssertEqual(Grouping.day.group(items).count, 4)
        XCTAssertEqual(Grouping.month.group(items).count, 3)
        XCTAssertEqual(Grouping.year.group(items).count, 2)
    }

    func testAGroupReportsWhatDeletingItWouldFree() {
        let items = [
            recording(2026, 8, 21, 9, bytes: 1500),
            recording(2026, 8, 21, 10, bytes: 2500),
        ]
        XCTAssertEqual(Grouping.day.group(items).first?.bytes, 4000)
    }

    func testGroupingNothingProducesNothing() {
        XCTAssertTrue(Grouping.month.group([]).isEmpty)
    }
}

final class HistorySearchTests: XCTestCase {
    private func history(_ entries: [(String, Date)]) -> History {
        var history = History()
        // Stored newest first, which is what the pane relies on.
        for (text, date) in entries {
            history.entries.append(Transcript(text: text, date: date, style: "Verbatim"))
        }
        return history
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testSearchIgnoresCase() {
        let items = history([("Meeting about the Budget", date(2026, 8, 21))])
        XCTAssertEqual(items.matching(search: "budget", period: .all).count, 1)
        XCTAssertEqual(items.matching(search: "BUDGET", period: .all).count, 1)
        XCTAssertEqual(items.matching(search: "invoice", period: .all).count, 0)
    }

    func testSearchMatchesPartOfAWord() {
        let items = history([("transcription", date(2026, 8, 21))])
        XCTAssertEqual(items.matching(search: "script", period: .all).count, 1)
    }

    func testBlankSearchKeepsEverything() {
        let items = history([("one", date(2026, 8, 21)), ("two", date(2026, 8, 20))])
        XCTAssertEqual(items.matching(search: "   ", period: .all).count, 2)
    }

    func testPeriodsNarrowByCalendar() {
        let now = date(2026, 8, 21)
        let items = history([
            ("today", now),
            ("earlier this month", date(2026, 8, 3)),
            ("earlier this year", date(2026, 2, 3)),
            ("last year", date(2025, 2, 3)),
        ])

        XCTAssertEqual(items.matching(search: "", period: .today, now: now).count, 1)
        XCTAssertEqual(items.matching(search: "", period: .month, now: now).count, 2)
        XCTAssertEqual(items.matching(search: "", period: .year, now: now).count, 3)
        XCTAssertEqual(items.matching(search: "", period: .all, now: now).count, 4)
    }

    func testSearchAndPeriodApplyTogether() {
        let now = date(2026, 8, 21)
        let items = history([
            ("budget meeting", now),
            ("budget meeting", date(2025, 8, 21)),
        ])
        XCTAssertEqual(items.matching(search: "budget", period: .year, now: now).count, 1)
    }

    func testFailuresAreFoundByTheirReason() {
        // A failed entry has no text, so searching would otherwise hide it entirely.
        var items = History()
        items.recordFailure("Nothing could be made out", style: .tidy)
        XCTAssertEqual(items.matching(search: "nothing", period: .all).count, 1)
        XCTAssertEqual(items.matching(search: "unrelated", period: .all).count, 0)
    }
}

final class LanguageTests: XCTestCase {
    func testEveryLanguageHasAName() {
        // A code showing as a bare "sw" in the menu would be a bug, not a language.
        let unnamed = Languages.all().filter { $0.endonym == $0.code }
        XCTAssertTrue(unnamed.isEmpty, "no native name for: \(unnamed.map(\.code))")
    }

    func testNamesAreInTheirOwnLanguage() {
        let all = Languages.all()
        XCTAssertEqual(all.first { $0.code == "fr" }?.endonym, "français")
        XCTAssertEqual(all.first { $0.code == "de" }?.endonym, "Deutsch")
        XCTAssertEqual(all.first { $0.code == "ja" }?.endonym, "日本語")
    }

    func testLabelAddsATranslationOnlyWhenItDiffers() {
        let english = Locale(identifier: "en")
        let all = Languages.all(displayedIn: english)
        // English reading English needs no gloss; English reading Japanese does.
        XCTAssertEqual(all.first { $0.code == "en" }?.label, "English")
        XCTAssertEqual(all.first { $0.code == "ja" }?.label, "日本語 — Japanese")
    }

    func testCodesAreUnique() {
        XCTAssertEqual(Set(Languages.codes).count, Languages.codes.count)
    }

    func testTheSystemLanguageIsOnlyOfferedWhenItCanBeHeard() {
        // Returns nil rather than a code the recogniser does not know.
        if let code = Languages.systemDefault() {
            XCTAssertTrue(Languages.codes.contains(code))
        }
    }
}

final class TranslationTests: XCTestCase {
    func testATranslationKeepsWhatWasActuallySaid() {
        var history = History()
        let entry = history.record("Bonjour", style: .translated, original: "Hello")!

        XCTAssertTrue(entry.isTranslation)
        XCTAssertEqual(entry.original, "Hello", "the original is the point of the mode")
        XCTAssertEqual(entry.text, "Bonjour", "text is what was inserted, so copying gives the translation")
    }

    func testOtherStylesCarryNoOriginal() {
        var history = History()
        let entry = history.record("hello there", style: .tidy)!
        XCTAssertFalse(entry.isTranslation)
        XCTAssertNil(entry.original)
    }

    func testRetranscribingATranslationKeepsTheOriginal() {
        var history = History()
        let entry = history.record("Bonjour", style: .translated, original: "Hello")!
        history.update(entry.id, text: "Salut")

        XCTAssertEqual(history.entries[0].text, "Salut")
        XCTAssertEqual(history.entries[0].original, "Hello", "a retry must not discard what was said")
    }

    func testTranslatedTextIsLeftForTheTranslatorRatherThanTidied() async {
        // The filler pass would only change what the translator is handed.
        let spoken = "um so I I think this is fine"
        let result = await Cleanup.apply(spoken, style: .translated)
        XCTAssertEqual(result, spoken)
    }

    func testEntriesWrittenBeforeTranslationExistedStillDecode() throws {
        let json = """
        {"entries":[{"id":"\(UUID().uuidString)","text":"older","date":768000000,"style":"Verbatim"}]}
        """
        let history = try JSONDecoder().decode(History.self, from: Data(json.utf8))
        XCTAssertFalse(history.entries[0].isTranslation)
    }
}

final class SilenceGateTests: XCTestCase {
    /// Measured from a real microphone rather than synthesised speech: quiet
    /// dictation peaks around 0.016, which the original 0.01 gate nearly rejected.
    func testQuietRealSpeechIsWellAboveTheGate() {
        // The 0.016 measured from real recordings is an RMS, and a sine's RMS is
        // its amplitude over root two — so the amplitude has to be scaled up to
        // model a signal that actually reads 0.016.
        let amplitude = Float(0.016 * 2.0.squareRoot())
        let quiet = (0..<32000).map { index in sin(Float(index) * 0.05) * amplitude }
        XCTAssertGreaterThan(Transcriber.peak(of: quiet), Transcriber.silenceThreshold)
        XCTAssertGreaterThan(
            Transcriber.peak(of: quiet) / Transcriber.silenceThreshold, 3,
            "a real microphone needs room to spare, not a hair's breadth"
        )
    }

    func testADeadMicrophoneIsStillRejected() {
        XCTAssertLessThan(Transcriber.peak(of: [Float](repeating: 0, count: 32000)),
                          Transcriber.silenceThreshold)
    }
}
