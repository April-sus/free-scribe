import AVFoundation
import Foundation
import SwiftUI
import UIKit
import WhisperFlowCore

/// Everything the iOS app knows, and the port of what the Mac keeps in its own
/// AppState — the same settings, history, statistics and recordings, minus the
/// parts of the Mac that cannot exist here.
///
/// What is missing is missing for a reason:
/// - **Pasting** is the keyboard's job. iOS gives no app a way to type into another.
/// - **Microphone choice** does not exist: iOS routes audio itself.
/// - **Translation** cannot be the same translator: the MADLAD sidecar is a
///   separate program and iOS has no subprocesses, so Apple's framework stands in.
///   See `AppleTranslator` for what that costs.
@MainActor
final class AppState: ObservableObject {
    /// One instance, because an App Intent has to reach the same state the screen is
    /// showing: the Action button runs its intent inside this app, and it must start
    /// the same microphone the Dictate tab would.
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastTranscript = ""
    @Published var history = History.load()
    @Published var stats = Stats.load()
    @Published var toast: String?
    /// Words the recogniser gets wrong, and is told about beforehand.
    @Published var vocabulary = Vocabulary.load()
    /// Whether the microphone is being held open for the keyboard.
    @Published private(set) var listening = false
    /// Whether the microphone is open right now for a dictation in the app.
    @Published private(set) var recording = false
    /// When the current session ends, if it ends.
    @Published private(set) var sessionEnds: Date?
    /// The model being fetched, if one is. Nothing else may be started while it is
    /// set, and pressing Download again while it runs would start a second fetch of
    /// the same files over the top of the first.
    @Published private(set) var downloadingModel: String?
    /// Loudness of what the microphone is hearing, for the ring around the button.
    @Published private(set) var level: Float = 0

    let machine = MachineInfo.probe()
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    let translator = AppleTranslator()
    private var heartbeat: Timer?
    private var expiry: Timer?
    private var lastPublished = Date.distantPast
    private var watchdog: Timer?
    private var lastToggle = Date.distantPast

    /// Nothing anybody says in one go is longer than this, and a recording that never
    /// ends is a microphone left open by a press whose partner never came.
    private static let longestDictation: TimeInterval = 120
    private var downloadTask: Task<URL, Error>?
    private var wired = false

    // MARK: Settings — the same keys the Mac uses, in the shared container so the
    // keyboard can read them too.

    @AppStorage("model", store: .shared) var modelOverride = "" { didSet { Task { await reloadModel() } } }
    @AppStorage("language", store: .shared) var language = "en"
    @AppStorage("style", store: .shared) private var styleRaw = DictationStyle.tidy.rawValue
    @AppStorage("spokenCapitals", store: .shared) var spokenCapitals = true
    /// What "Translate as I speak" translates into.
    @AppStorage("translateTo", store: .shared) var translateTo = "fr"
    @AppStorage("sounds", store: .shared) var soundsEnabled = true {
        didSet { Sounds.enabled = soundsEnabled }
    }
    @AppStorage("keepAudio", store: .shared) var keepAudio = true {
        didSet { if !keepAudio { AudioCache.clear() } }
    }
    @AppStorage("unlimitedAudio", store: .shared) var unlimitedAudio = false
    /// How long a dictation session lasts, in minutes, or 0 to run until turned off.
    ///
    /// A session is the window in which the app holds the microphone for the
    /// keyboard. iOS will not let a background app open one on demand, so keyboard
    /// dictation costs an open microphone — but it need not cost one all day, and
    /// this is what stops it: the session ends itself.
    @AppStorage("sessionMinutes", store: .shared) var sessionMinutes = 15
    /// A model the user asked for and has not got yet. Kept across launches so a
    /// download interrupted by leaving, or by the app being closed, picks itself up
    /// rather than waiting to be asked again.
    @AppStorage("pendingDownload", store: .shared) private var pendingDownload = ""

    var audioLimit: Int? { unlimitedAudio ? nil : AudioCache.defaultLimit }

    var style: DictationStyle {
        get { DictationStyle(rawValue: styleRaw) ?? .tidy }
        set { styleRaw = newValue.rawValue }
    }

    var activeModel: String {
        modelOverride.isEmpty ? ModelPicker.automatic(for: machine) : modelOverride
    }

    var needsSetup: Bool { !installed.models.contains(activeModel) }

    /// What is on disk, looked at when something might have changed rather than
    /// whenever the screen redraws.
    ///
    /// Every one of these answers costs a handful of `fileExists` calls, and they
    /// used to be asked from inside SwiftUI bodies — including one that redraws with
    /// the level meter, twenty times a second while dictating.
    struct Installed {
        var models: Set<String> = []
        var bundled: String?
        var audioBytes: Int64 = 0
        var keyboardInstalled = false
        var keyboardFullAccess = false
    }

    @Published private(set) var installed = Installed()

    func refreshInstalled() {
        var found: Set<String> = []
        for model in ModelPicker.catalog where Transcriber.isDownloaded(model.id) {
            found.insert(model.id)
        }
        installed = Installed(
            models: found,
            bundled: Transcriber.bundled(Transcriber.bundledModel) != nil ? Transcriber.bundledModel : nil,
            audioBytes: AudioCache.bytesUsed(),
            keyboardInstalled: Handoff.keyboardInstalled,
            keyboardFullAccess: Handoff.keyboardHasFullAccess
        )
    }

    init() {
        Sounds.enabled = soundsEnabled

        // A phone call, Siri, or another app taking the microphone. Without this the
        // app sits in "listening" with a stream that has been taken away from it.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began
            else { return }
            Task { @MainActor in
                guard AppState.shared.recording else { return }
                Diagnostics.log("app: interrupted mid-dictation, keeping what was said")
                AppState.shared.stopTalking()
            }
        }

        recorder.onLevel = { [weak self] level in
            // Smoothed, or the ring flickers on every buffer.
            guard let self else { return }
            self.level = self.level * 0.6 + level * 0.4

            // Handed to the keyboard as well, which is drawing the same sound while
            // the app is out of sight. Only while a dictation is actually being kept:
            // the microphone stays open between them, and publishing the room's noise
            // would draw a meter that moves when nobody is talking.
            let now = Date()
            if now.timeIntervalSince(self.lastPublished) > 0.05 {
                self.lastPublished = now
                Handoff.publish(level: self.recording ? self.level : 0)
            }
        }
    }

    /// Set by the Action button's shortcut: a dictation started from outside the app
    /// has nowhere to put its text unless the keyboard happens to be on screen, so it
    /// goes to the clipboard as well. Not done for every dictation — the keyboard's
    /// own would then trample whatever the user had copied.
    var copyNextTranscript = false

    /// Whether a dictation has been taken in the app itself. The last step of the
    /// first run is doing one, and going off to Settings and back must not undo it.
    @AppStorage("practised", store: .shared) var practised = false

    /// How the user dictates outside the app: "keyboard", or "both" for the keyboard
    /// with the Action button as a shortcut to it. Never the button alone — only the
    /// keyboard on screen can type into another app, so without it the button can
    /// only copy. Chosen during setup; decides which steps setup asks for.
    @AppStorage("setupMethod", store: .shared) var setupMethod = "both"

    /// Shows the debug tools in Settings. Off unless someone goes looking.
    @AppStorage("debugMode", store: .shared) var debugMode = false

    func loadedModelName() async -> String? { await transcriber.loadedModel }

    /// What is left to do before dictation works, in the order it has to be done.
    /// Empty when the app is ready, and gone from the screen with it.
    ///
    /// One list, used by both the first run and the checklist that catches whatever
    /// it skipped, so the two can never disagree about what is outstanding.
    var setupSteps: [(title: String, detail: String, done: Bool)] {
        let all: [(title: String, detail: String, done: Bool)] = [
            ("Allow the microphone", "Free Scribe cannot hear you without it.", Recorder.microphoneAuthorized),
            ("Download the speech model", "\(ModelPicker.label(for: activeModel)), \(ModelPicker.size(for: activeModel)). It runs on the phone; nothing you say is sent anywhere.", installed.models.contains(activeModel)),
            ("Add the Free Scribe keyboard", "Settings › General › Keyboard › Keyboards › Add New Keyboard.", installed.keyboardInstalled),
            ("Turn on Allow Full Access", "The keyboard needs it to read what Free Scribe transcribed. Nothing leaves the phone either way.", installed.keyboardFullAccess),
        ]
        return all
    }

    // MARK: Holding the microphone for the keyboard

    /// The keyboard cannot record — no app extension can, on any audio API — so the
    /// app dictates on its behalf.
    ///
    /// The microphone is opened here, in the foreground, and stays open while the app
    /// is on duty — iOS will not let a background app start audio input, so a stream
    /// that will be wanted later has to exist before the app is left. Nothing spoken
    /// is kept until the keyboard asks for it.
    func startListening() {
        guard !listening else { return }
        do {
            try recorder.start()
            recorder.pause()
            listening = true
            Handoff.setListening(true)
            beat()
            extendSession()
        } catch {
            phase = .error(error.localizedDescription)
            Diagnostics.log("app: record failed \(error)")
        }
    }

    func stopListening() {
        guard listening else { return }
        // A dictation still running when the window closes is finished properly
        // rather than left half-done with the stream pulled from under it.
        if recording { stopTalking() }
        _ = recorder.stop()
        heartbeat?.invalidate()
        expiry?.invalidate()
        listening = false
        sessionEnds = nil
        Handoff.sessionEnds = nil
        Handoff.setListening(false)
    }

    /// Pushes the end of the session back. Called when a session starts and after
    /// every dictation, so a session in use does not expire under the user, and one
    /// that is finished with closes itself.
    func extendSession() {
        expiry?.invalidate()
        guard sessionMinutes > 0 else {
            sessionEnds = nil
            Handoff.sessionEnds = nil
            return
        }

        let ends = Date().addingTimeInterval(Double(sessionMinutes) * 60)
        sessionEnds = ends
        Handoff.sessionEnds = ends
        expiry = Timer.scheduledTimer(withTimeInterval: ends.timeIntervalSinceNow, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.stopListening() }
        }
    }

    /// The keyboard decides whether the app is alive by how fresh the flag is, so a
    /// live app has to keep saying so.
    private func beat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Handoff.setListening(true)
        }
    }

    func wire() {
        guard !wired else { return }
        wired = true

        // The keyboard's press and release go through the same two methods as the
        // app's own button, so they share the warm-up, the watchdog and the silent
        // start. This used to be a copy of them — one that played the start beep
        // into the open microphone and had no watchdog.
        Handoff.observe(Handoff.start) { [weak self] in
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.startTalking()
            }
        }
        Handoff.observe(Handoff.stop) { [weak self] in
            Task { @MainActor in self?.stopTalking() }
        }
    }

    /// What one press of the Action button does, and the answer to give back.
    ///
    /// An empty string means "cannot start from here" — the caller decides whether
    /// that is worth interrupting the user for.
    func toggleDictation(foreground: Bool) -> String {
        // The button is easy to press twice. A second press inside a moment is the
        // same press, not a change of mind.
        guard Date().timeIntervalSince(lastToggle) > 0.35 else { return "One moment" }
        lastToggle = Date()

        // We think we are recording and the recorder disagrees: something died under
        // us. Clear it rather than refusing every press from here on.
        if recording, !recorder.isRecording {
            Diagnostics.log("app: recording state was stuck with no recorder, clearing it")
            recording = false
            phase = .idle
        }

        if recording {
            copyNextTranscript = true
            stopTalking()
            return "Transcribing"
        }

        if phase == .transcribing {
            return "Still working on the last one"
        }

        // A press that could not start anything was not a press: it must not make the
        // next one — the retry after coming forward — look like a double-tap.
        guard listening || foreground else {
            lastToggle = .distantPast
            return ""
        }

        // Started with the app on screen: open the stream for the keyboard window as
        // well, so the next press works from wherever the user goes back to. Without
        // this every other press failed — the stream lived only while the app was in
        // front, and was gone by the time the button was pressed again from Messages.
        // The window closes itself after `sessionMinutes` unused.
        if !listening { startListening() }

        copyNextTranscript = true
        startTalking()
        // `startTalking` sets an error phase rather than throwing, so the answer is
        // whatever it decided rather than an assumption that it worked.
        if case .error(let message) = phase { return message }
        return "Listening — press again when you have finished"
    }

    /// Abandons a dictation and puts everything back to idle. Nothing is transcribed
    /// and nothing is inserted.
    func cancelDictation() {
        watchdog?.invalidate()
        if recorder.isRecording {
            _ = listening ? recorder.endSegment() : recorder.stop()
        }
        recording = false
        level = 0
        copyNextTranscript = false
        Handoff.publish(level: 0)
        phase = .idle
        Sounds.play(.failed)
    }

    /// Hold-to-talk inside the app. The microphone is opened by the press and closed
    /// by the release — allowed here, and only here, because iOS lets an app start
    /// audio input when it is in the foreground.
    func startTalking() {
        guard !recording else { return }

        // While the keyboard is being listened for, the stream is already open and
        // being ignored — so this starts keeping it rather than opening a second one.
        // Without this branch, holding the button in the app did nothing at all
        // whenever keyboard dictation was on.
        if listening {
            recorder.beginSegment()
            recording = true
            phase = .recording
            // Haptic only. The cue used to play into an open microphone and the
            // recogniser transcribed it as "(beeping)".
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            armWatchdog()
            return
        }

        do {
            try recorder.start()
            recording = true
            phase = .recording
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            armWatchdog()
        } catch {
            phase = .error(error.localizedDescription)
            Diagnostics.log("app: could not open the microphone \(error)")
        }
    }

    /// Ends a dictation that nobody ended. Two minutes of one is either a pocket or
    /// a press that never came back; either way the microphone should not stay open.
    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.longestDictation, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.recording else { return }
                Diagnostics.log("app: dictation ran past \(Int(Self.longestDictation))s, ending it")
                self.stopTalking()
            }
        }
    }

    func stopTalking() {
        guard recording else { return }
        watchdog?.invalidate()
        recording = false
        level = 0
        Handoff.publish(level: 0)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()

        // Keep the stream open if it is being held for the keyboard; close it if this
        // dictation is the only reason it was open.
        let samples = listening ? recorder.endSegment() : recorder.stop()
        if samples.isEmpty, recorder.lastRecordingWasDead {
            phase = .error(RecorderError.deadDevice.errorDescription ?? "The microphone produced nothing")
            Sounds.play(.failed)
            return
        }
        Task { await dictate(samples) }
    }

    // MARK: Dictation

    /// Transcribes a segment and leaves it where the keyboard will find it.
    func dictate(_ samples: [Float]) async {
        guard !samples.isEmpty else {
            phase = .idle
            return
        }

        phase = .transcribing
        // No-op once loaded; covers a dictation taken while the model is still coming.
        await prepareModel()

        let seconds = Double(samples.count) / Recorder.sampleRate
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.map(\.portType.rawValue)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        Diagnostics.log("app: dictate \(String(format: "%.1f", seconds))s, \(samples.count) samples, peak \(String(format: "%.4f", peak)), input \(route), model \(activeModel) loaded \(await transcriber.loadedModel ?? "none")")
        do {
            let spoken = try await transcriber.transcribe(
                samples: samples,
                language: language.isEmpty ? nil : language
            )
            Diagnostics.log("app: whisper returned \(spoken.count) characters: \(spoken.prefix(80))")
            var text = await Cleanup.apply(spoken, style: style, spokenCapitals: spokenCapitals)

            // Kept so the history can show what was actually said beside what was
            // inserted — being able to check it is the point of the mode.
            var original: String?
            if style == .translated, !text.isEmpty {
                let source = language.isEmpty ? (Languages.systemDefault() ?? "en") : language
                guard let translated = await translator.translate(text, from: source, to: translateTo),
                      !translated.isEmpty else {
                    Sounds.play(.failed)
                    phase = .error("Could not translate that — what you said was not inserted")
                    return
                }
                original = text
                text = translated
            }

            // Whisper labels non-speech in brackets — "(beeping)", "[MUSIC PLAYING]" —
            // and `clean` strips those to nothing. Saying what it heard beats saying
            // nothing was heard, which sounds like the microphone failed.
            let noise = spoken.trimmingCharacters(in: .whitespaces)
            let heardNoise = !noise.isEmpty && text.isEmpty

            guard !text.isEmpty else {
                Diagnostics.log("app: nothing heard — peak \(String(format: "%.4f", peak)) against gate \(Transcriber.silenceThreshold), input was \(recorder.lastInputFormat)")
                Self.keepForInspection(samples)
                keepFailure("Nothing could be made out", samples: samples)
                phase = .error(heardNoise
                    ? "That came through as a sound rather than speech — try again a little closer"
                    : "Didn't catch that — nothing was heard")
                Sounds.play(.failed)
                return
            }

            stats.record(spoken: spoken, seconds: seconds)
            stats.save()

            if let transcript = history.record(text, style: style, original: original) {
                if keepAudio { AudioCache.store(samples, id: transcript.id, keepingLast: audioLimit) }
                history.save()
            }
            lastTranscript = text
            practised = true
            // From the Action button, not the keyboard's own mic. A background app
            // the button relaunched can flash itself to the foreground to open the
            // mic, which is enough to lapse the keyboard's visibility heartbeat for a
            // moment even though the user never left it — so whether the keyboard
            // looks present is judged again here, after transcription, and can come
            // out wrong in either direction from how it looked when the button was
            // pressed. The clipboard is written regardless of that judgement: a spare
            // copy nobody needed costs nothing, and it is the difference between
            // "pasted" and "gone" when the judgement is wrong. The keyboard's own
            // dictation (`copyNextTranscript` never set) always has a live proxy to
            // type into, so it alone leaves the clipboard untouched.
            let fromActionButton = copyNextTranscript
            let keyboardLikelyTyped = Handoff.keyboardIsVisible
            if fromActionButton {
                UIPasteboard.general.string = text
                copyNextTranscript = false
            }
            phase = .idle
            extendSession()
            // "Inserted" would be a lie the user has no way to catch if the keyboard
            // was not actually there to type it — they would just see an empty field
            // with no idea a copy happened instead.
            if fromActionButton, !keyboardLikelyTyped {
                Sounds.play(.copied)
                show(toast: "Copied — paste it in")
            } else {
                Sounds.play(.inserted)
            }
            // The keyboard is waiting on this to type it.
            Handoff.post(Handoff.transcript)
        } catch {
            await transcriber.clearState()
            keepFailure(error.localizedDescription, samples: samples)
            Sounds.play(.failed)
            phase = .error("Something went wrong transcribing that")
            Diagnostics.log("app: transcribe failed \(error)")
        }
    }

    /// Records the failure and keeps the audio behind it, so it can be retried
    /// rather than the attempt vanishing.
    private func keepFailure(_ reason: String, samples: [Float]) {
        let transcript = history.recordFailure(reason, style: style)
        if keepAudio { AudioCache.store(samples, id: transcript.id, keepingLast: audioLimit) }
        history.save()
    }

    /// Writes the samples as a WAV into Documents, so a failed dictation's audio can
    /// be pulled off the phone and run through the same model on a Mac. Diagnostic
    /// only; overwritten by the next failure.
    private static func keepForInspection(_ samples: [Float]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = documents.appending(path: "last-failed.wav")
        let rate: UInt32 = 16000
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + payload)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(payload))
        for sample in samples { put(Int16(max(-1, min(1, sample)) * 32767)) }
        try? data.write(to: url)
        Diagnostics.log("app: kept the audio at \(url.lastPathComponent)")
    }

    // MARK: Model

    func prepareModel() async {
        guard await transcriber.loadedModel != activeModel else { return }
        let model = activeModel
        if !Transcriber.isDownloaded(model) { pendingDownload = model }
        do {
            try await transcriber.load(model: model) { [weak self] phase in
                Task { @MainActor in
                    guard let self else { return }
                    switch phase {
                    case .downloading(let fraction): self.phase = .downloading(fraction)
                    case .loading: self.phase = .loading
                    case .ready, .idle: self.phase = .idle
                    }
                }
            }
            pendingDownload = ""
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func reloadModel() async {
        await transcriber.unload()
        await prepareModel()
    }

    /// Downloads a model without switching to it, so the choice in Settings is a
    /// choice rather than a wait.
    func download(_ model: String) async {
        guard !Transcriber.isDownloaded(model), downloadingModel == nil else { return }

        downloadingModel = model
        pendingDownload = model
        phase = .downloading(0)

        let task = Task {
            try await Transcriber.fetch(model) { [weak self] fraction in
                Task { @MainActor in self?.phase = .downloading(fraction) }
            }
        }
        downloadTask = task
        defer {
            downloadTask = nil
            downloadingModel = nil
        }

        do {
            _ = try await task.value
            pendingDownload = ""
            phase = .idle
            refreshInstalled()
            show(toast: "\(ModelPicker.label(for: model)) is ready to use")
        } catch is CancellationError {
            // Stopped on purpose: the bytes stay on disk so Download picks up where
            // this left off, but nothing resumes it behind the user's back.
            pendingDownload = ""
            phase = .idle
            show(toast: "Download stopped — what it got is kept for next time")
        } catch {
            // Interrupted rather than abandoned. `pendingDownload` still names the
            // model, so it resumes when the app comes back.
            phase = .idle
            Diagnostics.log("app: download of \(model) stopped — \(error.localizedDescription)")
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Called when the app comes back. Finishes whatever was left half-downloaded.
    func resumeDownloads() async {
        guard downloadingModel == nil else { return }

        if !pendingDownload.isEmpty, !Transcriber.isDownloaded(pendingDownload) {
            let model = pendingDownload
            show(toast: "Resuming the download of \(ModelPicker.label(for: model))")
            await download(model)
        } else if !pendingDownload.isEmpty {
            pendingDownload = ""
        }
    }

    /// What a resumed download has already got, for showing beside it.
    var pendingModel: String? { pendingDownload.isEmpty ? nil : pendingDownload }

    func delete(model: String) {
        guard model != activeModel else {
            show(toast: "That is the model in use — choose another one first")
            return
        }
        try? Transcriber.delete(model)
        refreshInstalled()
        show(toast: "\(ModelPicker.label(for: model)) deleted")
    }

    // MARK: Vocabulary

    func addWord(_ word: String) {
        vocabulary.add(word)
        vocabulary.save()
    }

    func removeWord(_ word: String) {
        vocabulary.remove(word)
        vocabulary.save()
    }

    // MARK: History

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

    func copy(_ transcript: Transcript) {
        UIPasteboard.general.string = transcript.text
        Sounds.play(.copied)
        show(toast: "Copied — paste it wherever you like")
    }

    /// Runs the original recording through again. The text it produced first time is
    /// replaced only if the second attempt actually yields something.
    func retranscribe(_ transcript: Transcript) {
        guard transcript.canRetranscribe else {
            Sounds.play(.failed)
            show(toast: "That recording is no longer stored")
            return
        }

        Task {
            await prepareModel()
            do {
                let spoken = try await transcriber.transcribe(
                    path: AudioCache.url(for: transcript.id).path,
                    language: language.isEmpty ? nil : language
                )
                let text = await Cleanup.apply(spoken, style: style, spokenCapitals: spokenCapitals)
                guard !text.isEmpty else {
                    Sounds.play(.failed)
                    show(toast: "Nothing could be made out")
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

    // MARK: Recordings

    func deleteRecordings(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        AudioCache.remove(ids)
        refreshInstalled()
        show(toast: ids.count == 1
            ? "Recording deleted — its transcript is still here"
            : "\(ids.count) recordings deleted — their transcripts are still here")
    }

    func clearAudioCache() {
        AudioCache.clear()
        refreshInstalled()
        show(toast: "Recordings deleted — transcripts kept")
    }

    // MARK: Presentation

    var statusText: String {
        switch phase {
        case .idle: listening ? "Listening for the keyboard" : "Ready · \(ModelPicker.label(for: activeModel))"
        case .downloading(let fraction): "Downloading model… \(Int(fraction * 100))%"
        case .loading: "Loading model…"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .error(let message): message
        }
    }

    func show(toast message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}

extension UserDefaults {
    /// Settings live in the shared container: the keyboard reads the same ones.
    static let shared = UserDefaults(suiteName: Transcriber.appGroup) ?? .standard
}
