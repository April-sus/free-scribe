import AppKit
import Foundation
import WhisperFlowCore

if CommandLine.arguments.contains("--devices") {
    for device in MainActor.assumeIsolated({ Recorder.availableInputs() }) {
        print("\(device.name)\t\(device.id)")
    }
    exit(0)
}

// Shows what each dictation style does to a line, without speaking it.
if let index = CommandLine.arguments.firstIndex(of: "--clean"), index + 1 < CommandLine.arguments.count {
    let spoken = CommandLine.arguments[index + 1]
    let done = DispatchSemaphore(value: 0)
    Task {
        defer { done.signal() }
        print("polish available: \(Cleanup.polishAvailable) \(Cleanup.polishUnavailableReason ?? "")")
        for style in DictationStyle.allCases {
            print("\(style.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(await Cleanup.apply(spoken, style: style))")
        }
    }
    done.wait()
    exit(0)
}

// Headless smoke test of the whole engine path: download/load a model and
// transcribe a file, no mic, no UI. See build.sh for the one-liner that makes a wav.
if let index = CommandLine.arguments.firstIndex(of: "--transcribe") {
    guard index + 1 < CommandLine.arguments.count else {
        FileHandle.standardError.write(Data("usage: FreeScribe --transcribe <audio file>\n".utf8))
        exit(2)
    }
    let path = CommandLine.arguments[index + 1]
    let done = DispatchSemaphore(value: 0)
    var status: Int32 = 0

    Task {
        defer { done.signal() }
        let machine = MachineInfo.probe()
        let model = UserDefaults.standard.string(forKey: "model").flatMap { $0.isEmpty ? nil : $0 }
            ?? ModelPicker.automatic(for: machine)
        FileHandle.standardError.write(Data("\(machine.summary)\nmodel: \(model)\n".utf8))

        do {
            let transcriber = Transcriber()
            try await transcriber.load(model: model) { phase in
                if case .downloading(let fraction) = phase {
                    FileHandle.standardError.write(Data("\rdownloading \(Int(fraction * 100))%".utf8))
                }
            }
            let text = try await transcriber.transcribe(path: path, language: "en")
            print(text)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            status = 1
        }
    }

    done.wait()
    exit(status)
}

WhisperFlowApp.main()
