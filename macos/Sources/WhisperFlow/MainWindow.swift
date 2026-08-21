import AppKit
import ServiceManagement
import SwiftUI
import WhisperFlowCore

/// The app's single window. Everything configurable lives here rather than in the
/// macOS Settings scene, and it is built from `Theme.swift` primitives rather than
/// native form chrome, so a port to another platform reuses this file's body as-is.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private static let shared = MainWindow()
    private static var window: NSWindow?

    static func show(_ state: AppState) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Free Scribe"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: MainView(state: state))
            window.contentMinSize = NSSize(width: 660, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = shared
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func done() {
        window?.close()
    }

    /// Back to a menu-bar-only app, however the window was dismissed.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private enum Pane: String, CaseIterable, Identifiable {
    case dictation, history, audio, model, stats, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .history: "History"
        case .audio: "Audio"
        case .model: "Model"
        case .stats: "Stats"
        case .general: "General"
        }
    }

    var icon: String {
        switch self {
        case .dictation: "text.cursor"
        case .history: "list.bullet.rectangle"
        case .audio: "waveform"
        case .model: "cpu"
        case .stats: "chart.bar"
        case .general: "gearshape"
        }
    }
}

private struct MainView: View {
    @ObservedObject var state: AppState
    @State private var pane: Pane = .dictation

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(state: state, pane: $pane)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch pane {
                    case .dictation: DictationPane(state: state)
                    case .history: HistoryPane(state: state)
                    case .audio: AudioPane(state: state)
                    case .model: ModelPane(state: state)
                    case .stats: StatsPane(state: state)
                    case .general: GeneralPane(state: state)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
        }
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35)))
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toast)
    }
}

/// The transcript board: everything dictated this session, click to copy it again.
/// The two irreversible actions on this pane, each with the reason you might not
/// want to take it. Nothing here can be undone, so nothing here happens on one click.
private enum Destruction: Identifiable {
    case audio
    case everything

    var id: String { title }

    var title: String {
        switch self {
        case .audio: "Delete the saved recordings?"
        case .everything: "Delete every transcript and recording?"
        }
    }

    var explanation: String {
        switch self {
        case .audio:
            "The recordings are what make “Transcribe again” possible. Without them, a transcript that came out wrong can only be fixed by dictating it over. Your transcripts themselves are not touched."
        case .everything:
            "Every transcript goes, along with every recording. You will not be able to look back at anything you have dictated, copy it again, or run any of it through the recogniser a second time. This cannot be undone."
        }
    }

    var confirm: String {
        switch self {
        case .audio: "Delete recordings"
        case .everything: "Delete everything"
        }
    }
}

private struct HistoryPane: View {
    @ObservedObject var state: AppState
    @State private var confirming: Destruction?

    var body: some View {
        if state.history.entries.isEmpty {
            Card(title: "Nothing yet", footnote: "Transcripts appear here as you dictate. Click one to copy it again.") {
                Text("Dictate something and it shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.cardPadding)
                    .padding(.vertical, 12)
            }
        } else {
            Card(title: "Transcripts", footnote: "Copy any of them back to the clipboard. The last \(AudioCache.limit) recordings are kept, so those can be run through the recogniser again — useful when a word came out wrong.") {
                ForEach(Array(state.history.entries.enumerated()), id: \.element.id) { index, transcript in
                    TranscriptRow(state: state, transcript: transcript)
                    if index < state.history.entries.count - 1 { RowDivider() }
                }
            }
        }

        Card(
            title: "Stored on this Mac",
            footnote: "Transcripts are kept until you delete them. Recordings of the last \(AudioCache.limit) dictations are kept so a transcript can be produced again from the original audio — they are deleted automatically as newer ones arrive, and you can remove them all at any time."
        ) {
            Row(title: "Keep recordings", detail: "Needed to transcribe again. Turning this off deletes the ones already stored.") {
                Toggle("", isOn: $state.keepAudio)
                    .toggleStyle(.switch)
            }
            RowDivider()
            Row(title: "Recordings held", detail: byteLabel) {
                Button("Delete audio") { confirming = .audio }
                    .disabled(AudioCache.bytesUsed() == 0)
            }
            if !state.history.entries.isEmpty {
                RowDivider()
                Row(title: "Clear everything", detail: "Removes every transcript and every recording.") {
                    Button("Clear") { confirming = .everything }
                }
            }
        }
        .alert(item: $confirming) { destruction in
            Alert(
                title: Text(destruction.title),
                message: Text(destruction.explanation),
                primaryButton: .destructive(Text(destruction.confirm)) {
                    switch destruction {
                    case .audio: state.clearAudioCache()
                    case .everything: state.clearHistory()
                    }
                },
                secondaryButton: .cancel(Text("Keep them"))
            )
        }
    }

    private var byteLabel: String {
        let bytes = AudioCache.bytesUsed()
        guard bytes > 0 else { return "Nothing stored right now." }
        let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(AudioCache.stored().count) of \(AudioCache.limit), using \(formatted)."
    }
}

private struct TranscriptRow: View {
    @ObservedObject var state: AppState
    let transcript: Transcript
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if transcript.failed {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                    Text("Transcription failed")
                        .fontWeight(.medium)
                }
                Text(transcript.failureReason ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(transcript.text)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Text("\(transcript.date.formatted(date: .abbreviated, time: .shortened)) · \(transcript.style)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if !transcript.failed {
                    Button("Copy") { state.copyToClipboard(transcript) }
                        .controlSize(.small)
                }

                if transcript.canRetranscribe {
                    // A failure is the one case worth pushing, so it gets the
                    // prominent treatment and everything else stays quiet.
                    if transcript.failed {
                        Button("Retry") { state.retranscribe(transcript) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .help("Runs the original recording through again")
                    } else {
                        Button("Transcribe again") { state.retranscribe(transcript) }
                            .controlSize(.small)
                            .help("Runs the original recording through again")
                    }
                } else {
                    Text("recording cleared")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .help("Only the last \(AudioCache.limit) recordings are kept, so this one cannot be redone.")
                }

                Button {
                    state.delete(transcript)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Delete this transcript and its recording")
            }
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 12)
        .background(background)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if transcript.failed { return Theme.warning.opacity(0.08) }
        return hovering ? Theme.accent.opacity(0.05) : .clear
    }
}



// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var state: AppState
    @Binding var pane: Pane

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Free Scribe")
                        .font(.system(size: 13, weight: .semibold))
                    Text(state.statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 34)
            .padding(.bottom, 18)

            ForEach(Pane.allCases) { item in
                Button {
                    pane = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 17)
                        Text(item.title)
                            .font(.system(size: 12.5, weight: pane == item ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(pane == item ? Theme.accent : .primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(pane == item ? Theme.accent.opacity(0.14) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
            }

            Spacer()

            Button("Done") {
                state.seenWelcome = true
                MainWindow.done()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(14)
        }
        .frame(width: 186)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.22))
    }
}

// MARK: - Panes

private struct DictationPane: View {
    @ObservedObject var state: AppState

    var body: some View {
        if !Paste.isTrusted {
            Banner(
                icon: "hand.raised.fill",
                message: "Accessibility is off, so transcripts are only copied instead of typed for you.",
                tint: Theme.warning,
                actionTitle: "Grant…",
                action: { Paste.openAccessibilitySettings() }
            )
        }

        Card(title: "Shortcut") {
            VStack(alignment: .leading) { ShortcutField() }
                .padding(.horizontal, Theme.cardPadding)
                .padding(.vertical, 10)
        }

        Card(title: "Style", footnote: state.style.detail) {
            ForEach(Array(DictationStyle.allCases.enumerated()), id: \.element) { index, style in
                Button {
                    state.style = style
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: state.style == style ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(state.style == style ? Theme.accent : .secondary)
                        Text(style.label)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.cardPadding)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index < DictationStyle.allCases.count - 1 { RowDivider() }
            }
        }

        if state.style == .scribe {
            ScribeRules(state: state)
        }

        if state.style == .polished, let reason = Cleanup.polishUnavailableReason {
            Banner(
                icon: "sparkles",
                message: "\(reason) Until then transcripts fall back to “\(DictationStyle.tidy.label)”.",
                tint: Theme.warning
            )
        }
    }
}

/// Being explicit about the boundary matters more than the feature does: a school
/// has to know which rules the software is holding and which ones still need a person.
private struct ScribeRules: View {
    @ObservedObject var state: AppState

    private static let enforced = [
        "Writes word for word — nothing added, removed, corrected or suggested.",
        "Prints everything in lower case unless the student asks otherwise.",
        "Adds no punctuation unless the student asks for it by name, and every mark needs “command” in front of it.",
        "Keeps “um”, repeats and false starts, because removing them would improve the text.",
        "Reads the text back only when asked, from the menu bar.",
    ]

    private static let human = [
        "Prior written permission for a scribe, and a student who normally uses one.",
        "Test instructions given from the Test Administration Handbook.",
        "The editing pass: the student marks capitals, full stops and paragraphs, recorded in red.",
        "The spelling check: 4 easy, 4 average and 4 difficult words spelt orally, recorded in red in three columns.",
        "Any extra time granted, and recording it where your authority requires.",
    ]

    var body: some View {
        Card(
            title: "Spoken commands",
            footnote: "The word “command” is required on every one, so dictating “the capital of France” or “put a comma there” is written out exactly as spoken."
        ) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Say “command”, then any of:")
                    .font(.callout)
                // Read straight off the table the transcriber uses, so this reference
                // cannot drift out of step with what actually works.
                Text(Cleanup.dictatedMarks.map(\.0).joined(separator: "  ·  "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, 10)

            RowDivider()

            Row(
                title: "Allow spoken capitals",
                detail: "“command capital y” writes Y, and following single letters spell the rest — “command capital y”, “o” writes “Yo”. Off is the strictest reading, where capitals are marked only during the editing pass."
            ) {
                Toggle("", isOn: $state.spokenCapitals)
                    .toggleStyle(.switch)
            }
        }

        Card(title: "Enforced by this mode") {
            ForEach(Array(Self.enforced.enumerated()), id: \.offset) { index, rule in
                RuleLine(icon: "checkmark.circle.fill", tint: Theme.accent, text: rule)
                if index < Self.enforced.count - 1 { RowDivider() }
            }
        }

        Card(
            title: "Still the supervisor's job",
            footnote: "Based on the NAPLAN Scribe Rules for the Writing Test. This mode is an aid, not a certification — confirm current requirements with your authority before using it in an exam."
        ) {
            ForEach(Array(Self.human.enumerated()), id: \.offset) { index, rule in
                RuleLine(icon: "person.fill", tint: .secondary, text: rule)
                if index < Self.human.count - 1 { RowDivider() }
            }
        }
    }
}

private struct RuleLine: View {
    var icon: String
    var tint: Color
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.cardPadding)
        .padding(.vertical, 9)
    }
}

private struct AudioPane: View {
    @ObservedObject var state: AppState
    @State private var inputs = Recorder.availableInputs()

    private static let languages: [(code: String, name: String)] = [
        ("", "Detect automatically"),
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("pt", "Portuguese"), ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
    ]

    var body: some View {
        Card(title: "Input") {
            Row(title: "Microphone", detail: "Takes effect on your next dictation.") {
                Picker("", selection: $state.inputDevice) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(inputs) { Text($0.name).tag($0.id) }
                    // Keep an unplugged choice selectable so reconnecting restores it
                    // instead of silently leaving the picker blank.
                    if !state.inputDevice.isEmpty, !inputs.contains(where: { $0.id == state.inputDevice }) {
                        Text("Unavailable device").tag(state.inputDevice)
                    }
                }
                .frame(maxWidth: 210)
            }
            RowDivider()
            Row(title: "Language", detail: "Forcing a language is faster and more accurate than detection.") {
                Picker("", selection: $state.language) {
                    ForEach(Self.languages, id: \.code) { Text($1).tag($0) }
                }
                .frame(maxWidth: 210)
            }
        }
        .onAppear { inputs = Recorder.availableInputs() }
    }
}

private struct ModelPane: View {
    @ObservedObject var state: AppState
    @State private var downloaded = Transcriber.downloadedModels()

    var body: some View {
        if state.needsSetup {
            Banner(
                icon: "arrow.down.circle.fill",
                message: "\(ModelPicker.label(for: state.activeModel)) · \(ModelPicker.size(for: state.activeModel)) — one download, then it works offline.",
                tint: Theme.accent,
                actionTitle: "Download",
                action: { Task { await state.prepareModel() } }
            )
        }

        switch state.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading model…").font(.callout) }
                .tint(Theme.accent)
        case .loading:
            ProgressView { Text("Loading model…").font(.callout) }
        case .error(let message):
            Banner(icon: "exclamationmark.triangle.fill", message: message, tint: .red)
        default:
            EmptyView()
        }

        Card(title: "Speech model", footnote: "Automatic picks the largest model this Mac can run comfortably.") {
            Row(title: "Model") {
                Picker("", selection: $state.modelOverride) {
                    Text("Automatic — \(ModelPicker.label(for: ModelPicker.automatic(for: state.machine)))").tag("")
                    Divider()
                    ForEach(ModelPicker.catalog, id: \.id) { entry in
                        Text("\(entry.label) · \(entry.size)\(downloaded.contains(entry.id) ? " ✓" : "")")
                            .tag(entry.id)
                    }
                }
                .frame(maxWidth: 260)
            }
            RowDivider()
            Row(title: "This Mac", detail: state.machine.summary) { EmptyView() }
        }

        if !downloaded.isEmpty {
            Card(title: "Downloaded") {
                ForEach(Array(downloaded.enumerated()), id: \.element) { index, model in
                    Row(title: ModelPicker.label(for: model)) {
                        Button("Delete") {
                            try? Transcriber.delete(model)
                            downloaded = Transcriber.downloadedModels()
                        }
                        .disabled(model == state.activeModel)
                    }
                    if index < downloaded.count - 1 { RowDivider() }
                }
            }
        }
    }
}

private struct StatsPane: View {
    @ObservedObject var state: AppState
    @State private var confirmingReset = false

    private var stats: Stats { state.stats }

    var body: some View {
        if stats.dictations == 0 {
            Card(title: "Nothing yet", footnote: "These numbers are written to a file on this Mac and never sent anywhere.") {
                Text("Dictate something and this fills in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.cardPadding)
                    .padding(.vertical, 12)
            }
        } else {
            HStack(spacing: 12) {
                Tile(value: stats.words.formatted(), label: "words spoken")
                Tile(value: stats.secondsSaved > 0 ? stats.secondsSaved.asDuration : "—", label: "saved vs typing")
                Tile(value: stats.dictations.formatted(), label: "dictations")
            }

            Card(title: "Last 14 days") {
                DayChart(days: stats.recent(days: 14))
                    .frame(height: 96)
                    .padding(.horizontal, Theme.cardPadding)
                    .padding(.vertical, 12)
            }

            Card(
                title: "Detail",
                footnote: "“Saved vs typing” compares your words against \(Int(Stats.typingWordsPerMinute)) words per minute of typing, minus the time you actually spent speaking. A ballpark, not a measurement."
            ) {
                Row(title: "Speaking rate") { Text("\(Int(stats.wordsPerMinute)) wpm").foregroundStyle(.secondary) }
                RowDivider()
                Row(title: "Time spent talking") { Text(stats.secondsSpoken.asDuration).foregroundStyle(.secondary) }
                RowDivider()
                Row(title: "Average dictation") { Text("\(stats.averageWordsPerDictation) words").foregroundStyle(.secondary) }
                if let first = stats.firstUsed {
                    RowDivider()
                    Row(title: "First used") {
                        Text(first.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    }
                }
            }

            Card(title: "Privacy", footnote: Stats.fileURL.path(percentEncoded: false)) {
                Row(title: "Stored on this Mac only", detail: "One JSON file. No account, no upload, no identifiers.") {
                    Button(confirmingReset ? "Really reset?" : "Reset") {
                        if confirmingReset {
                            Stats.erase()
                            state.stats = Stats()
                            confirmingReset = false
                        } else {
                            confirmingReset = true
                        }
                    }
                    .tint(confirmingReset ? .red : nil)
                }
            }
        }
    }
}

private struct Tile: View {
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.cardBorder))
    }
}

private struct DayChart: View {
    let days: [(day: Date, words: Int)]

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)

        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 5) {
                    // Always leaves a sliver visible so empty days read as empty
                    // rather than as missing data.
                    GeometryReader { geometry in
                        let height = max(2, geometry.size.height * CGFloat(entry.words) / CGFloat(peak))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(entry.words > 0 ? Theme.accent : Color.secondary.opacity(0.25))
                            .frame(height: height)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    Text(entry.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Card(title: "Startup") {
            Row(title: "Launch at login", detail: "Starts hidden in the menu bar.") {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, enabled in
                        // ponytail: silently reverts the toggle if macOS refuses the
                        // registration; surface an alert only if anyone reports it.
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            }
        }

        Card(title: "Sound") {
            Row(title: "Play sounds", detail: "Short cues when listening starts, text is inserted, and something fails — useful when the window is hidden.") {
                Toggle("", isOn: $state.soundsEnabled)
                    .toggleStyle(.switch)
            }
        }

        Card(title: "Permissions") {
            Row(title: "Microphone", detail: "Needed to hear you at all.") {
                StatusPip(granted: Recorder.microphoneAuthorized)
            }
            RowDivider()
            Row(title: "Accessibility", detail: "Needed to type the text into other apps.") {
                if Paste.isTrusted {
                    StatusPip(granted: true)
                } else {
                    Button("Grant…") { Paste.openAccessibilitySettings() }
                }
            }
        }

        Card(title: "About", footnote: "Free Scribe recognises speech on this Mac using Apple's Neural Engine. Nothing you say is uploaded, and there is nothing to pay for. Open source under the MIT License; see the notices in this app's Resources folder.") {
            Row(title: "Version", detail: "Free Scribe 1.0") { EmptyView() }
            RowDivider()
            Row(title: "Speech model", detail: ModelPicker.label(for: state.activeModel)) { EmptyView() }
        }
    }
}

private struct StatusPip: View {
    var granted: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(granted ? Theme.accent : Theme.warning)
                .frame(width: 7, height: 7)
            Text(granted ? "Allowed" : "Not yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
