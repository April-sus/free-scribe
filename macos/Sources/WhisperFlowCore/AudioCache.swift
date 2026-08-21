import AVFoundation
import Foundation

/// Keeps the audio of the most recent dictations so a transcript can be produced
/// again from the original recording rather than guessed at.
///
/// This is the most sensitive thing the app stores — recordings of somebody
/// speaking — so it is deliberately small, rotates on its own, and can be wiped
/// outright at any time.
public enum AudioCache {
    /// Only the last few. Enough to redo something that came out wrong, not an
    /// archive of everything anybody has said.
    public static let limit = 7

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
    @discardableResult
    public static func store(_ samples: [Float], id: UUID) -> Bool {
        guard !samples.isEmpty else { return false }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(samples, to: url(for: id))
            prune()
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

    private static func prune() {
        let files = stored()
        guard files.count > limit else { return }
        for file in files.prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: file)
        }
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
