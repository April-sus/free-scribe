import XCTest
@testable import WhisperFlowCore

/// Loads a real model and transcribes a real file.
///
/// Skipped unless asked for, because it needs a model on disk and takes seconds
/// rather than milliseconds. It exists to answer "does this model actually work"
/// without a phone in the loop — the iOS app runs this same code, so a model that
/// fails here fails there.
///
///     FREE_SCRIBE_MODEL=/path/to/Model FREE_SCRIBE_AUDIO=/path/to.wav \
///       swift test --filter LiveModelTests
final class LiveModelTests: XCTestCase {
    func testTranscribesWithTheGivenModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["FREE_SCRIBE_MODEL"],
              let audioPath = environment["FREE_SCRIBE_AUDIO"]
        else { throw XCTSkip("Set FREE_SCRIBE_MODEL and FREE_SCRIBE_AUDIO to run this") }

        // Copied to where the loader looks, so the whole path is exercised — including
        // the tokenizer resolution, which is what the bundled model gets wrong.
        let name = "free-scribe-live-test"
        let destination = Transcriber.localFolder(for: name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: URL(fileURLWithPath: modelPath), to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertTrue(Transcriber.isDownloaded(name), "the folder is not a usable model")

        let transcriber = Transcriber()
        let loadStart = Date()
        try await transcriber.load(model: name) { _ in }
        let loaded = Date().timeIntervalSince(loadStart)

        // Twice: the first transcription pays for whatever the model does lazily, and
        // the second is what a user actually waits for on every dictation after that.
        var elapsed: [Double] = []
        var text = ""
        for _ in 0..<2 {
            let start = Date()
            text = try await transcriber.transcribe(path: audioPath, language: "en")
            elapsed.append(Date().timeIntervalSince(start))
        }

        print("[live] load \(String(format: "%.2f", loaded))s, first \(String(format: "%.2f", elapsed[0]))s, second \(String(format: "%.2f", elapsed[1]))s")
        print("[live] transcript: \(text)")
        XCTAssertFalse(text.isEmpty, "the model loaded but transcribed nothing")
    }
}
