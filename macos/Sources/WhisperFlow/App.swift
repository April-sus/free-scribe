import SwiftUI
import WhisperFlowCore

/// Opening an app that is already running gives an accessory app no windows and no
/// feedback — it just looks dead. Catch the reopen and show the window instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show(AppState.shared)
        return true
    }
}

struct WhisperFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.statusSymbol)
        }
        // No `Settings` scene on purpose: every option lives in MainWindow so the
        // same UI ports to another platform unchanged.
    }
}

private struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.statusText)

        Divider()

        if state.phase == .recording {
            Button("Stop and insert") { state.finishDictation() }
        } else if state.phase == .transcribing {
            Button("Cancel transcription") {
                state.cancelTranscription(message: "Transcription cancelled")
            }
        } else {
            Button("Start dictation") { state.startDictation() }
                .disabled(state.phase.isBusy)
        }

        if !state.lastTranscript.isEmpty {
            Button("Copy last transcript") { Paste.insert(state.lastTranscript) }
            // The scribe rules let the student ask for the text back — on request only.
            Button(Speaker.isSpeaking ? "Stop reading back" : "Read last text back") {
                Speaker.isSpeaking ? Speaker.stop() : Speaker.readBack(state.lastTranscript)
            }
        }

        Divider()

        // Switching between verbatim and cleaned-up is a per-task decision, so it
        // gets its own row here as well as in the window.
        Picker("Style", selection: Binding(get: { state.style }, set: { state.style = $0 })) {
            ForEach(DictationStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
        .pickerStyle(.inline)

        Divider()

        Button("Settings…") { MainWindow.show(state) }
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Free Scribe") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
