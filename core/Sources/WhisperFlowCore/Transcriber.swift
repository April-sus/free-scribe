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

    public static func localFolder(for model: String) -> URL {
        modelsBase.appending(path: "models/argmaxinc/whisperkit-coreml/\(model)")
    }

    public static func isDownloaded(_ model: String) -> Bool {
        bundled(model) != nil || isComplete(localFolder(for: model))
    }

    /// A model shipped inside the app, if this is one.
    ///
    /// The iOS build carries its default model so dictation works the moment the app
    /// is installed, with no download to wait for and nothing to fail on a school's
    /// network. Only the app ever loads a model — the keyboard asks the app to
    /// dictate — so reading it out of the app's own bundle is enough, and copying it
    /// into the shared container would only duplicate 145 MB.
    public static func bundled(_ model: String) -> URL? {
        guard let folder = Bundle.main.url(forResource: "Model", withExtension: nil),
              isComplete(folder),
              model == bundledModel
        else { return nil }
        return folder
    }

    /// Which model the bundled one is. Kept beside the fetch script that puts it there.
    public static let bundledModel = "openai_whisper-base.en"

    /// Whether a model folder holds a usable model, rather than whatever an
    /// interrupted download happened to leave behind.
    /// Stop reading the source code 😠
    ///
    /// The folder existing says almost nothing: a part-finished download keeps the
    /// weights, which are fetched first and are nearly all of the bytes, but not
    /// `model.mil`. CoreML then refuses the `.mlmodelc` with "compile the model
    /// with Xcode or MLModel.compileModel", which reads as a compilation problem
    /// and is really a missing file. Checking here means the next load re-downloads
    /// instead of failing forever.
    static func isComplete(_ folder: URL) -> Bool {
        let parts = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        return parts.allSatisfy { part in
            let compiled = folder.appending(path: "\(part).mlmodelc")
            return ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy {
                FileManager.default.fileExists(atPath: compiled.appending(path: $0).path)
            }
        }
    }

    /// Fetches a model without loading it, so a model can be chosen in Settings
    /// ahead of time rather than at the moment it is first needed.
    ///
    /// Safe to call again after an interrupted download: the partly-fetched file is
    /// kept and the next attempt asks for the rest of it by byte range, so a phone
    /// that was closed at 80% resumes at 80% rather than starting again.
    @discardableResult
    public static func fetch(
        _ model: String,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: model,
            downloadBase: modelsBase,
            // Deliberately the ordinary session, not a background one. A background
            // transfer is handed to nsurlsessiond, which schedules it against every
            // other app's, and the Hub builds one background session per file all
            // sharing a single identifier — which is a conflict, not reuse. Measured
            // against ~5 MB/s available from the same network, it was far slower.
            //
            // What is lost is transfers continuing after the app is closed. What is
            // kept is the part that matters: the partly-fetched file stays on disk and
            // the next attempt asks for the rest by byte range, so closing the app
            // pauses the download rather than wasting it.
            useBackgroundSession: false
        ) { progress in
            onProgress(progress.fractionCompleted)
        }
    }

    public static func downloadedModels() -> [String] {
        let root = modelsBase.appending(path: "models/argmaxinc/whisperkit-coreml")
        return (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
    }

    public static func delete(_ model: String) throws {
        guard bundled(model) == nil else { throw TranscriberError.bundled }
        try FileManager.default.removeItem(at: localFolder(for: model))
    }

    /// Downloads the model if missing, then loads it. No-op if already loaded.
    public func load(model: String, onPhase: @Sendable @escaping (Phase) -> Void) async throws {
        if loadedModel == model, pipe != nil { return }

        let folder: URL
        if let shipped = Self.bundled(model) {
            folder = shipped
        } else if Self.isComplete(Self.localFolder(for: model)) {
            folder = Self.localFolder(for: model)
        } else {
            onPhase(.downloading(0))
            folder = try await Self.fetch(model) { onPhase(.downloading($0)) }
        }

        onPhase(.loading)
        // Point the tokenizer at the model folder when it holds one. Without this,
        // WhisperKit falls back to fetching the tokenizer from the Hub at load time —
        // which turns a model that ships inside the app into one that still needs the
        // network the first time it is used, and fails on a phone that has none.
        let localTokenizer = FileManager.default
            .fileExists(atPath: folder.appending(path: "tokenizer.json").path) ? folder : nil

        let config = WhisperKitConfig(
            model: model,
            modelFolder: folder.path,
            tokenizerFolder: localTokenizer,
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

        // No conditioning prompt. WhisperKit 0.18 honours an end-of-text sampled while
        // a prompt is still being forced and returns nothing at all
        // (argmaxinc/WhisperKit#372, fixed upstream after v1.0.0, which the pin
        // predates). Working around it meant decoding twice on every dictation that
        // had a vocabulary, for biasing that was not arriving anyway — the phonetic
        // correction afterwards does the same job for free. Restore this when the
        // dependency moves.
        let audio = Self.padded(Self.normalised(samples))
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options(language))
        let raw = results.map(\.text).joined(separator: " ")

        // The raw text, before bracketed tags are stripped: "[BLANK_AUDIO]" and an
        // empty string both come out of `clean` as nothing, and they mean different
        // things — one is the model hearing silence, the other is the model saying
        // nothing at all.
        Diagnostics.log("whisper: \(results.count) segments, raw \"\(raw.prefix(120))\"")
        return Self.clean(raw)
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

    /// Brings a quiet recording up to a level the recogniser was trained on.
    ///
    /// A phone held at arm's length, or recording while the app is in the background,
    /// produces peaks around 0.02 where the same voice gives 0.5 up close. Whisper
    /// answers "[BLANK_AUDIO]" to the first and transcribes the second. The gain is
    /// capped so that a recording of a quiet room is amplified into quiet noise
    /// rather than into something the recogniser will invent words from.
    static func normalised(_ samples: [Float], target: Float = 0.5, maximumGain: Float = 12) -> [Float] {
        let peak = samples.reduce(0) { max($0, abs($1)) }
        guard peak > 0, peak < target else { return samples }

        let gain = min(target / peak, maximumGain)
        guard gain > 1.05 else { return samples }
        return samples.map { $0 * gain }
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
            // Forces the task, language and no-timestamps tokens into the decoder.
            usePrefillPrompt: true,
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
    case bundled

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "No speech model is loaded yet."
        case .bundled: "That model came with the app and cannot be deleted."
        }
    }
}
/// Tung tung suhar wouldn't be happy
