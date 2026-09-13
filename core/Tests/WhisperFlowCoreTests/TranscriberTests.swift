import XCTest
@testable import WhisperFlowCore

final class TranscriberTests: XCTestCase {
    /// A download that stops after the weights leaves a folder that looks finished
    /// and a model CoreML will not load. Everything routes through this check, so
    /// the app re-downloads and the keyboard says the model is not there yet.
    func testAnInterruptedDownloadDoesNotCountAsDownloaded() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "transcriber-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ relative: String) throws {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }

        let files = ["coremldata.bin", "model.mil", "weights/weight.bin"]
        for part in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            for file in files {
                try write("\(part).mlmodelc/\(file)")
            }
        }
        XCTAssertTrue(Transcriber.isComplete(root))

        // What the phone actually had: the weights arrived, model.mil never did.
        try FileManager.default.removeItem(at: root.appending(path: "AudioEncoder.mlmodelc/model.mil"))
        XCTAssertFalse(Transcriber.isComplete(root))
    }
}

extension TranscriberTests {
    /// A phone in a pocket-to-mouth position records the same voice far quieter than
    /// one held close, and Whisper calls the quiet one blank audio.
    func testQuietAudioIsBroughtUp() {
        let quiet = (0..<1000).map { _ in Float.random(in: -0.02...0.02) }
        let louder = Transcriber.normalised(quiet)
        let peak = louder.reduce(0) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.15, "quiet speech should be lifted towards the training level")
    }

    /// Loud enough already: leave it alone rather than clipping it.
    func testAudioThatIsAlreadyLoudIsUntouched() {
        let loud: [Float] = [0.6, -0.7, 0.55]
        XCTAssertEqual(Transcriber.normalised(loud), loud)
    }

    /// The gain is capped, so a silent room stays quiet noise instead of being
    /// amplified into something the recogniser will hallucinate words from.
    func testTheGainIsCapped() {
        let nearSilence = (0..<1000).map { _ in Float.random(in: -0.0005...0.0005) }
        let lifted = Transcriber.normalised(nearSilence)
        let peak = lifted.reduce(0) { max($0, abs($1)) }
        XCTAssertLessThan(peak, 0.05, "near-silence must not be amplified to speech level")
    }

    func testSilenceIsLeftAlone() {
        XCTAssertEqual(Transcriber.normalised([0, 0, 0]), [0, 0, 0])
    }
}
