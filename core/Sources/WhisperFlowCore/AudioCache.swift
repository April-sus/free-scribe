import AVFoundation
import Foundation

/// Keeps the audio of the most recent dictations so a transcript can be produced
/// again from the original recording rather than guessed at.
///
/// This is the most sensitive thing the app stores — recordings of somebody
/// speaking — so it is deliberately small, rotates on its own, and can be wiped
/// outright at any time.
public enum AudioCache {
    /// Only the last few by default. Enough to redo something that came out wrong,
    /// not an archive of everything anybody has said — but a user who wants the
    /// archive can have it, and manage it themselves.
    public static let defaultLimit = 7

    /// Matches `Recorder.sampleRate`, restated here because this type is not
    /// main-actor isolated and that one is.
    static let sampleRate: Double = 16000

    public static var directory: URL {
        Transcriber.modelsBase.appending(path: "audio")
    }

    public static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).wav")
    }

    public static func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Writes the recording and drops whatever has fallen off the end.
    /// - Parameter keepingLast: how many to retain, or nil to keep every one.
    @discardableResult
    public static func store(_ samples: [Float], id: UUID, keepingLast limit: Int?) -> Bool {
        guard !samples.isEmpty else { return false }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(samples, to: url(for: id))
            if let limit { prune(to: limit) }
            return true
        } catch {
            // A failed cache write must never cost the user their transcript.
            return false
        }
    }

    /// 16-bit PCM at 16 kHz: what the recogniser wants, and a quarter the size of
    /// the float buffer it came from.
    static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AudioCacheError.unwritable
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// Oldest first, so callers can show what is still redoable.
    public static func stored() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "wav" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate < rightDate
            }
    }

    private static func prune(to limit: Int) {
        let files = stored()
        guard files.count > limit else { return }
        for file in files.prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Everything cached, newest first, with what each one costs — the basis for
    /// deciding what to clear out.
    public static func recordings() -> [Recording] {
        stored().reversed().compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Recording(
                id: id,
                date: values?.contentModificationDate ?? .distantPast,
                bytes: Int64(values?.fileSize ?? 0)
            )
        }
    }

    public static func remove(_ ids: Set<UUID>) {
        for id in ids { remove(id) }
    }

    public static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Wipes every recording. Offered unconditionally — this is audio of a person,
    /// and getting rid of it should never depend on another setting.
    public static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Total bytes on disk, so the user can see what "keeping audio" actually costs.
    public static func bytesUsed() -> Int64 {
        stored().reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }
}

/// One cached recording, as the storage list sees it.
public struct Recording: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let date: Date
    public let bytes: Int64
}

/// How the storage list buckets recordings, so a year of them can be cleared
/// without picking through every one.
public enum Grouping: String, CaseIterable, Identifiable, Sendable {
    case day, month, year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: "Day"
        case .month: "Month"
        case .year: "Year"
        }
    }

    var components: Set<Calendar.Component> {
        switch self {
        case .day: [.year, .month, .day]
        case .month: [.year, .month]
        case .year: [.year]
        }
    }

    public func title(for date: Date) -> String {
        switch self {
        case .day: date.formatted(date: .long, time: .omitted)
        case .month: date.formatted(.dateTime.month(.wide).year())
        case .year: date.formatted(.dateTime.year())
        }
    }

    /// Groups newest first, each group's recordings newest first too.
    public func group(_ recordings: [Recording]) -> [RecordingGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [Recording]] = [:]

        for recording in recordings {
            let start = calendar.date(from: calendar.dateComponents(components, from: recording.date))
                ?? recording.date
            buckets[start, default: []].append(recording)
        }

        return buckets
            .map { RecordingGroup(date: $0.key, title: title(for: $0.key), recordings: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.date > $1.date }
    }
}

public struct RecordingGroup: Identifiable, Sendable {
    public let date: Date
    public let title: String
    public let recordings: [Recording]

    public var id: Date { date }
    public var bytes: Int64 { recordings.reduce(0) { $0 + $1.bytes } }
}

public enum AudioCacheError: LocalizedError {
    case unwritable
    case missing

    public var errorDescription: String? {
        switch self {
        case .unwritable: "The recording could not be saved."
        case .missing: "Audio transcription failed — the recording is no longer stored."
        }
    }
}
