import Foundation

/// A log both the app and its keyboard can write to and a Mac can read off the
/// device afterwards.
///
/// A keyboard extension's console output has nowhere to go — nothing attaches to
/// it — so anything worth reading later goes to a file in the shared container.
public enum Diagnostics {
    public static func log(_ line: String) {
        print("[free-scribe] \(line)")
        guard let file = fileURL else { return }

        let entry = "\(Date()) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            try? Data(entry.utf8).write(to: file)
        }
    }

    /// The last few lines, for reading an extension's log out through the app.
    public static func tail(_ lines: Int = 20) -> String {
        guard let file = fileURL, let text = try? String(contentsOf: file, encoding: .utf8) else {
            return "(no log)"
        }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    public static func clear() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    public static var fileURL: URL? {
        #if os(iOS)
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Transcriber.appGroup)?
            .appending(path: "free-scribe.log")
        #else
        nil
        #endif
    }
}
