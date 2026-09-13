import SwiftUI
import WhisperFlowCore

/// The Mac's six panes, as the four a phone can carry: dictation and its styles,
/// the transcript history, the statistics, and everything else under Settings.
struct MainView: View {
    @StateObject private var state = AppState.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Shown once, on the first run. Kept in the shared container so reinstalling
    /// the keyboard alone does not bring it back.
    @AppStorage("onboarded", store: .shared) private var onboarded = false
    /// Shown only when the keyboard sent the user here, and dismissed the moment
    /// they leave. Arriving in an app you did not mean to open is disorienting, and
    /// the way back is the one thing worth saying at that moment.
    @State private var handedOver = false

    var body: some View {
        TabView {
            DictatePane(state: state)
                .tabItem { Label("Dictate", systemImage: "mic") }
            HistoryPane(state: state)
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
            StatsPane(state: state)
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            SettingsPane(state: state)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 60)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: state.toast)
        .onOpenURL { _ in
            state.startListening()
            handedOver = true
        }
        .fullScreenCover(isPresented: $handedOver) {
            ReturnHint(state: state) { handedOver = false }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            Onboarding(state: state) { onboarded = true }
        }
        // The session for translating comes from SwiftUI rather than being built:
        // this is what hands one to the translator when the language pair changes.
        .translationTask(state.translator.configuration) { session in
            state.translator.attach(session)
        }
        // A download the phone interrupted picks itself up here, from the bytes it
        // already has, without the user having to remember it was going.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Coming back is when the answers may have changed: a keyboard added
                // in Settings, Full Access granted, a download finished.
                state.refreshInstalled()
                Task { await state.resumeDownloads() }
            } else if state.recording, !state.listening {
                // The app owns this stream and is about to lose the foreground it was
                // opened in. Finish the dictation rather than strand it.
                state.stopTalking()
            }
        }
        .task {
            print("[free-scribe] keyboard log:\n\(Diagnostics.tail())")
            _ = await Recorder.requestMicrophoneAccess()
            state.refreshInstalled()
            state.wire()
            // Armed once, armed on every launch afterwards: the microphone is what the
            // keyboard waits for, and the model can arrive behind it.
            // A session that had not run out when the app was last closed is still
            // the user's session; one that expired is not resurrected.
            if let ends = Handoff.sessionEnds, ends > Date() { state.startListening() }
            await state.translator.loadSupported()
            await state.prepareModel()
            await state.resumeDownloads()
        }
    }
}

// MARK: - Dictate

private struct DictatePane: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(state.statusText)
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    ZStack {
                        Circle().fill(.quaternary)
                        // Grows with what the microphone hears, so a dead microphone or
                        // a voice too quiet to catch is visible rather than guessed at.
                        Circle()
                            .stroke(Color.red.opacity(0.55), lineWidth: 6)
                            // The level is already 0…1 out of `Recorder.rms`, so it
                            // scales the ring directly rather than being stretched.
                            .scaleEffect(1 + CGFloat(state.level) * 0.35)
                            .opacity(state.recording ? 1 : 0)
                        Image(systemName: state.recording ? "waveform" : "mic.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(state.recording ? .red : Color.accentColor)
                    }
                    .frame(width: 130, height: 130)
                    .scaleEffect(state.recording ? 1.06 : 1)
                    .animation(.easeOut(duration: 0.12), value: state.level)
                    .animation(.spring(duration: 0.2), value: state.recording)
                    // Press and release rather than a tap: the microphone opens for
                    // exactly as long as the finger is down. A long press rather than a
                    // drag, because the scrolling view swallows drags.
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: .infinity) {
                // Never fires: the press only ends by lifting, which `pressing` reports.
            } onPressingChanged: { pressing in
                pressing ? state.startTalking() : state.stopTalking()
            }
                    .accessibilityLabel("Hold to talk")

                    Text("Hold to talk. The microphone opens while you hold and closes when you let go.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    // What the last dictation *this session* produced. Without it,
                    // a dictation that worked looked identical to one that did not:
                    // the result went to History and the tab said "Ready".
                    if !state.lastTranscript.isEmpty {
                        Text(state.lastTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
                    }

                    SetupCard(state: state)
                    SessionCard(state: state)


                    StylePicker(state: state)

                }
                .padding()
            }
            .navigationTitle("Free Scribe")
        }
    }
}

private struct StylePicker: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(DictationStyle.allCases) { style in
                Button {
                    state.style = style
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: state.style == style ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(style.label).font(.body)
                            Text(style.detail).font(.caption).foregroundStyle(.secondary)
                            if style == .polished, let reason = Cleanup.polishUnavailableReason {
                                Text(reason).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(style == .polished && !Cleanup.polishAvailable)
                .disabled(style == .translated && state.translator.supported.isEmpty)
            }

            if state.style == .scribe {
                Toggle("Allow spoken capitals", isOn: $state.spokenCapitals)
                    .font(.footnote)
                Text("Lets the student say \"capital y\" for an uppercase letter. Turn it off for the strictest reading of the rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - History

private struct HistoryPane: View {
    @ObservedObject var state: AppState
    @State private var search = ""
    @State private var period = Period.all
    @State private var confirmingClear = false

    private var entries: [Transcript] {
        state.history.matching(search: search, period: period)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $period) {
                        ForEach(Period.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if entries.isEmpty {
                    ContentUnavailableView(
                        state.history.entries.isEmpty ? "Nothing dictated yet" : "Nothing matches",
                        systemImage: "text.bubble"
                    )
                } else {
                    ForEach(entries) { transcript in
                        TranscriptRow(transcript: transcript, state: state)
                    }
                    .onDelete { offsets in
                        for index in offsets { state.delete(entries[index]) }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search transcripts")
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !state.history.entries.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !state.history.entries.isEmpty {
                        Button("Clear", role: .destructive) { confirmingClear = true }
                    }
                }
            }
            .confirmationDialog(
                "Delete every transcript and recording?",
                isPresented: $confirmingClear,
                titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) { state.clearHistory() }
            } message: {
                Text("This cannot be undone. Nothing was ever sent anywhere, so this is the only copy.")
            }
        }
    }
}

private struct TranscriptRow: View {
    let transcript: Transcript
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if transcript.failed {
                Label(transcript.failureReason ?? "Failed", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            } else {
                Text(transcript.text)
            }

            HStack(spacing: 8) {
                Text(transcript.date, style: .time)
                Text(transcript.style)
                if transcript.canRetranscribe {
                    Label("recording kept", systemImage: "waveform")
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        // Copy is the full-swipe action, not delete: a transcript is the only copy
        // there is, and losing one to a careless swipe is not recoverable.
        .swipeActions(edge: .trailing) {
            Button("Copy") { state.copy(transcript) }.tint(.blue)
            if transcript.canRetranscribe {
                Button("Redo") { state.retranscribe(transcript) }.tint(.indigo)
            }
            Button("Delete", role: .destructive) { state.delete(transcript) }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { state.copy(transcript) }
            if transcript.canRetranscribe {
                Button("Transcribe again", systemImage: "arrow.clockwise") { state.retranscribe(transcript) }
                Button("Delete the recording, keep this", systemImage: "waveform.slash") {
                    state.deleteRecordings([transcript.id])
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { state.delete(transcript) }
        }
    }
}

// MARK: - Stats

private struct StatsPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Tile(label: "Words dictated", value: "\(state.stats.words)")
                    Tile(label: "Dictations", value: "\(state.stats.dictations)")
                    Tile(label: "Time spoken", value: state.stats.secondsSpoken.asDuration)
                    Tile(label: "Time saved against typing", value: state.stats.secondsSaved.asDuration)
                    Tile(label: "Speaking speed", value: "\(Int(state.stats.wordsPerMinute)) wpm")
                    Tile(label: "Average dictation", value: "\(state.stats.averageWordsPerDictation) words")
                }

                Section("Last two weeks") {
                    DayChart(days: state.stats.recent(days: 14))
                }

                Section {
                    Button("Reset statistics", role: .destructive) {
                        Stats.erase()
                        state.stats = Stats()
                        state.show(toast: "Statistics reset")
                    }
                } footer: {
                    Text("Counted on this device and kept on it. Nothing here has ever left the phone.")
                }
            }
            .navigationTitle("Stats")
        }
    }
}

private struct Tile: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct DayChart: View {
    let days: [(day: Date, words: Int)]

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days, id: \.day) { day in
                RoundedRectangle(cornerRadius: 2)
                    .fill(day.words == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.accentColor))
                    .frame(height: max(3, CGFloat(day.words) / CGFloat(peak) * 90))
            }
        }
        .frame(height: 90)
        .padding(.vertical, 6)
    }
}

// MARK: - Settings

private struct SettingsPane: View {
    @ObservedObject var state: AppState
    @State private var confirmingAudio = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Spoken language", selection: $state.language) {
                        Text("Detect automatically").tag("")
                        ForEach(Languages.all()) { Text($0.label).tag($0.code) }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("Detecting costs a moment per dictation, so naming the language is quicker if you always speak the same one. Anything but English needs the all-languages model.")
                }

                Section {
                    NavigationLink("Use the Action button") { ActionButtonGuide() }
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("Free Scribe offers Dictate, Ready the keyboard and Copy last dictation to Shortcuts, so anything that can run a shortcut can start a dictation — the Action button, Control Centre, the Lock Screen, Back Tap or Siri.")
                }

                Section {
                    NavigationLink("Words it gets wrong") { VocabularyPane(state: state) }
                } header: {
                    Text("Vocabulary")
                } footer: {
                    Text("Names, places and awkward words the recogniser mangles. It is told to expect them before it listens, and anything that still comes out sounding like one is put right afterwards.")
                }

                ModelSection(state: state)

                Section {
                    Toggle("Keep the audio", isOn: $state.keepAudio)
                    if state.keepAudio {
                        Toggle("Keep every recording", isOn: $state.unlimitedAudio)
                    }
                    LabeledContent("Stored", value: ByteCountFormatter.string(
                        fromByteCount: state.installed.audioBytes, countStyle: .file
                    ))
                    NavigationLink("Manage recordings") { RecordingsPane(state: state) }
                    Button("Delete recordings, keep transcripts", role: .destructive) {
                        confirmingAudio = true
                    }
                } header: {
                    Text("Recordings")
                } footer: {
                    Text("Keeping the audio is what makes a transcript redoable. Off by default beyond the last \(AudioCache.defaultLimit), because recordings of a person add up.")
                }

                Section {
                    Picker("Turn off after", selection: $state.sessionMinutes) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("1 hour").tag(60)
                        Text("Only when I say").tag(0)
                    }
                } header: {
                    Text("Keyboard dictation")
                } footer: {
                    Text("How long Free Scribe stays available to the keyboard after you last use it. iOS gives a keyboard no microphone of its own and will not let an app in the background open one, so Free Scribe holds the microphone while it is available — which is why it turns itself off rather than staying on all day.\n\nWhen it is off, Free Scribe holds no microphone at all, and the keyboard can still type anything already dictated.")
                }

                Section {
                    Toggle("Sound cues", isOn: $state.soundsEnabled)
                } header: {
                    Text("General")
                } footer: {
                    Text("Dictation happens while you are looking at another app, so a cue is often the only sign that anything happened.")
                }

                TranslationSection(state: state)

                DebugSection(state: state)
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Delete the saved recordings?",
                isPresented: $confirmingAudio,
                titleVisibility: .visible
            ) {
                Button("Delete recordings", role: .destructive) { state.clearAudioCache() }
            } message: {
                Text("The transcripts stay. Only the audio behind them goes, and with it the ability to redo them.")
            }
        }
    }
}

/// Models are downloaded when you ask for them, not all at once: the largest is
/// nearly a gigabyte and most people never need it.
private struct ModelSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section("Speech model") {
            Picker("In use", selection: $state.modelOverride) {
                Text("Choose for me (\(ModelPicker.label(for: ModelPicker.automatic(for: state.machine))))").tag("")
                ForEach(ModelPicker.catalog, id: \.id) { model in
                    Text(model.label).tag(model.id)
                }
            }

            ForEach(ModelPicker.catalog, id: \.id) { model in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.label)
                            Text(model.size).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()

                        if state.downloadingModel == model.id {
                            Button("Cancel", role: .destructive) { state.cancelDownload() }
                                .buttonStyle(.borderless)
                        } else if state.installed.bundled == model.id {
                            // Shipped inside the app: nothing to fetch, nothing to free.
                            Text("Included").font(.caption).foregroundStyle(.secondary)
                        } else if state.installed.models.contains(model.id) {
                            Button("Delete", role: .destructive) { state.delete(model: model.id) }
                                .buttonStyle(.borderless)
                        } else {
                            Button("Download") { Task { await state.download(model.id) } }
                                .buttonStyle(.borderless)
                                // One at a time: pressing this again mid-download would
                                // fetch the same files over the top of themselves.
                                .disabled(state.downloadingModel != nil)
                        }
                    }

                    // The bar belongs to the model being fetched, not to the section:
                    // one progress bar under a list of five says nothing about which.
                    if state.downloadingModel == model.id, case .downloading(let fraction) = state.phase {
                        ProgressView(value: fraction) {
                            Text("\(Int(fraction * 100))% — keeps going in the background, and picks up where it left off")
                                .font(.caption)
                        }
                    }
                }
            }

            if state.downloadingModel == nil, let pending = state.pendingModel {
                Button("Resume downloading \(ModelPicker.label(for: pending))") {
                    Task { await state.resumeDownloads() }
                }
            }
        }
    }
}

// MARK: - Recordings

/// Clearing out recordings without clearing all of them — the Mac's storage sheet.
///
/// With unlimited retention on, the cache grows for as long as somebody keeps
/// dictating, so freeing space has to mean more than "delete everything". Grouping
/// by day, month or year lets a year of old recordings go while this week's stay.
private struct RecordingsPane: View {
    @ObservedObject var state: AppState

    @State private var grouping: Grouping = .day
    @State private var selected: Set<UUID> = []
    @State private var recordings = AudioCache.recordings()
    @State private var confirming = false

    private var groups: [RecordingGroup] { grouping.group(recordings) }
    private var selectedBytes: Int64 {
        recordings.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        List {
            Section {
                Picker("Group by", selection: $grouping) {
                    ForEach(Grouping.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if recordings.isEmpty {
                ContentUnavailableView("No recordings stored", systemImage: "waveform.slash")
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.recordings) { recording in
                            Button {
                                toggle(recording.id)
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(recording.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(Color.accentColor)
                                    Text(recording.date, format: .dateTime.hour().minute())
                                    Spacer()
                                    Text(byteLabel(recording.bytes))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Button(allSelected(group) ? "None" : "All") { toggle(group) }
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Text("\(recordings.count) stored, using \(byteLabel(recordings.reduce(0) { $0 + $1.bytes }))")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Delete \(selected.count) selected", role: .destructive) { confirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .confirmationDialog(
            "Delete \(selected.count) recording\(selected.count == 1 ? "" : "s")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                state.deleteRecordings(selected)
                selected.removeAll()
                recordings = AudioCache.recordings()
            }
        } message: {
            Text("Those recordings cannot be transcribed again afterwards. The transcripts stay in your history, and this frees \(byteLabel(selectedBytes)).")
        }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func allSelected(_ group: RecordingGroup) -> Bool {
        group.recordings.allSatisfy { selected.contains($0.id) }
    }

    private func toggle(_ group: RecordingGroup) {
        let ids = group.recordings.map(\.id)
        if allSelected(group) {
            ids.forEach { selected.remove($0) }
        } else {
            selected.formUnion(ids)
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Translation

/// Languages are downloaded one pair at a time, by iOS itself: the framework puts
/// up its own prompt, and there is no way — or reason — to fetch one behind the
/// user's back.
private struct TranslationSection: View {
    @ObservedObject var state: AppState
    @State private var installed = false
    @State private var working = false

    /// The languages this phone can translate into, named the way the rest of the
    /// app names them.
    private var targets: [Languages.Language] {
        Languages.all().filter { state.translator.supported.contains($0.code) }
    }

    private var source: String {
        state.language.isEmpty ? (Languages.systemDefault() ?? "en") : state.language
    }

    var body: some View {
        Section {
            if targets.isEmpty {
                Label("This phone has no translation languages", systemImage: "globe.badge.chevron.backward")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Translate into", selection: $state.translateTo) {
                    ForEach(targets) { Text($0.label).tag($0.code) }
                }

                if installed {
                    Label("Downloaded", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Button(working ? "Downloading…" : "Download this language") {
                        working = true
                        Task {
                            try? await state.translator.download(from: source, to: state.translateTo)
                            installed = await state.translator.isInstalled(from: source, to: state.translateTo)
                            working = false
                        }
                    }
                    .disabled(working)
                }
            }
        } header: {
            Text("Translation")
        } footer: {
            Text("Dictate in one language, insert it in another — choose \"Translate as I speak\" as your style. iOS translates on the device, and downloads a language the first time you use it.\n\nThis is Apple's translator, not the MADLAD one the Mac and Windows builds share: iOS cannot run that, so wording will sometimes differ between platforms. Scribe mode is unaffected — it never translates and never uses a language model.")
        }
        .task(id: state.translateTo) {
            installed = await state.translator.isInstalled(from: source, to: state.translateTo)
        }
    }
}

// MARK: - Sessions

/// Starting and ending the window in which the keyboard can dictate.
private struct SessionCard: View {
    @ObservedObject var state: AppState
    /// Redraws the remaining time without the whole view depending on a clock.
    @State private var now = Date()
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            if state.listening {
                Label("The keyboard can dictate", systemImage: "keyboard.badge.waveform")
                    .font(.footnote)
                Text(remaining).font(.caption).foregroundStyle(.secondary)
                Button("Turn off", role: .destructive) { state.stopListening() }
            } else {
                Button("Let the keyboard dictate") { state.startListening() }
                    .buttonStyle(.borderedProminent)
                Text("Then hold the microphone on the Free Scribe keyboard, in any app, and what you say is typed where you are. Nothing is kept but what you hold the button for.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        .onReceive(tick) { now = $0 }
    }

    private var remaining: String {
        guard let ends = state.sessionEnds else { return "Stays on until you turn it off" }
        let minutes = max(0, Int(ends.timeIntervalSince(now) / 60) + 1)
        return "Turns itself off in about \(minutes) minute\(minutes == 1 ? "" : "s") unless you use it"
    }
}

// MARK: - Coming back from the keyboard

/// The screen the keyboard's button lands on, and nowhere else.
///
/// Being thrown into another app mid-sentence is the worst moment in this whole
/// arrangement, so it gets its own screen rather than a toast: what happened, that
/// it worked, and the two ways back to what you were typing.
private struct ReturnHint: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    @Environment(\.scenePhase) private var phase

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: state.listening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(state.listening ? .green : .orange)

            VStack(spacing: 10) {
                Text(state.listening ? "Ready to dictate" : "Could not start")
                    .font(.title.bold())
                Text(state.listening
                     ? "Go back to what you were typing and hold the microphone on the Free Scribe keyboard."
                     : state.statusText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if state.listening {
                VStack(alignment: .leading, spacing: 18) {
                    WayBack(
                        symbol: "chevron.backward",
                        title: "Tap ‹ Back, top left",
                        detail: "Takes you straight back to the app you came from."
                    )
                    HStack(alignment: .center, spacing: 14) {
                        WayBack(
                            symbol: "rectangle.portrait.and.arrow.forward",
                            title: "Or swipe up from the bottom edge",
                            detail: "Swipe up and let go to leave; swipe up and pause to pick the app from the switcher."
                        )
                        SwipeDemo()
                    }
                }
                .padding()
                .background(.quinary, in: RoundedRectangle(cornerRadius: 16))
            }

            Button("Stay here instead", action: dismiss)
                .font(.footnote)
                .padding(.top, 4)

            Spacer()
            Spacer()
        }
        .padding(28)
        // Leaving is the point of this screen, so going away is what closes it.
        .onChange(of: phase) { _, new in
            if new != .active { dismiss() }
        }
    }
}

private struct WayBack: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Setup

/// What is still missing, and nothing else.
///
/// The four things dictation needs are spread across two apps and three Settings
/// screens, and nothing tells you which one you have not done. This does, and then
/// disappears — a checklist that stays after it is finished is just clutter.
private struct SetupCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        let steps = state.setupSteps
        let outstanding = steps.filter { !$0.done }

        if !outstanding.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("To finish setting up")
                    .font(.headline)

                ForEach(steps, id: \.title) { step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(step.done ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.callout)
                                .strikethrough(step.done)
                                .foregroundStyle(step.done ? .secondary : .primary)
                            if !step.done {
                                Text(step.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Deep link rather than instructions alone: iOS will open its own
                // Settings at this app's page, which is two taps from the keyboard list.
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .font(.footnote)
                }
            }
            .padding()
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// The swipe, drawn rather than described: a finger leaving the bottom edge, over
/// and over. Two lines of instructions are harder to follow than one loop of it.
private struct SwipeDemo: View {
    @State private var running = false

    private let width: CGFloat = 54
    private let height: CGFloat = 86

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.secondary.opacity(0.4), lineWidth: 1.5)

            // The home indicator, the thing being swiped.
            VStack {
                Spacer()
                Capsule()
                    .fill(.secondary)
                    .frame(width: width * 0.45, height: 3)
                    .padding(.bottom, 5)
            }

            // The finger: up from the edge, fading as it goes, then round again.
            Circle()
                .fill(Color.accentColor)
                .frame(width: 13, height: 13)
                .offset(y: running ? -height * 0.28 : height * 0.36)
                .opacity(running ? 0 : 1)
                .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: running)
        }
        .frame(width: width, height: height)
        .onAppear { running = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Vocabulary

/// The words to expect. Short lists work best: Whisper reads only the last 224
/// tokens of what it is told, and every word dilutes the rest.
private struct VocabularyPane: View {
    @ObservedObject var state: AppState
    @State private var entry = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("onomatopoeia, a name, a place…", text: $entry)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("Spell each word the way you want it written. That spelling is what the recogniser is steered towards, and what replaces anything that comes out sounding like it.")
            }

            if state.vocabulary.words.isEmpty {
                ContentUnavailableView("No words yet", systemImage: "character.book.closed")
            } else {
                Section("Words") {
                    ForEach(state.vocabulary.words, id: \.self) { word in
                        Text(word)
                    }
                    .onDelete { offsets in
                        for index in offsets { state.removeWord(state.vocabulary.words[index]) }
                    }
                }
            }

            Section {
                Text("This applies in every style, scribe mode included. A word the student said and the recogniser mangled is already not word for word — putting it back is accuracy, not correction. Only words on this list are ever matched, so nothing can appear that nobody said.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Vocabulary")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        state.addWord(entry)
        entry = ""
    }
}

// MARK: - The Action button

/// How to put dictation on the Action button.
///
/// iOS gives an app no way to claim that button; it runs a shortcut, and shortcuts
/// are what the app provides. So the instructions are the feature — there is nothing
/// to switch on here, only somewhere else to go and four taps to make.
struct ActionButtonGuide: View {
    static let steps = [
        ("1", "Open Settings", "The iPhone's own Settings, not this app's."),
        ("2", "Tap Action Button", "Near the top, under Sounds & Haptics. If it is not there, this iPhone has no Action button — the rest of this still works from Control Centre or Back Tap."),
        ("3", "Swipe to Shortcut", "The list of what the button can do is a carousel. Shortcut is at the end."),
        ("4", "Tap Choose a Shortcut", "Then pick Dictate, under Free Scribe."),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.steps, id: \.0) { number, title, detail in
                    HStack(alignment: .top, spacing: 14) {
                        Text(number)
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.callout)
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Putting dictation on the button")
            } footer: {
                Text("The Action button is on iPhone 15 Pro and Pro Max, and on every iPhone 16 and 17. On other iPhones the same shortcuts work from Control Centre, the Lock Screen, Back Tap (Settings › Accessibility › Touch) or by asking Siri.")
            }

            Section {
                Label("Let the keyboard dictate, on the Dictate tab", systemImage: "power")
                Label("Press once to start talking", systemImage: "1.circle")
                Label("Press again to stop", systemImage: "2.circle")
                Label("It is typed if the keyboard is up, and copied either way", systemImage: "doc.on.doc")
            } header: {
                Text("How it then behaves")
            } footer: {
                Text("Free Scribe stays out of the way and does not come to the front — but only while it is already listening, because that is when the microphone is open. Turn that off and the button has to open the app to start one, which iOS allows nowhere else.\n\nA press, not a hold: the button gives a shortcut one trigger and no release, so it toggles rather than working like the keyboard's microphone.")
            }

            Section {
                LabeledContent("Dictate", value: "without leaving this app")
                LabeledContent("Ready the keyboard", value: "let the keyboard dictate")
                LabeledContent("Copy last dictation", value: "back onto the clipboard")
            } header: {
                Text("The shortcuts Free Scribe provides")
            }

            if let url = URL(string: "App-prefs:root=ACTION_BUTTON") {
                Link("Open the Action Button settings", destination: url)
            }
        }
        .navigationTitle("Action button")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - Debug

/// A switch at the bottom of Settings, for whoever wants to see inside. Turning it
/// on asks first: these tools can leave the app in a state its normal screens never
/// would.
private struct DebugSection: View {
    @ObservedObject var state: AppState
    @State private var warning = false

    var body: some View {
        Section {
            Toggle("Debug mode", isOn: Binding(
                get: { state.debugMode },
                set: { on in if on { warning = true } else { state.debugMode = false } }
            ))
            if state.debugMode {
                NavigationLink("Debug tools") { DebugPane(state: state) }
            }
        } footer: {
            Text("For developers and the curious. Shows what the app is doing underneath and lets you do things it normally would not.")
        }
        .alert("Turn on debug mode?", isPresented: $warning) {
            Button("Turn on", role: .destructive) { state.debugMode = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These tools are for testing. They can reset the app, wipe your settings and stop things halfway — if you really try, you can leave Free Scribe in a mess. Nothing leaves the phone either way.")
        }
    }
}

private struct DebugPane: View {
    @ObservedObject var state: AppState
    @State private var log = Diagnostics.tail(400)
    @State private var loaded = "…"
    @State private var confirmingWipe = false

    private var lastFailed: URL? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "last-failed.wav")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        List {
            Section("State") {
                row("Status", state.statusText)
                row("Model in use", state.activeModel)
                row("Model loaded", loaded)
                row("Bundled model", state.installed.bundled ?? "none")
                row("Setup method", state.setupMethod)
                row("Keyboard listening", yes(state.listening))
                row("Recording", yes(state.recording))
                row("Session ends", state.sessionEnds.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                row("Microphone allowed", yes(Recorder.microphoneAuthorized))
                row("Keyboard installed", yes(state.installed.keyboardInstalled))
                row("Full Access", yes(state.installed.keyboardFullAccess))
                row("Keyboard on screen", yes(Handoff.keyboardIsVisible))
                row("Container", Transcriber.modelsBase.path)
            }

            Section("Actions") {
                Button("Show setup again") {
                    state.practised = false
                    UserDefaults.shared.set(false, forKey: "onboarded")
                }
                Button("Reload the speech model") {
                    Task {
                        loaded = "reloading…"
                        await state.reloadModel()
                        loaded = await state.loadedModelName() ?? "none"
                    }
                }
                Button(state.listening ? "Stop keyboard listening" : "Start keyboard listening") {
                    state.listening ? state.stopListening() : state.startListening()
                }
                Button("Re-check what is installed") { state.refreshInstalled() }
                Button("Cancel any dictation", role: .destructive) { state.cancelDictation() }
                Button("Wipe every setting", role: .destructive) { confirmingWipe = true }
            }

            Section {
                // The app's own log: every dictation, every Action button press, every
                // failure and why. The same file the Mac reads off the phone.
                ScrollView([.vertical, .horizontal]) {
                    Text(log)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 300)

                HStack {
                    Button("Refresh") { log = Diagnostics.tail(400) }
                    Spacer()
                    Button("Clear", role: .destructive) {
                        Diagnostics.clear()
                        log = Diagnostics.tail(400)
                    }
                    Spacer()
                    if let file = Diagnostics.fileURL { ShareLink(item: file) }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Log")
            }

            if let wav = lastFailed {
                Section("Last failed recording") {
                    ShareLink("Share last-failed.wav", item: wav)
                }
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .task { loaded = await state.loadedModelName() ?? "none" }
        .confirmationDialog("Wipe every setting?", isPresented: $confirmingWipe, titleVisibility: .visible) {
            Button("Wipe everything", role: .destructive) {
                UserDefaults.shared.removePersistentDomain(forName: Transcriber.appGroup)
            }
        } message: {
            Text("Every setting goes back to how it was on first launch, and setup runs again. Transcripts, recordings and models stay.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func yes(_ flag: Bool) -> String { flag ? "yes" : "no" }
}
