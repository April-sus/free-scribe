import SwiftUI
import WhisperFlowCore

/// Container app. Its job for now is to exist so the keyboard can be installed,
/// and to show the same measurement for comparison — an app is given far more
/// memory than an extension, and the difference is the whole question.
@main
struct FreeScribeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

struct ProbeView: View {
    @State private var readout = ""
    @State private var loading = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Free Scribe").font(.largeTitle.bold())
            Text(readout).font(.system(.footnote, design: .monospaced)).multilineTextAlignment(.center)

            Button(loading ? "Loading…" : "Load the speech model") {
                loading = true
                Task {
                    let transcriber = Transcriber()
                    try? await transcriber.load(model: "openai_whisper-tiny.en") { _ in }
                    readout = report("model loaded in the app")
                    loading = false
                }
            }
            .disabled(loading)

            Text("Enable the keyboard in Settings → General → Keyboards, then switch to it and load the model there. The difference between the two figures is what decides the design.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
        .onAppear { readout = report("at launch") }
    }

    private func report(_ stage: String) -> String {
        let machine = MachineInfo.probe()
        let text = """
        \(MemoryProbe.describe(stage))
        \(machine.chip), \(machine.ramGB) GB memory, \(machine.freeStorageGB) GB free
        would choose \(ModelPicker.label(for: ModelPicker.fallback(for: machine)))
        """
        // Logged as well as shown: the figure matters more than the label, and it
        // is easier to read off a console than a phone screen.
        NSLog("[free-scribe] %@", text.replacingOccurrences(of: "\n", with: " | "))
        return text
    }
}
