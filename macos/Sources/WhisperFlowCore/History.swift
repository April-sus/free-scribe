import Foundation

/// One finished dictation, kept so it can be copied again.
public struct Transcript: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let date: Date
    /// The style it was produced under, so the board can show how it was treated.
    public let style: String
    /// Why it failed, or nil when it worked. Optional so entries written before
    /// failures were recorded still decode.
    public var failureReason: String?
    /// What was actually said, when `text` is a translation of it. Nil for every
    /// other style, and for entries written before translation existed.
    public var original: String?

    public var isTranslation: Bool { original != nil }

    public var failed: Bool { failureReason != nil }

    public init(text: String, date: Date = Date(), style: String, failureReason: String? = nil, original: String? = nil) {
        self.init(id: UUID(), text: text, date: date, style: style, failureReason: failureReason, original: original)
    }

    public init(id: UUID, text: String, date: Date, style: String, failureReason: String? = nil, original: String? = nil) {
        self.id = id
        self.text = text
        self.date = date
        self.style = style
        self.failureReason = failureReason
        self.original = original
    }

    /// True while the original recording is still cached and can be run again.
    public var canRetranscribe: Bool { AudioCache.exists(id) }
}

/// Every transcript, kept for good.
///
/// Written to disk after each dictation and never trimmed: the whole point is that
/// something dictated last month is still there. Removing entries is the user's
/// call, never the app's.
public struct History: Codable, Sendable {
    public var entries: [Transcript] = []

    public init() {}

    /// - Returns: the new entry, whose id also names its cached audio.
    @discardableResult
    public mutating func record(_ text: String, style: DictationStyle, original: String? = nil) -> Transcript? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let transcript = Transcript(text: trimmed, style: style.label, original: original)
        entries.insert(transcript, at: 0)
        return transcript
    }

    /// A dictation that produced nothing. The recording is kept, so it can be
    /// retried — otherwise a failure loses both the text and the audio, and the
    /// user has nothing left to try again with.
    @discardableResult
    public mutating func recordFailure(_ reason: String, style: DictationStyle) -> Transcript {
        let transcript = Transcript(text: "", style: style.label, failureReason: reason)
        entries.insert(transcript, at: 0)
        return transcript
    }

    /// Replaces the text after the audio has been run through again. A successful
    /// retry clears the failure, so the entry stops offering one.
    public mutating func update(_ id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = Transcript(
            id: id,
            text: text,
            date: entries[index].date,
            style: entries[index].style,
            failureReason: nil,
            original: entries[index].original
        )
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        // The recording goes with it: deleting a transcript should not leave the
        // audio of it sitting on disk.
        AudioCache.remove(id)
    }

    public mutating func removeAll() {
        entries.removeAll()
        AudioCache.clear()
    }

    // MARK: Storage

    public static var fileURL: URL {
        Transcriber.modelsBase.appending(path: "history.json")
    }

    public static func load() -> History {
        guard let data = try? Data(contentsOf: fileURL),
              let history = try? JSONDecoder().decode(History.self, from: data)
        else { return History() }
        return history
    }

    public func save() {
        let directory = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Removes the file entirely rather than writing an empty one, so a cleared
    /// history leaves nothing behind to recover.
    public static func erase() {
        try? FileManager.default.removeItem(at: fileURL)
        AudioCache.clear()
    }
}
