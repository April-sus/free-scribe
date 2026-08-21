// iOS has no way to type into another app; a keyboard extension inserts text itself.
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Puts the transcript into whatever app the user is actually typing in.
@MainActor
public enum Paste {
    private static let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant Accessibility" prompt. Returns the current state,
    /// which is almost always false the first time — macOS grants it out of band.
    @discardableResult
    public static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Copies `text` and, if we are allowed to synthesise keystrokes, presses ⌘V in
    /// the frontmost app. Returns false when it could only copy — the caller should
    /// tell the user the text is on the clipboard rather than pretend it worked.
    @discardableResult
    public static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        // ponytail: plain text only. If someone loses a copied image to a dictation,
        // snapshot every pasteboard item here instead of just the string.
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard isTrusted else { return false }

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        if let previous {
            // Give the target app time to read the pasteboard before we put it back.
            // ponytail: fixed delay; if an app ever pastes the old clipboard instead,
            // poll NSPasteboard.changeCount rather than lengthening this.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard pasteboard.string(forType: .string) == text else { return }
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        return true
    }
}

#endif
