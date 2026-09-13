import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", default: .init(.d, modifiers: [.command, .option]))
}

/// One shortcut, two feels: hold it down to talk, or tap it to latch on and tap
/// again to stop. Which one you get is decided by how long the first press lasted.
///
/// Whether a dictation is running is the recorder's to say, not this class's. It
/// used to keep a `latched` flag of its own, set on every tap — including a tap whose
/// start had failed or not happened yet. The next press then took the "stop" branch,
/// found nothing recording, and did nothing: that was the press that had to be made
/// twice, and only sometimes.
@MainActor
final class Hotkey {
    private static let tapThreshold: TimeInterval = 0.3

    private unowned let state: AppState
    /// When the press that started the current dictation went down, while it is
    /// still down. Nil once released, or when this press was a stop.
    private var pressedAt: Date?

    /// Forgets a press in progress. After a sleep the key-up may never have come.
    func reset() {
        pressedAt = nil
    }

    init(state: AppState) {
        self.state = state

        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self else { return }
            if state.isRecording {
                pressedAt = nil
                state.finishDictation()
                return
            }
            pressedAt = Date()
            state.startDictation()
        }

        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self, let pressedAt else { return }
            self.pressedAt = nil
            // Held: push-to-talk, so letting go ends it. Tapped: it keeps listening,
            // and the next press ends it — found through `isRecording`, not a flag.
            if Date().timeIntervalSince(pressedAt) >= Self.tapThreshold {
                state.finishDictation()
            }
        }
    }
}
