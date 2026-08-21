import Foundation
import WhisperFlowCore

/// Talks to the translation sidecar.
///
/// The model is a C++ library, so it runs as a child process rather than being
/// linked in: one JSON request per line to its stdin, one JSON response per line
/// back. Responses arrive in the order requests were sent, so a queue of
/// continuations is enough to match them up.
@MainActor
final class LocalTranslator {
    private var process: Process?
    private var toChild: FileHandle?
    private var pending: [CheckedContinuation<String?, Never>] = []
    private var buffer = Data()
    private var ready = false

    /// Loading the model takes a few seconds, so the first request waits on this
    /// rather than being sent into a process that is not listening yet.
    private var readySignal: [CheckedContinuation<Bool, Never>] = []

    static var isAvailable: Bool {
        TranslationModel.isInstalled && executable != nil
    }

    /// Shipped beside the app rather than found on the machine.
    static var executable: URL? {
        let url = Bundle.main.bundleURL
            .appending(path: "Contents/MacOS/free-scribe-translate")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func translate(_ text: String, from source: String, to target: String) async -> String? {
        guard Self.isAvailable else { return nil }
        guard await start() else { return nil }

        let request: [String: String] = ["text": text, "source": source, "target": target]
        guard let line = try? JSONSerialization.data(withJSONObject: request) else { return nil }

        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            var payload = line
            payload.append(0x0A)
            do {
                try toChild?.write(contentsOf: payload)
            } catch {
                // The child has gone; fail this request rather than leave it waiting.
                finishNext(with: nil)
                stop()
            }
        }
    }

    /// - Returns: whether the sidecar is loaded and listening.
    @discardableResult
    func start() async -> Bool {
        if ready { return true }
        if process == nil { launch() }
        guard process != nil else { return false }

        return await withCheckedContinuation { continuation in
            readySignal.append(continuation)
        }
    }

    private func launch() {
        guard let executable = Self.executable else { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = [TranslationModel.directory.path]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // The child's own diagnostics would otherwise fill a pipe nobody reads,
        // and a full pipe blocks the writer.
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.childDied() }
        }

        do {
            try process.run()
            self.process = process
            self.toChild = input.fileHandleForWriting
        } catch {
            self.process = nil
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if object["ready"] as? Bool == true {
            ready = true
            let waiting = readySignal
            readySignal.removeAll()
            for continuation in waiting { continuation.resume(returning: true) }
            return
        }

        finishNext(with: object["text"] as? String)
    }

    private func finishNext(with text: String?) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: text)
    }

    private func childDied() {
        ready = false
        process = nil
        toChild = nil

        // Nothing in flight can ever be answered now.
        let waitingForReady = readySignal
        readySignal.removeAll()
        for continuation in waitingForReady { continuation.resume(returning: false) }

        let inFlight = pending
        pending.removeAll()
        for continuation in inFlight { continuation.resume(returning: nil) }
    }

    func stop() {
        process?.terminate()
        childDied()
    }
}
