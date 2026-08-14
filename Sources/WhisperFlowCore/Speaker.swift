import AVFoundation
import Foundation

/// Reads the scribed text back. The NAPLAN scribe rules let a student ask for the
/// text so far to be read back to maintain continuity, so a software scribe has to
/// be able to do it — but only on request, never unprompted.
@MainActor
public enum Speaker {
    private static let synthesiser = AVSpeechSynthesizer()

    public static var isSpeaking: Bool { synthesiser.isSpeaking }

    public static func readBack(_ text: String) {
        guard !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        // Slightly under default: this is being read back for checking, not listening.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesiser.speak(utterance)
    }

    public static func stop() {
        guard synthesiser.isSpeaking else { return }
        synthesiser.stopSpeaking(at: .immediate)
    }
}
