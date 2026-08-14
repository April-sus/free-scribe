import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let dictate = Self("dictate", default: .init(.d, modifiers: [.command, .option]))
}

/// One shortcut, two feels: hold it down to talk, or tap it to latch on and tap
/// again to stop. Which one you get is decided by how long the first press lasted.
@MainActor
final class Hotkey {
    private static let tapThreshold: TimeInterval = 0.3

    private unowned let state: AppState
    private var pressedAt: Date?
    private var latched = false

    init(state: AppState) {
        self.state = state

        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            guard let self else { return }
            if latched {
                latched = false
                state.finishDictation()
                return
            }
            pressedAt = Date()
            state.startDictation()
        }

        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            guard let self, let pressedAt else { return }
            self.pressedAt = nil
            if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
                latched = true // a tap: keep listening until the next press
            } else {
                state.finishDictation()
            }
        }
    }
}
