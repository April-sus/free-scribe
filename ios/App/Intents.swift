import AppIntents
import SwiftUI
import WhisperFlowCore

/// What the Action button runs.
///
/// iOS has no way to hand an app a button press directly; what it has is Shortcuts,
/// and the Action button can run a shortcut. So dictation is offered as an intent,
/// and the button, Control Centre, the Lock Screen, Back Tap and "Hey Siri" all get
/// it for free.
///
/// It toggles rather than starting: one press to speak, another to stop. A press is
/// all the Action button gives — there is no release event to end a dictation with,
/// so it cannot be held for the length of a sentence the way the keyboard's
/// microphone is.
///
/// It does not bring Free Scribe forward while the microphone is already open for the
/// keyboard: the stream exists, and starting to keep it needs nothing from the
/// foreground. That is the whole trick — dictating without leaving what you are
/// typing in. When nothing is open, there is no stream to keep and iOS will not let a
/// background app start one, so the app has to come forward for that press only.
struct DictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Dictate"
    static var description = IntentDescription(
        "Dictate without leaving the app you are in. Run it again to stop, transcribe, and insert."
    )

    static var openAppWhenRun = false

    /// Runs in the background, and comes forward only when it has to. `.dynamic`
    /// means the intent decides at run time rather than always opening the app.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Every guard lives in `toggleDictation`, so a press means the same thing
        // however it arrives: a second press ends the dictation, a press during
        // transcription waits its turn, a press against a recorder that has died
        // starts cleanly, and one that runs too long ends itself.
        let state = AppState.shared
        var answer = state.toggleDictation(foreground: UIApplication.shared.applicationState == .active)

        // No stream open and not on screen: the one case that needs the app. It comes
        // forward without asking, then starts. This used to throw
        // `needsToContinueInForegroundError`, whose confirmation defaults on — iOS
        // reported that as "This action is not allowed" and the press did nothing.
        if answer.isEmpty, #available(iOS 26.0, *) {
            if systemContext.currentMode.canContinueInForeground {
                try await continueInForeground(alwaysConfirm: false)
                answer = state.toggleDictation(foreground: true)
            }
        }
        Diagnostics.log("intent: dictate — \(answer.isEmpty ? "nothing to record into" : answer)")

        // Deliberately no dialog. Shortcuts puts a result snippet on screen and waits
        // for Done, so the second press of a two-press dictation could not be made
        // until the first had been dismissed. The knock of the haptic says it started
        // and the insertion says it finished; neither needs acknowledging.
        return .result()
    }
}

/// Stops a dictation and throws it away — for a press that started something you did
/// not mean to start, or one that never came back.
struct CancelDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel dictation"
    static var description = IntentDescription("Stop recording and discard it, without transcribing.")

    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.cancelDictation()
        return .result()
    }
}

/// Arms the microphone for the keyboard, which is the other thing worth a button:
/// it is the one trip to the app that keyboard dictation needs.
struct ReadyForKeyboardIntent: AppIntent {
    static var title: LocalizedStringResource = "Ready the keyboard"
    static var description = IntentDescription(
        "Let the Free Scribe keyboard dictate, without opening the app by hand."
    )

    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppState.shared.startListening()
        return .result()
    }
}

/// Puts the last thing dictated back on the clipboard.
struct CopyLastIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy last dictation"
    static var description = IntentDescription("Copy the most recent transcript to the clipboard.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let latest = History.load().entries.first else { return .result() }
        UIPasteboard.general.string = latest.text
        Sounds.play(.copied)
        return .result()
    }
}

/// Makes the intents findable in Shortcuts and Spotlight without the user building
/// anything, which is what the Action button setup then points at.
struct FreeScribeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: ["Dictate with \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: ReadyForKeyboardIntent(),
            phrases: ["Ready the \(.applicationName) keyboard"],
            shortTitle: "Ready the keyboard",
            systemImageName: "keyboard"
        )
        AppShortcut(
            intent: CancelDictationIntent(),
            phrases: ["Cancel \(.applicationName) dictation"],
            shortTitle: "Cancel dictation",
            systemImageName: "xmark.circle"
        )
        AppShortcut(
            intent: CopyLastIntent(),
            phrases: ["Copy my last \(.applicationName) dictation"],
            shortTitle: "Copy last dictation",
            systemImageName: "doc.on.doc"
        )
    }
}
