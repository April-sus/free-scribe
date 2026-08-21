import Foundation

/// One finished dictation, kept so it can be copied again.
public struct Transcript: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let date: Date
    /// The style it was produced under, so the board can show how it was treated.
    public let style: String

    public init(text: String, date: Date = Date(), style: String) {
        self.id = UUID()
        self.text = text
        self.date = date
        self.style = style
    }
}

/// Recent transcripts.
///
/// Held in memory for the session so the board is useful straight away, and written
/// to disk only if the user asks for it. On a shared or school machine, a log of what
/// somebody said is exactly the sort of thing that should not linger by default.
public struct History: Codable, Sendable {
    /// Enough to find the thing you dictated a moment ago, not a diary.
    public static let limit = 20

    public var entries: [Transcript] = []

    public init() {}

    /// Scribe mode is never recorded. During an exam a list of earlier answers is a
    /// record nobody sanctioned, and could function as assistance.
    public static func records(style: DictationStyle) -> Bool {
        style != .scribe
    }

    public mutating func record(_ text: String, style: DictationStyle) {
        guard Self.records(style: style) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.insert(Transcript(text: trimmed, style: style.label), at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
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

    /// Removes the file entirely rather than writing an empty one, so turning the
    /// setting off leaves nothing behind to recover.
    public static func erase() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
