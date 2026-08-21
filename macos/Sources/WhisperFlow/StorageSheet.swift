import SwiftUI
import WhisperFlowCore

/// Clearing out recordings without clearing all of them.
///
/// With unlimited retention on, the cache grows for as long as somebody keeps
/// dictating, so freeing space has to mean more than "delete everything". Grouping
/// by day, month or year lets a year of old recordings go in two clicks while this
/// week's stay.
struct StorageSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var grouping: Grouping = .day
    @State private var selected: Set<UUID> = []
    @State private var expanded: Set<Date> = []
    @State private var recordings = AudioCache.recordings()
    @State private var confirming = false

    private var groups: [RecordingGroup] { grouping.group(recordings) }
    private var selectedBytes: Int64 {
        recordings.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if recordings.isEmpty {
                Spacer()
                Text("No recordings stored.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(groups) { group in
                            groupRow(group)
                            if expanded.contains(group.id) {
                                ForEach(group.recordings) { recording in
                                    recordingRow(recording)
                                }
                            }
                            Divider()
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 540, height: 460)
        .alert("Delete \(selected.count) recording\(selected.count == 1 ? "" : "s")?", isPresented: $confirming) {
            Button("Delete", role: .destructive) {
                state.deleteRecordings(selected)
                selected.removeAll()
                recordings = AudioCache.recordings()
            }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Those recordings cannot be transcribed again afterwards. The transcripts themselves stay in your history, and this frees \(byteLabel(selectedBytes)).")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recordings").font(.headline)
                Text("\(recordings.count) stored, using \(byteLabel(recordings.reduce(0) { $0 + $1.bytes }))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Group by", selection: $grouping) {
                ForEach(Grouping.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            // Groups change shape, so a selection made under one grouping would be
            // invisible under the next.
            .onChange(of: grouping) { _, _ in
                expanded.removeAll()
                selected.removeAll()
            }
        }
        .padding(16)
    }

    private func groupRow(_ group: RecordingGroup) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: binding(for: group))
                .labelsHidden()
                .toggleStyle(.checkbox)

            Button {
                if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
            } label: {
                Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Text(group.title)
            Spacer()
            Text("\(group.recordings.count) · \(byteLabel(group.bytes))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.25))
    }

    private func recordingRow(_ recording: Recording) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(recording.id) },
                set: { isOn in
                    if isOn { selected.insert(recording.id) } else { selected.remove(recording.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Text(recording.date.formatted(date: .omitted, time: .standard))
                .font(.callout)
            // The transcript it belongs to, so you know what you are deleting.
            Text(transcriptText(for: recording.id))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(byteLabel(recording.bytes))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 52)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack {
            Button(selected.count == recordings.count ? "Select none" : "Select all") {
                selected = selected.count == recordings.count ? [] : Set(recordings.map(\.id))
            }
            .disabled(recordings.isEmpty)

            Spacer()

            if !selected.isEmpty {
                Text("\(selected.count) selected · \(byteLabel(selectedBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button("Delete selected") { confirming = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selected.isEmpty)

            Button("Done") { dismiss() }
        }
        .padding(16)
    }

    /// Selecting a group selects everything in it, and clearing it clears them.
    private func binding(for group: RecordingGroup) -> Binding<Bool> {
        let ids = Set(group.recordings.map(\.id))
        return Binding(
            get: { !ids.isEmpty && ids.isSubset(of: selected) },
            set: { isOn in
                if isOn { selected.formUnion(ids) } else { selected.subtract(ids) }
            }
        )
    }

    private func transcriptText(for id: UUID) -> String {
        guard let entry = state.history.entries.first(where: { $0.id == id }) else {
            return "no transcript"
        }
        return entry.failed ? "transcription failed" : entry.text
    }

    private func byteLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
