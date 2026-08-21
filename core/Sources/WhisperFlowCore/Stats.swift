import Foundation

/// Usage totals, kept in a plain JSON file next to the models. Nothing is sent
/// anywhere — there is no network code in this type, and deleting the file resets it.
public struct Stats: Codable, Sendable {
    /// What a competent typist manages in prose. Used only to estimate the time
    /// dictating saved, so it is an honest ballpark rather than a measurement.
    public static let typingWordsPerMinute = 40.0

    public var words = 0
    public var dictations = 0
    public var secondsSpoken = 0.0
    public var firstUsed: Date?
    public var lastUsed: Date?
    /// yyyy-MM-dd to words, for the recent-activity chart.
    public var byDay: [String: Int] = [:]

    public init() {}

    // MARK: Derived

    /// Time typing those words would have taken, less the time actually spent saying
    /// them. Negative early on, which is fine and honest.
    public var secondsSaved: Double {
        Double(words) / Self.typingWordsPerMinute * 60 - secondsSpoken
    }

    public var wordsPerMinute: Double {
        secondsSpoken > 0 ? Double(words) / (secondsSpoken / 60) : 0
    }

    public var averageWordsPerDictation: Int {
        dictations > 0 ? words / dictations : 0
    }

    /// Words per day for the last `days` days, oldest first, including empty days.
    public func recent(days: Int) -> [(day: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, byDay[Self.key(for: day)] ?? 0)
        }
    }

    // MARK: Recording

    /// Updates the totals in memory. Deliberately does not write — the caller decides
    /// when to persist, so counting can be exercised without touching the real file.
    public mutating func record(spoken: String, seconds: Double) {
        let count = spoken.split(whereSeparator: \.isWhitespace).count
        guard count > 0 else { return }

        words += count
        dictations += 1
        secondsSpoken += seconds
        let now = Date()
        if firstUsed == nil { firstUsed = now }
        lastUsed = now
        byDay[Self.key(for: now), default: 0] += count

        // ponytail: keeps roughly a year of daily buckets. Plenty for the chart, and
        // it stops the file growing without bound.
        if byDay.count > 400 {
            for key in byDay.keys.sorted().prefix(byDay.count - 365) {
                byDay.removeValue(forKey: key)
            }
        }
    }

    // MARK: Storage

    public static var fileURL: URL {
        Transcriber.modelsBase.appending(path: "stats.json")
    }

    public static func load() -> Stats {
        guard let data = try? Data(contentsOf: fileURL),
              let stats = try? JSONDecoder().decode(Stats.self, from: data)
        else { return Stats() }
        return stats
    }

    public func save() {
        let directory = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    public static func erase() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func key(for date: Date) -> String { dayFormatter.string(from: date) }
}

public extension Double {
    /// "2h 14m", "6m", "44s" — for durations shown to a person, not parsed.
    var asDuration: String {
        let total = Int(abs(self).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
