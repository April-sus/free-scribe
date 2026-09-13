import Foundation

/// Words the recogniser gets wrong, and the two ways of putting them right.
///
/// Whisper mangles words it rarely saw in training: "onomatopoeia" comes back as
/// "on O'Matopir", a name comes back as something that merely sounds like it. Two
/// mechanisms, both offline and neither involving a language model:
///
/// 1. **Before** transcribing, the words are fed to the decoder as a conditioning
///    prompt, which biases it toward spelling them the way they are written here.
/// 2. **After** transcribing, anything that still came out wrong but *sounds* like
///    a word on the list is replaced by it.
///
/// Only words the user put here are ever matched. A general dictionary would be
/// free to substitute words nobody said, and in scribe mode that would be a breach
/// of the rules rather than a wrong guess.
public struct Vocabulary: Codable, Sendable, Equatable {
    public var words: [String] = []

    public init(words: [String] = []) {
        self.words = words
    }

    public static var fileURL: URL {
        Transcriber.modelsBase.appending(path: "vocabulary.json")
    }

    public static func load() -> Vocabulary {
        guard let data = try? Data(contentsOf: fileURL),
              let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data)
        else { return Vocabulary() }
        return vocabulary
    }

    public func save() {
        let directory = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    public mutating func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        words.append(trimmed)
    }

    public mutating func remove(_ word: String) {
        words.removeAll { $0 == word }
    }


    // MARK: Putting right what came out wrong

    /// Replaces anything that sounds like one of these words with the word itself.
    ///
    /// Runs of up to three words are considered together, because a word the
    /// recogniser did not know usually comes back broken into several — "on O'Matopir"
    /// for one word, not one wrong word.
    public func corrected(_ text: String) -> String {
        guard !words.isEmpty, !text.isEmpty else { return text }

        let pieces = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0

        while index < pieces.count {
            var matched = false

            // Longest run first: "on omatopir" should win over "on" alone.
            for length in stride(from: min(3, pieces.count - index), through: 1, by: -1) {
                let run = Array(pieces[index..<(index + length)])
                guard let replacement = match(run) else { continue }
                output.append(replacement)
                index += length
                matched = true
                break
            }

            if !matched {
                output.append(pieces[index])
                index += 1
            }
        }

        return output.joined(separator: " ")
    }

    /// The vocabulary word a run of words was meant to be, if any.
    ///
    /// Deliberately hard to satisfy. A false positive puts a word into the transcript
    /// that nobody said, which is worse than leaving a mangled one there — and in
    /// scribe mode it would be a breach of the rules rather than an annoyance.
    private func match(_ run: [String]) -> String? {
        // A run containing a word that is already right is not a mangled word: it is
        // a correct one with its neighbours. Without this, "bureaucracy are both"
        // swallowed the "are".
        if run.count > 1, run.contains(where: { piece in
            words.contains { $0.caseInsensitiveCompare(Self.letters(piece)) == .orderedSame }
        }) { return nil }

        let bare = Self.letters(run.joined())
        guard bare.count >= 4 else { return nil }

        let sound = Self.sound(of: bare)
        guard !sound.isEmpty else { return nil }

        for word in words {
            let target = Self.letters(word)
            // Already right: leave it alone.
            guard bare.caseInsensitiveCompare(target) != .orderedSame else { return nil }

            // Roughly the same amount of word. "the bureau" is not a mangled
            // "Kaikoura" however the sounds line up.
            guard abs(bare.count - target.count) <= max(2, target.count / 3) else { continue }

            let wanted = Self.sound(of: target)
            guard !wanted.isEmpty, abs(wanted.count - sound.count) <= 2 else { continue }

            // Words that begin with a different sound are different words. This is the
            // single most useful check: it is what a person hears first.
            guard sound.first == wanted.first else { continue }

            let allowed = max(1, wanted.count / 5)
            guard Self.distance(sound, wanted) <= allowed else { continue }

            return Self.wearing(punctuationOf: run, word: word)
        }
        return nil
    }

    /// Keeps whatever punctuation surrounded the words being replaced: "onomatopoeia,"
    /// should stay a word followed by a comma.
    private static func wearing(punctuationOf run: [String], word: String) -> String {
        let leading = run.first?.prefix { !$0.isLetter && !$0.isNumber } ?? ""
        let trailing = run.last?.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed() ?? []
        return leading + word + String(trailing)
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter }
    }

    /// A rough phonetic skeleton: the sounds a word is made of, with the spellings
    /// that make no difference to how it sounds flattened together.
    ///
    /// Not a full Metaphone. It only has to bring a mangled word close enough to the
    /// right one to be caught by the distance check, and a simple one is far easier
    /// to be sure of than a table of English exceptions.
    static func sound(of word: String) -> String {
        var letters = Array(letters(word))
        guard !letters.isEmpty else { return "" }

        // Digraphs first: these are one sound written as two letters.
        var text = String(letters)
        for (spelling, sound) in [("ph", "f"), ("gh", "f"), ("ck", "k"), ("sch", "sk"),
                                  ("sh", "s"), ("ch", "k"), ("th", "t"), ("wh", "w"),
                                  ("qu", "kw"), ("x", "ks"), ("z", "s")] {
            text = text.replacingOccurrences(of: spelling, with: sound)
        }

        // A soft c before e, i or y is an s: "bureaucracy" ends in a hiss, not a
        // click. Mapping every c to k made those two words look unrelated.
        var spelled = ""
        let characters = Array(text)
        for (index, letter) in characters.enumerated() {
            guard letter == "c" else {
                spelled.append(letter)
                continue
            }
            let next = index + 1 < characters.count ? characters[index + 1] : " "
            spelled.append("eiy".contains(next) ? "s" : "k")
        }
        letters = Array(spelled)

        var sound = ""
        var previous: Character?
        for (index, letter) in letters.enumerated() {
            // Vowels carry almost no information about a misheard word — they are
            // what the recogniser gets wrong first — so only a leading one is kept.
            let isVowel = "aeiouy".contains(letter)
            if isVowel, index > 0 { continue }
            if letter == "h", index > 0 { continue }
            // Doubled letters are one sound.
            if letter == previous { continue }
            sound.append(letter)
            previous = letter
        }
        return sound
    }

    /// Levenshtein distance, for how far apart two of those skeletons are.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
