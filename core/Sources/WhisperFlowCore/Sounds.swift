#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif
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

        #if !os(macOS)
        var identifier: SystemSoundID {
            switch self {
            case .started: 1113   // begin recording
            case .inserted: 1114  // end recording
            case .failed: 1073    // error tone
            case .copied: 1104    // key press tick
            }
        }
        #endif
    }

    public static func play(_ cue: Cue) {
        guard enabled else { return }
        #if os(macOS)
        guard let sound = NSSound(named: cue.name) else { return }
        sound.volume = cue.volume
        sound.play()
        #else
        // iOS has no named system sounds and no volume control over them, so these
        // are the stock UI cues by id. Their character matches the Mac's: a tick to
        // start, a pop on success, an error tone on failure.
        AudioServicesPlaySystemSound(cue.identifier)
        #endif
    }
}
