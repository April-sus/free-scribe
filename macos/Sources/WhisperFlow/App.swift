import SwiftUI
import WhisperFlowCore

/// Opening an app that is already running gives an accessory app no windows and no
/// feedback — it just looks dead. Catch the reopen and show the window instead.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runningObserver: NSKeyValueObservation?

    /// Launched directly (build.sh, Xcode, a second double-click of the .app while
    /// one is already running) rather than reopened through the Dock, so LaunchServices'
    /// usual single-instance activation never kicks in — an LSUIElement app has no Dock
    /// icon for that to attach to. Two copies would fight over the hotkey and the mic.
    func applicationWillFinishLaunching(_ notification: Notification) {
        settleInstances()
    }

    /// Exactly one copy may run, and every copy agrees which.
    ///
    /// Checking once at launch was not enough: two copies started together (the
    /// login item and a click, or a rebuild relaunching) could each look before the
    /// other had registered, find nothing, and both stay. So every copy looks at
    /// launch, again once launching has settled, and whenever another copy appears —
    /// and all of them apply the same ranking to the same list, so they reach the
    /// same answer. The winner asks the others to quit; the others quit themselves on
    /// finding they lost. Either alone is enough, which is the point: an old build
    /// that knows nothing of this still gets told.
    private func settleInstances() {
        let me = NSRunningApplication.current
        var copies = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            // A `--transcribe` run of the same binary has no interface. It is a
            // command-line tool, not a second copy, and must never end the app.
            .filter { !$0.isTerminated && $0.activationPolicy != .prohibited }
        if !copies.contains(where: { $0.processIdentifier == me.processIdentifier }) {
            copies.append(me)
        }
        guard copies.count > 1, let keeper = copies.min(by: Self.ranksAhead) else { return }

        if keeper.processIdentifier == me.processIdentifier {
            for other in copies where other.processIdentifier != me.processIdentifier {
                other.terminate()
            }
        } else {
            keeper.activate()
            NSApp.terminate(nil)
        }
    }

    /// A copy running a binary that has been rebuilt since it launched loses to one
    /// that is not; then the newest build; then whichever launched first; then the
    /// lower process id, so there is never a tie.
    ///
    /// The first rule is the one that matters for a rebuild. `build.sh` writes the new
    /// executable over the old in place, so two copies of the same bundle report the
    /// same build date — and without it, the one still running the old code in memory
    /// won on launch order and the new build quit itself.
    private static func ranksAhead(_ a: NSRunningApplication, _ b: NSRunningApplication) -> Bool {
        let staleA = replacedSinceLaunch(a), staleB = replacedSinceLaunch(b)
        if staleA != staleB { return !staleA }
        let builtA = built(a), builtB = built(b)
        if builtA != builtB { return builtA > builtB }
        let launchedA = a.launchDate ?? .distantFuture
        let launchedB = b.launchDate ?? .distantFuture
        if launchedA != launchedB { return launchedA < launchedB }
        return a.processIdentifier < b.processIdentifier
    }

    private static func replacedSinceLaunch(_ app: NSRunningApplication) -> Bool {
        guard let launched = app.launchDate else { return false }
        return launched < built(app)
    }

    private static func built(_ app: NSRunningApplication) -> Date {
        (try? app.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Opening the app opens the window — one click, not two.
    ///
    /// The exception is the launch macOS performs at login, which the user did not
    /// ask for. `launchIsDefaultUserInfoKey` is false for those; SMAppService's own
    /// status is not a usable substitute, since it reports `.enabled` even when the
    /// app is nowhere in Login Items.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Look again once both copies of a simultaneous launch have registered, and
        // whenever another copy is started later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.settleInstances()
        }
        // Key-value observing, not `didLaunchApplicationNotification`: that is not
        // posted for menu-bar-only apps like this one, so a second copy launched
        // later went unnoticed and both kept running. The list itself changes for
        // every app, whatever kind.
        runningObserver = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.settleInstances() }
        }

        let openedByUser = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard openedByUser || AppState.shared.needsSetup else { return }
        MainWindow.show(AppState.shared)
    }

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
