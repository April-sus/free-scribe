import XCTest
@testable import WhisperFlowCore

final class VocabularyTests: XCTestCase {
    private let vocabulary = Vocabulary(words: ["onomatopoeia", "bureaucracy", "Siobhan", "Kaikoura"])

    /// The real failure this exists for, measured from the actual recogniser: the
    /// small model returns "on O'Matopir" for one spoken word.
    func testPutsBackAWordBrokenIntoSeveral() {
        XCTAssertEqual(
            vocabulary.corrected("The word on O'Matopir is difficult"),
            "The word onomatopoeia is difficult"
        )
    }

    func testKeepsThePunctuationAroundIt() {
        XCTAssertEqual(vocabulary.corrected("say omatopeia, again"), "say onomatopoeia, again")
    }

    func testLeavesAWordThatIsAlreadyRight() {
        let sentence = "onomatopoeia and bureaucracy are both hard"
        XCTAssertEqual(vocabulary.corrected(sentence), sentence)
    }

    /// The danger is a word nobody said. Ordinary words that merely rhyme, or share
    /// a few sounds, must survive untouched.
    func testLeavesUnrelatedWordsAlone() {
        for sentence in [
            "the bureau was closed",
            "she went to the shop and bought bread",
            "a democracy is not a bureaucracy",
        ] {
            XCTAssertEqual(vocabulary.corrected(sentence), sentence, sentence)
        }
    }

    func testDoesNothingWithoutAVocabulary() {
        XCTAssertEqual(Vocabulary().corrected("on O'Matopir"), "on O'Matopir")
    }


    func testSoundIgnoresSpellingThatDoesNotChangeTheSound() {
        XCTAssertEqual(Vocabulary.sound(of: "photo"), Vocabulary.sound(of: "foto"))
        XCTAssertEqual(Vocabulary.sound(of: "bureaucracy"), Vocabulary.sound(of: "bureaukrasy"))
        // Doubled letters are one sound, and case is not a sound at all.
        XCTAssertEqual(Vocabulary.sound(of: "Kaikoura"), Vocabulary.sound(of: "kaikkoura"))
    }

    /// Whole sentences of ordinary words, none of which should be touched. The list
    /// is deliberately full of words that share sounds with the vocabulary.
    func testDoesNotTouchOrdinaryWriting() {
        let sentences = [
            "the boy ran home because he was late",
            "an automatic machine made the noise",
            "she wrote about a monarchy and a democracy",
            "on a mat opposite the door",
        ]
        for sentence in sentences {
            XCTAssertEqual(vocabulary.corrected(sentence), sentence, sentence)
        }
    }
}
