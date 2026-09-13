import SwiftUI
import Translation
import WhisperFlowCore

/// Translation on iOS, which cannot be the translator the other platforms use.
///
/// macOS and Windows both run MADLAD-400 in a CTranslate2 sidecar — a separate
/// program, because CTranslate2 is C++ and linking it into a Swift package is far
/// more trouble than spawning a child. iOS has no subprocesses at all, so that
/// route is closed here, and Apple's own framework is the only on-device
/// translator a phone can run.
///
/// The consequence is worth being honest about: **iOS translations will not always
/// match the Mac's.** Apple covers fewer languages than MADLAD's 98 and words
/// things its own way. Dictation and the scribe rules are unaffected — scribe mode
/// never translates, and never touches a language model of any kind.
@MainActor
final class AppleTranslator: ObservableObject {
    /// Set to ask SwiftUI for a session; `translationTask` hands one back.
    @Published var configuration: TranslationSession.Configuration?

    private var session: TranslationSession?
    private var waiting: [CheckedContinuation<TranslationSession, Never>] = []

    /// Which of our languages this phone can translate into, installed or not.
    @Published private(set) var supported: Set<String> = []

    func loadSupported() async {
        let languages = await LanguageAvailability().supportedLanguages
        supported = Set(languages.compactMap(\.languageCode?.identifier))
    }

    /// Whether the pack for a pair is already on the device, so Settings can say
    /// "downloaded" rather than making the user find out mid-dictation.
    func isInstalled(from source: String, to target: String) async -> Bool {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )
        return status == .installed
    }

    func attach(_ session: TranslationSession) {
        self.session = session
        for continuation in waiting { continuation.resume(returning: session) }
        waiting.removeAll()
    }

    /// Downloads the pack for a pair. iOS puts up its own prompt for this; there is
    /// no way to fetch one silently, and no reason to want one.
    func download(from source: String, to target: String) async throws {
        let session = await session(from: source, to: target)
        try await session.prepareTranslation()
    }

    func translate(_ text: String, from source: String, to target: String) async -> String? {
        guard source != target else { return text }
        let session = await session(from: source, to: target)
        return try? await session.translate(text).targetText
    }

    /// A session belongs to one language pair, so a change of language means asking
    /// SwiftUI for a new one and waiting for it to arrive.
    private func session(from source: String, to target: String) async -> TranslationSession {
        let wanted = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )

        if let session, configuration == wanted { return session }
        session = nil
        configuration = wanted

        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }
}
