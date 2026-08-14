import KeyboardShortcuts
import SwiftUI

/// The shortcut recorder plus the state it is easy to end up in by accident: empty.
/// Clearing the field (backspace, or the ⓧ button) leaves no shortcut at all, and
/// without this warning the app just looks like the hotkey stopped working.
struct ShortcutField: View {
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .dictate)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KeyboardShortcuts.Recorder("Dictation shortcut:", name: .dictate) { shortcut = $0 }

            if shortcut == nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No shortcut set — dictation can only be started from the menu bar.")
                        .font(.footnote)
                    Button("Use ⌘⌥D") {
                        KeyboardShortcuts.reset(.dictate)
                        shortcut = KeyboardShortcuts.getShortcut(for: .dictate)
                    }
                    .controlSize(.small)
                }
            } else {
                Text("Hold it to talk and release to insert, or tap once to start and tap again to stop. The text is pasted wherever your cursor is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
