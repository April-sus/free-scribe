import SwiftUI
import Translation
import WhisperFlowCore

/// On-device translation of a finished dictation.
///
/// `TranslationSession` has no initialiser — it is only handed out by SwiftUI's
/// `.translationTask`, so a session cannot simply be created where it is needed.
/// The work is instead posted to a stream that a long-lived view drains, which
/// keeps one session alive for as many dictations as the configuration allows.
@MainActor
final class Translator: ObservableObject {
    struct Job {
        let text: String
        let finish: (String?) -> Void
    }

    /// Changing this is what causes SwiftUI to vend a new session.
    @Published private(set) var configuration: TranslationSession.Configuration?

    private var jobs: [Job] = []
    private var waiting: CheckedContinuation<Job, Never>?

    /// Whether a pair can be translated without going to the network. Reports the
    /// reason when it cannot, since "nothing happened" is the worst answer.
    static func availability(from source: String, to target: String) async -> String? {
        guard source != target else { return "Both languages are the same." }

        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: target)
        )

        switch status {
        case .installed: return nil
        case .supported: return nil  // macOS downloads the pair on first use.
        case .unsupported: return "This Mac cannot translate that pair on-device."
        @unknown default: return "That pair is unavailable."
        }
    }

    func prepare(from source: String, to target: String) {
        let wanted = TranslationSession.Configuration(
            source: Locale.Language(identifier: source),
            target: Locale.Language(identifier: target)
        )
        guard configuration != wanted else { return }
        configuration = wanted
    }

    /// - Returns: the translation, or nil if it could not be produced.
    func translate(_ text: String) async -> String? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let job = Job(text: text) { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
            submit(job)
        }
    }

    private func submit(_ job: Job) {
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: job)
        } else {
            jobs.append(job)
        }
    }

    fileprivate func nextJob() async -> Job {
        if !jobs.isEmpty { return jobs.removeFirst() }
        return await withCheckedContinuation { continuation in
            waiting = continuation
        }
    }

    /// Called when a session goes away — anything still queued would otherwise wait
    /// for a worker that no longer exists.
    fileprivate func abandonQueued() {
        let pending = jobs
        jobs.removeAll()
        for job in pending { job.finish(nil) }
    }
}

/// Attach to a view that stays alive. It drains the queue for as long as SwiftUI
/// keeps the session, so one session serves many dictations.
struct TranslationWorker: ViewModifier {
    @ObservedObject var translator: Translator

    func body(content: Content) -> some View {
        content.translationTask(translator.configuration) { session in
            // Prepared once per session rather than per dictation; this is what
            // downloads the language the first time a pair is used.
            try? await session.prepareTranslation()

            while !Task.isCancelled {
                let job = await translator.nextJob()
                let result = try? await session.translate(job.text)
                job.finish(result?.targetText)
            }

            translator.abandonQueued()
        }
    }
}

extension View {
    func translationWorker(_ translator: Translator) -> some View {
        modifier(TranslationWorker(translator: translator))
    }
}
