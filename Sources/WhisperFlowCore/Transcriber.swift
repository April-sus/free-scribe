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

    /// Where models live. Deliberately outside the app bundle so a rebuild does not
    /// throw away a 1 GB download.
    public static var modelsBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "WhisperFlow")
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

    /// - Parameter language: ISO code such as "en", or nil to let Whisper detect it.
    public func transcribe(samples: [Float], language: String?) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language))
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    public func transcribe(path: String, language: String?) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        let results = try await pipe.transcribe(audioPath: path, decodeOptions: options(language))
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    private func options(_ language: String?) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
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
