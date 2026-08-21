import Foundation
import WhisperKit

/// Owns the WhisperKit pipeline and keeps it warm between dictations —
/// cold-loading a CoreML model per utterance would dominate the latency.
public actor Transcriber {
    public enum Phase: Sendable, Equatable {
        case idle
        case downloading(Double)   // 0...1
        case loading
        case ready
    }

    private var pipe: WhisperKit?
    public private(set) var loadedModel: String?

    public init() {}

    /// Identifies the container the app and its keyboard both see.
    public static let appGroup = "group.local.freescribe.shared"

    /// Where models live. Deliberately outside the app bundle so a rebuild does not
    /// throw away a large download.
    ///
    /// On iOS this has to be the shared group container: a keyboard extension is
    /// sandboxed separately from its own app, so anything written to the app's
    /// Application Support is invisible to the keyboard, which then tries to
    /// download its own copy — and a keyboard has no reliable network to do it with.
    public static var modelsBase: URL {
        #if os(iOS)
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return shared.appending(path: "WhisperFlow")
        }
        #endif

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "WhisperFlow")
    }

    /// Whether a model is present without trying to fetch one. A keyboard should
    /// say what is missing rather than attempt a download it cannot complete.
    public static func canRunOffline(_ model: String) -> Bool {
        isDownloaded(model)
    }

    public static func localFolder(for model: String) -> URL {
        modelsBase.appending(path: "models/argmaxinc/whisperkit-coreml/\(model)")
    }

    public static func isDownloaded(_ model: String) -> Bool {
        FileManager.default.fileExists(atPath: localFolder(for: model).path)
    }

    public static func downloadedModels() -> [String] {
        let root = modelsBase.appending(path: "models/argmaxinc/whisperkit-coreml")
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    }

    public static func delete(_ model: String) throws {
        try FileManager.default.removeItem(at: localFolder(for: model))
    }

    /// Downloads the model if missing, then loads it. No-op if already loaded.
    public func load(model: String, onPhase: @Sendable @escaping (Phase) -> Void) async throws {
        if loadedModel == model, pipe != nil { return }

        let folder: URL
        if Self.isDownloaded(model) {
            folder = Self.localFolder(for: model)
        } else {
            onPhase(.downloading(0))
            folder = try await WhisperKit.download(
                variant: model,
                downloadBase: Self.modelsBase
            ) { progress in
                onPhase(.downloading(progress.fractionCompleted))
            }
        }

        onPhase(.loading)
        let config = WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        loadedModel = model
        onPhase(.ready)
    }

    /// Drops any half-finished transcription state. Called after a failure or a
    /// cancellation so the next attempt starts clean instead of inheriting it.
    public func clearState() {
        pipe?.clearState()
    }

    public func unload() async {
        await pipe?.unloadModels()
        pipe = nil
        loadedModel = nil
    }

    /// Below this, treat the recording as nothing said.
    ///
    /// The first value here was calibrated against synthesised speech, which peaks
    /// around 0.19. Real microphones are far quieter — measured against actual
    /// recordings, quiet speech peaks at 0.016 — which left almost no margin and
    /// threw away short or softly spoken phrases before the recogniser saw them.
    /// Whisper's own no-speech thresholds are the real defence against silence;
    /// this only has to catch a dead microphone.
    public static let silenceThreshold: Float = 0.004

    /// Whisper works on a long window and returns nothing at all for very short
    /// clips, so anything briefer than this is padded with silence.
    static let minimumSeconds: Double = 2.0

    /// - Parameter language: ISO code such as "en", or nil to let Whisper detect it.
    public func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }

        // Whisper hallucinates confidently on silence — a muted microphone reliably
        // produces "you". Pasting a word the user never said is the worst thing this
        // app can do, and in scribe mode it would be a breach of the rules.
        guard Self.peak(of: samples) >= Self.silenceThreshold else { return "" }

        let results = try await pipe.transcribe(
            audioArray: Self.padded(samples),
            decodeOptions: options(language)
        )
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    /// Loudest 100 ms of the recording. Peak rather than mean, so a short word
    /// surrounded by silence still registers.
    static func peak(of samples: [Float]) -> Float {
        let window = 1600
        guard !samples.isEmpty else { return 0 }

        var loudest: Float = 0
        for start in stride(from: 0, to: samples.count, by: window) {
            let chunk = samples[start..<min(start + window, samples.count)]
            guard !chunk.isEmpty else { continue }
            let mean = chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)
            loudest = max(loudest, mean.squareRoot())
        }
        return loudest
    }

    /// "Yes." on its own transcribes as nothing until the clip is long enough.
    static func padded(_ samples: [Float]) -> [Float] {
        let wanted = Int(minimumSeconds * 16000)
        guard samples.count < wanted else { return samples }
        return samples + [Float](repeating: 0, count: wanted - samples.count)
    }

    /// Diagnostic path for `--transcribe`. Goes through the same guards as a
    /// dictation so what it prints is what a user would actually get.
    public func transcribe(path: String, language: String?) async throws -> String {
        guard pipe != nil else { throw TranscriberError.notLoaded }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        return try await transcribe(samples: samples, language: language)
    }

    private func options(_ language: String?) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // The energy gate catches silence; this catches loud non-speech, where
            // Whisper will otherwise invent a confident short sentence.
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
    }

    /// Whisper emits leading spaces and, on silence, bracketed non-speech tags
    /// like "(wind blowing)" or "[BLANK_AUDIO]" that must not be pasted.
    static func clean(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "[\\(\\[][^\\)\\]]*[\\)\\]]",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriberError: LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "No speech model is loaded yet."
        }
    }
}
