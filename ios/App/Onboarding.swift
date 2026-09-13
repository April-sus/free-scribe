import SwiftUI
import WhisperFlowCore

/// The first run, which is the only chance to explain why a dictation app that
/// sends nothing anywhere asks for so much before it says a word.
///
/// Four of the steps cannot be done by the app at all — permission, a download, a
/// keyboard added in Settings, Full Access granted there too — so each says what it
/// is for, and each checks for itself whether it is done rather than taking anyone's
/// word for it. The last one is a dictation, so that the first attempt from the
/// keyboard is not also the first test of whether any of this works.
struct Onboarding: View {
    @ObservedObject var state: AppState
    let finish: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var step = 0
    @State private var askedForMicrophone = false

    var body: some View {
        let steps = steps
        let current = steps[min(step, steps.count - 1)]

        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)

            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: current.symbol)
                        .font(.system(size: 54))
                        .foregroundStyle(current.done && current.action != nil ? .green : Color.accentColor)

                    Text(current.title)
                        .font(.title.bold())
                        .multilineTextAlignment(.center)

                    Text(current.body)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    extras(for: current)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)

            Spacer(minLength: 0)
            footer(current: current, count: steps.count)
        }
        // Three steps are finished in another app, so coming back is the moment to
        // look again rather than asking the user to confirm what they just did.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { state.refreshInstalled() }
        }
        // No button, nothing to choose. And "action" is a choice that no longer
        // exists: the button always works through the keyboard now.
        .onAppear {
            if !MachineInfo.hasActionButton {
                state.setupMethod = "keyboard"
            } else if state.setupMethod == "action" {
                state.setupMethod = "both"
            }
        }
    }

    // MARK: The steps

    /// The keyboard's two steps always, and the Action button's as well when the
    /// phone has one and it was chosen on the method screen.
    private var steps: [Step] {
        let bundled = state.installed.bundled == state.activeModel
        var list = [
            Step(
                kind: .welcome,
                symbol: "waveform",
                title: "Dictation that stays on your phone",
                body: "Speak, and what you said is typed where you were typing. The speech model runs here, on this phone: after the download, nothing you say is sent anywhere. No account, no subscription, nothing to sign in to.",
                action: nil,
                done: true
            ),
            Step(
                kind: .microphone,
                symbol: "mic.fill",
                title: "Let Free Scribe hear you",
                body: "The microphone is used while you dictate, and not otherwise. Recordings stay on the phone, and you can delete them whenever you like.",
                action: Action(title: "Allow the microphone") {
                    askedForMicrophone = true
                    _ = await Recorder.requestMicrophoneAccess()
                    state.objectWillChange.send()
                },
                done: Recorder.microphoneAuthorized
            ),
            Step(
                kind: .model,
                symbol: bundled ? "checkmark.circle" : "arrow.down.circle",
                title: bundled ? "The speech model is already here" : "Download the speech model",
                body: bundled
                    ? "\(ModelPicker.label(for: state.activeModel)) came with the app, so there is nothing to download and nothing to wait for. A more accurate one can be fetched later in Settings if you want it."
                    : "\(ModelPicker.label(for: state.activeModel)), about \(ModelPicker.size(for: state.activeModel)). This is the part that does the listening. It downloads once, keeps going while you do something else, and picks up where it left off if the app closes.",
                // No action while it is running: the button underneath would start the
                // same download a second time.
                action: state.downloadingModel == nil
                    ? Action(title: "Download") { await state.download(state.activeModel) }
                    : nil,
                done: state.installed.models.contains(state.activeModel)
            ),
        ]

        // Only a phone with the button has anything to choose.
        if MachineInfo.hasActionButton {
            list.append(Step(
                kind: .method,
                symbol: "hand.point.up.left",
                title: "How do you want to dictate?",
                body: "Either way the Free Scribe keyboard is needed. iOS lets only the keyboard on screen type into another app, so the Action button can start and stop a dictation, but the keyboard is what types it.",
                action: nil,
                done: true
            ))
        }

        list += [
            Step(
                kind: .keyboard,
                symbol: "keyboard",
                title: "Add the Free Scribe keyboard",
                body: "In Settings: General › Keyboard › Keyboards › Add New Keyboard, then choose Free Scribe. It is an ordinary keyboard with a microphone on it, so you can leave it as your only one.",
                action: Action(title: "Open Settings") { await openSettings() },
                done: state.installed.keyboardInstalled
            ),
            Step(
                kind: .fullAccess,
                symbol: "lock.open",
                title: "Turn on Allow Full Access",
                body: "On that same screen, tap Free Scribe and turn on Allow Full Access.\n\niOS asks about this because a keyboard could send everything you type to a server. This one has nowhere to send it: it needs the switch only to read what Free Scribe transcribed, out of storage the two of them share on this phone.",
                action: Action(title: "Open Settings") { await openSettings() },
                done: state.installed.keyboardFullAccess
            ),
        ]

        if MachineInfo.hasActionButton, state.setupMethod != "keyboard" {
            // iOS offers no way to read what the Action button is set to, so this one
            // cannot tick itself off. It stays a step to do, and Next is how it ends.
            list.append(Step(
                kind: .actionButton,
                symbol: "button.programmable",
                title: "Put dictation on the Action button",
                body: "Press once to start, again to stop, in any app with the Free Scribe keyboard up to type it. Four steps in Settings. Free Scribe cannot see how the button is set, so tap Next once you have done it.",
                action: Action(title: "Open Settings") { await openSettings() },
                done: false
            ))
        }

        list += [
            Step(
                kind: .practice,
                symbol: "text.bubble",
                title: "Try it now",
                body: state.practised
                    ? "That is all there is to it. The same words are in your History, and everything you dictate lands there."
                    : "Hold the button and say a sentence, then let go. Better to find out here than in the middle of a message.",
                action: nil,
                done: state.practised
            ),
            Step(
                kind: .ready,
                symbol: "checkmark.seal.fill",
                title: "Ready",
                body: readyText,
                action: nil,
                done: true
            ),
        ]
        return list
    }

    private var readyText: String {
        let keyboard = "Switch to the Free Scribe keyboard in any app and use its microphone: tap once and speak, then tap the check mark — or hold it while you talk and let go."
        let button = "Or, with the Free Scribe keyboard up, press the Action button, speak, and press it again, and the keyboard types it. With another keyboard up nothing can type it, so it is copied for you to paste."
        let how = "Dictation runs through this app, because iOS gives a keyboard no microphone of its own. The first time, Free Scribe may come forward to switch its microphone on."
        return state.setupMethod == "keyboard"
            ? keyboard + "\n\n" + how
            : keyboard + "\n\n" + button + "\n\n" + how
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation { step -= 1 } }
            }
            Spacer()
            Button("Skip setup", action: finish)
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding()
    }

    /// Whatever the step needs beyond words: a progress bar, a choice, a guide, a
    /// microphone, a warning.
    @ViewBuilder
    private func extras(for current: Step) -> some View {
        switch current.kind {
        case .model:
            if case .downloading(let fraction) = state.phase {
                VStack(spacing: 10) {
                    ProgressView(value: fraction) {
                        Text("\(Int(fraction * 100))% — carry on if you like, it keeps going")
                            .font(.caption)
                    }
                    Button("Cancel", role: .destructive) { state.cancelDownload() }
                        .font(.footnote)
                }
            }
        case .microphone:
            if askedForMicrophone, !Recorder.microphoneAuthorized {
                Text("iOS only asks once. If nothing appeared, turn the microphone on for Free Scribe in Settings › Privacy & Security › Microphone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        case .method:
            MethodPicker(selection: $state.setupMethod)
        case .actionButton:
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ActionButtonGuide.steps, id: \.0) { number, title, detail in
                    HStack(alignment: .top, spacing: 12) {
                        Text(number)
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.callout)
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        case .practice:
            PracticeButton(state: state)
        default:
            EmptyView()
        }
    }

    private func footer(current: Step, count: Int) -> some View {
        VStack(spacing: 14) {
            if let action = current.action {
                if current.done {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Button(action.title) { Task { await action.run() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }

            // Prominent when there is nothing outstanding on this step, quieter when
            // there is: moving on is allowed, but it should not look like the answer.
            let advance = Button(step == count - 1 ? "Start dictating" : "Next") {
                if step == count - 1 { finish() } else { withAnimation { step += 1 } }
            }
            .controlSize(.large)

            if current.done {
                advance.buttonStyle(.borderedProminent)
            } else {
                advance.buttonStyle(.bordered)
            }

            Dots(count: count, current: step)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    private func openSettings() async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        await UIApplication.shared.open(url)
    }

    private enum Kind {
        case welcome, microphone, model, method, keyboard, fullAccess, actionButton, practice, ready
    }

    private struct Step {
        let kind: Kind
        let symbol: String
        let title: String
        let body: String
        let action: Action?
        let done: Bool
    }

    private struct Action {
        let title: String
        let run: () async -> Void
    }
}

// MARK: - The practice dictation

/// The same press-and-hold as the Dictate tab, with the transcript shown underneath
/// and a word about it when nothing was heard.
private struct PracticeButton: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(.quaternary)
                Circle()
                    .stroke(Color.red.opacity(0.55), lineWidth: 5)
                    .scaleEffect(1 + CGFloat(state.level) * 0.35)
                    .opacity(state.recording ? 1 : 0)
                Image(systemName: state.recording ? "waveform" : "mic.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(state.recording ? .red : Color.accentColor)
            }
            .frame(width: 104, height: 104)
            .animation(.easeOut(duration: 0.12), value: state.level)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
                // Never fires: the press only ends by lifting, which `pressing` reports.
            } onPressingChanged: { pressing in
                pressing ? state.startTalking() : state.stopTalking()
            }
            .accessibilityLabel("Hold to talk")

            switch state.phase {
            case .recording:
                Text("Listening — let go when you are done").font(.caption)
            case .transcribing:
                Text("Transcribing…").font(.caption)
            case .downloading, .loading:
                Text("Waiting for the speech model…").font(.caption).foregroundStyle(.secondary)
            case .error(let message):
                Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            case .idle:
                if !state.lastTranscript.isEmpty {
                    Text(state.lastTranscript)
                        .font(.callout)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

/// The keyboard alone, or the keyboard with the Action button as a shortcut to it.
private struct MethodPicker: View {
    @Binding var selection: String

    private let options = [
        ("keyboard", "keyboard", "The keyboard", "Hold its microphone in any app. Types straight into the field you are in."),
        ("both", "button.programmable", "Keyboard and Action button", "Press the button to start and stop instead of reaching for the microphone. The Free Scribe keyboard still does the typing."),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(options, id: \.0) { value, symbol, title, detail in
                Button {
                    selection = value
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.title3)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.callout.weight(.medium))
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selection == value ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection == value ? Color.accentColor : .secondary)
                    }
                    .padding(12)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Where you are in the run of steps.
private struct Dots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
