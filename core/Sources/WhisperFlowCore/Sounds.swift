// NSSound is AppKit; iOS cues would come from AudioServices instead.
#if os(macOS)
import AppKit
import Foundation

/// Short cues for the things that happen while you are looking at another app.
///
/// Dictation is used with the window hidden, so sound is often the only feedback
/// there is — particularly for "I stopped listening" and "that failed".
@MainActor
public enum Sounds {
    public static var enabled = true

    public enum Cue {
        case started
        case inserted
        case failed
        case copied

        /// System sounds rather than bundled assets: nothing to ship, nothing to
        /// license, and they already match what the user expects from the OS.
        var name: String {
            switch self {
            case .started: "Tink"
            case .inserted: "Pop"
            case .failed: "Basso"
            case .copied: "Morse"
            }
        }

        var volume: Float {
            switch self {
            case .failed: 0.6
            default: 0.35
            }
        }
    }

    public static func play(_ cue: Cue) {
        guard enabled, let sound = NSSound(named: cue.name) else { return }
        sound.volume = cue.volume
        sound.play()
    }
}

#endif
