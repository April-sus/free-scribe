import Foundation

/// Narrowing a long history down to the thing you are actually looking for.
///
/// Both filters are cheap and run on every keystroke, so they stay simple: a
/// case-insensitive substring match and a calendar comparison. Nothing here needs
/// an index until somebody has tens of thousands of transcripts.
public enum Period: String, CaseIterable, Identifiable, Sendable {
    case all, today, week, month, year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .today: "Today"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }

    /// What the picker means, spelled out — "this week" is the calendar week, not
    /// the last seven days, and the two disagree every Monday.
    public var detail: String {
        switch self {
        case .all: "Everything you have dictated."
        case .today: "Dictated today."
        case .week: "Dictated this calendar week."
        case .month: "Dictated this calendar month."
        case .year: "Dictated this calendar year."
        }
    }

    public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: true
        case .today: calendar.isDate(date, inSameDayAs: now)
        case .week: calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .month: calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .year: calendar.isDate(date, equalTo: now, toGranularity: .year)
        }
    }
}

public extension History {
    /// Entries matching both filters, newest first as they are already stored.
    ///
    /// A failed entry has no text, so its reason is searched instead — otherwise
    /// failures would vanish the moment anything was typed in the box.
    func matching(search: String, period: Period, now: Date = Date()) -> [Transcript] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)

        return entries.filter { transcript in
            guard period.contains(transcript.date, now: now) else { return false }
            guard !needle.isEmpty else { return true }

            let haystack = transcript.failed
                ? (transcript.failureReason ?? "")
                : transcript.text
            return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
