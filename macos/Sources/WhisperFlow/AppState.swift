import AppKit
import Foundation
import SwiftUI
import WhisperFlowCore

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case recording
        case transcribing
        case error(String)

        var isBusy: Bool {
            switch self {
            case .idle, .error: false
            default: true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// Recent loudness values driving the waveform in the pill.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var lastTranscript = ""
    @Published var needsSetup: Bool
    /// Local-only usage totals. Loaded once, written after each dictation.
    @Published var stats = Stats.load()
    /// Recent transcripts, so one can be copied again. Kept in memory for the
    /// session; only written to disk when `keepHistory` is on.
    @Published var history = History()
    /// Set briefly after a copy, so the board can confirm it happened.
    @Published var toast: String?

    /// The app delegate needs to reach this from outside the SwiftUI scene.
    static let shared = AppState()

    let machine = MachineInfo.probe()
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private lazy var pill = PillWindow()
    private var hotkey: Hotkey?

    // MARK: Settings (empty string means "decide automatically")

    @AppStorage("model") var modelOverride = "" { didSet { Task { await reloadModel() } } }
    @AppStorage("language") var language = "en"
    /// CoreAudio UID of the chosen microphone; empty means the system default.
    @AppStorage("inputDevice") var inputDevice = ""
    @AppStorage("style") private var styleRaw = DictationStyle.tidy.rawValue
    /// Scribe mode only: let the student say "capital y" to get an uppercase letter.
    @AppStorage("spokenCapitals") var spokenCapitals = true
    /// Cues while the window is hidden, which is most of the time.
    @AppStorage("sounds") var soundsEnabled = true {
        didSet { Sounds.enabled = soundsEnabled }
    }
    /// Keeping the audio is what makes a transcript redoable. Deleting it is always
    /// available regardless of this, since it is a recording of a person.
    @AppStorage("keepAudio") var keepAudio = true {
        didSet { if !keepAudio { AudioCache.clear() } }
    }

    var style: DictationStyle {
        get { DictationStyle(rawValue: styleRaw) ?? .tidy }
        set { styleRaw = newValue.rawValue }
    }
    /// Until the user has dismissed the window once, every launch shows it — a
    /// menu-bar app that opens to nothing at all reads as a failed launch.
    @AppStorage("seenWelcome") var seenWelcome = false

    /// The model this machine should run, honouring a manual override.
    var activeModel: String {
        modelOverride.isEmpty ? ModelPicker.automatic(for: machine) : modelOverride
    }

    init() {
        needsSetup = !Transcriber.isDownloaded(ModelPicker.automatic(for: MachineInfo.probe()))
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            levels.append(level)
            if levels.count > 48 { levels.removeFirst(levels.count - 48) }
        }
        history = History.load()
        Sounds.enabled = soundsEnabled
        hotkey = Hotkey(state: self)

        if needsSetup || !seenWelcome {
            Task { @MainActor in MainWindow.show(self) }
        }
        if !needsSetup {
            Task { await prepareModel() }
        }
    }

    // MARK: Model

    /// Downloads (if needed) and loads the active model, reporting progress into `phase`.
    func prepareModel() async {
        let model = activeModel
        do {
            try await transcriber.load(model: model) { [weak self] phase in
                Task { @MainActor in
                    guard let self, !self.isRecordingOrTranscribing else { return }
                    switch phase {
                    case .downloading(let fraction): self.phase = .downloading(fraction)
                    case .loading: self.phase = .loading
                    case .ready, .idle: self.phase = .idle
                    }
                }
            }
            needsSetup = false
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func reloadModel() async {
        await transcriber.unload()
        await prepareModel()
    }

    private var isRecordingOrTranscribing: Bool {
        phase == .recording || phase == .transcribing
    }

    // MARK: Dictation

    /// Bumped whenever a dictation starts or is abandoned. A transcription that
    /// finishes late compares its token against this before touching any state —
    /// without it, a slow transcription completing after the next recording began
    /// would reset `phase` to idle mid-recording, and the release would then be
    /// ignored, leaving the engine running with no way to stop it.
    private var generation = 0
    private var transcription: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    func startDictation() {
        // The recorder is the source of truth for "already going", not `phase`,
        // which an error or a late task can leave out of step.
        guard !recorder.isRecording else { return }
        guard !needsSetup else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Speaking again while the last one is still working is the user saying
        // "forget that, take this instead" — so drop it rather than making them wait.
        if phase == .transcribing { cancelTranscription(message: nil) }

        generation += 1
        Task {
            guard await ensureMicrophone() else {
                phase = .error(RecorderError.microphoneDenied.errorDescription ?? "No microphone access")
                pill.flash(self)
                return
            }
            do {
                levels.removeAll()
                // Read at start time so a device change takes effect on the next
                // dictation without restarting anything.
                recorder.inputDeviceUID = inputDevice
                try recorder.start()
                phase = .recording
                Sounds.play(.started)
                pill.show(self)
            } catch {
                phase = .error(error.localizedDescription)
                pill.flash(self)
            }
        }
    }

    func finishDictation() {
        // Keyed off the recorder, not `phase`: if anything knocked `phase` out of
        // step the engine would otherwise keep running with the tap installed, and
        // the next dictation would transcribe both recordings glued together.
        guard recorder.isRecording else { return }
        let samples = recorder.stop()
        guard !samples.isEmpty else {
            phase = .idle
            pill.hide()
            return
        }

        phase = .transcribing
        let token = generation
        let seconds = Double(samples.count) / Recorder.sampleRate
        // Held locally, not read back off `self`: by the time this task finishes,
        // `watchdog` may already belong to a newer dictation.
        let ownWatchdog = startWatchdog(for: token, audioSeconds: seconds)

        transcription = Task {
            defer { ownWatchdog.cancel() }
            do {
                // First dictation after launch may still be loading the model.
                if await transcriber.loadedModel == nil { await prepareModel() }
                let spoken = try await transcriber.transcribe(samples: samples, language: language.isEmpty ? nil : language)
                let text = await Cleanup.apply(spoken, style: style, spokenCapitals: spokenCapitals)

                guard token == generation else { return }

                guard !text.isEmpty else {
                    phase = .error("Didn't catch that — nothing was heard")
                    Sounds.play(.failed)
                    pill.flash(self, seconds: 2)
                    return
                }
                stats.record(spoken: spoken, seconds: seconds)
                stats.save()

                if let transcript = history.record(text, style: style) {
                    // Stored under the transcript's own id, so the board knows which
                    // recording belongs to which line.
                    if keepAudio { AudioCache.store(samples, id: transcript.id) }
                    history.save()
                }
                Sounds.play(.inserted)
                lastTranscript = text
                if !Paste.insert(text) {
                    phase = .error("Copied to clipboard — grant Accessibility to paste automatically")
                    Paste.requestTrust()
                    pill.flash(self)
                    return
                }
                phase = .idle
                pill.hide()
            } catch is CancellationError {
                // Already handled by whoever cancelled us — cancelling again here
                // would overwrite their message with a vaguer one.
                await transcriber.clearState()
            } catch {
                guard token == generation else { return }
                await transcriber.clearState()
                Sounds.play(.failed)
                phase = .error("Something went wrong transcribing that — press the shortcut to try again")
                pill.flash(self)
            }
        }
    }

    /// Stops the current transcription dead. Nothing is left running in the
    /// background: the task is cancelled, WhisperKit unwinds at its next
    /// cancellation check, and the generation bump makes any late result a no-op.
    ///
    /// - Parameter message: what to show, or nil when the user is replacing this
    ///   dictation with a new one and does not need telling.
    func cancelTranscription(message: String?) {
        watchdog?.cancel()
        transcription?.cancel()
        transcription = nil
        generation += 1

        if let message {
            phase = .error(message)
            pill.flash(self)
        } else {
            phase = .idle
        }
    }

    /// A transcription that never finishes must not leave the app stuck in
    /// `.transcribing`. The budget scales with the recording, because a long
    /// dictation legitimately takes longer than a short one.
    @discardableResult
    private func startWatchdog(for token: Int, audioSeconds: Double) -> Task<Void, Never> {
        let budget = max(15, audioSeconds * 6)
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(budget))
            guard !Task.isCancelled, token == generation, phase == .transcribing else { return }
            cancelTranscription(message: "That took too long to transcribe and was cancelled — press the shortcut to try again")
        }
        watchdog = task
        return task
    }

    private func ensureMicrophone() async -> Bool {
        Recorder.microphoneAuthorized ? true : await Recorder.requestMicrophoneAccess()
    }

    // MARK: Menu bar

    var statusSymbol: String {
        switch phase {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing, .loading: "waveform"
        case .downloading: "arrow.down.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch phase {
        case .idle: needsSetup ? "Setup needed" : "Ready · \(ModelPicker.label(for: activeModel))"
        case .downloading(let fraction): "Downloading model… \(Int(fraction * 100))%"
        case .loading: "Loading model…"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .error(let message): message
        }
    }
}


// MARK: - Transcript board

extension AppState {
    /// Copies an earlier transcript and confirms it, since a click with no feedback
    /// leaves you wondering whether it worked.
    func copyToClipboard(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
        Sounds.play(.copied)
        show(toast: "Copied to your clipboard — paste it wherever you like")
    }

    func delete(_ transcript: Transcript) {
        history.remove(transcript.id)
        history.save()
        show(toast: "Deleted, along with its recording")
    }

    func clearHistory() {
        history.removeAll()
        History.erase()
        show(toast: "History and recordings cleared")
    }

    func clearAudioCache() {
        AudioCache.clear()
        objectWillChange.send()
        show(toast: "Recordings deleted — transcripts kept")
    }

    /// Runs the original recording through again. The text it produced first time is
    /// replaced only if the second attempt actually yields something.
    func retranscribe(_ transcript: Transcript) {
        guard transcript.canRetranscribe else {
            Sounds.play(.failed)
            show(toast: "Audio transcription failed — that recording is no longer stored")
            return
        }

        Task {
            do {
                if await transcriber.loadedModel == nil { await prepareModel() }
                let spoken = try await transcriber.transcribe(
                    path: AudioCache.url(for: transcript.id).path,
                    language: language.isEmpty ? nil : language
                )
                let text = await Cleanup.apply(spoken, style: style, spokenCapitals: spokenCapitals)

                guard !text.isEmpty else {
                    Sounds.play(.failed)
                    show(toast: "Audio transcription failed — nothing could be made out")
                    return
                }

                history.update(transcript.id, text: text)
                history.save()
                Sounds.play(.inserted)
                show(toast: "Transcribed again from the original recording")
            } catch {
                Sounds.play(.failed)
                show(toast: "Audio transcription failed — \(error.localizedDescription)")
            }
        }
    }

    private func show(toast message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}
