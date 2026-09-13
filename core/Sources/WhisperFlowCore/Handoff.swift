import Foundation

/// How the keyboard asks the app to dictate for it.
///
/// An app extension cannot record — not through AVAudioEngine, AVAudioRecorder or
/// AVCaptureSession, all three of which the phone refuses. What an app *can* do is
/// hold the microphone open in the background, so the app listens and the keyboard
/// tells it when to start and stop. Nothing crosses a process boundary except a
/// Darwin notification and the shared container.
public enum Handoff {
    public static let start = "local.freescribe.start"
    public static let stop = "local.freescribe.stop"
    public static let transcript = "local.freescribe.transcript"

    /// Written while the app is holding the microphone open, so the keyboard can say
    /// "open Free Scribe first" rather than waiting for an answer that never comes.
    public static var listeningFlag: URL {
        Transcriber.modelsBase.appending(path: "listening")
    }

    public static var isListening: Bool {
        guard let seen = try? FileManager.default
            .attributesOfItem(atPath: listeningFlag.path)[.modificationDate] as? Date else { return false }
        // The app refreshes this; a stale one means it was killed in the background.
        return Date().timeIntervalSince(seen) < 90
    }

    /// Refreshed while the app is alive; `isListening` is a heartbeat, not a latch.
    public static func setListening(_ listening: Bool) {
        if listening {
            try? FileManager.default.createDirectory(
                at: listeningFlag.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data().write(to: listeningFlag)
        } else {
            try? FileManager.default.removeItem(at: listeningFlag)
        }
    }

    /// When the current dictation session runs out, for the keyboard to show and the
    /// app to act on. A session is a window in which the app holds the microphone;
    /// outside one it holds nothing.
    public static var sessionEnds: Date? {
        get {
            let seconds = defaults?.double(forKey: "sessionEnds") ?? 0
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set { defaults?.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "sessionEnds") }
    }

    /// What the keyboard has seen of itself, written when it runs. The app cannot
    /// ask iOS whether Full Access is on — only the extension can know — so the
    /// extension leaves the answer where the app can read it.
    public static var keyboardHasFullAccess: Bool {
        get { defaults?.bool(forKey: "keyboardFullAccess") ?? false }
        set { defaults?.set(newValue, forKey: "keyboardFullAccess") }
    }

    /// Whether the keyboard is installed at all. iOS lists the installed keyboards
    /// in defaults, which is the only way an app can tell.
    public static var keyboardInstalled: Bool {
        let installed = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        return installed.contains { $0.contains("FreeScribe.Keyboard") }
    }

    /// Whether the Free Scribe keyboard is on screen right now.
    ///
    /// It decides who inserts what was dictated. With the keyboard up it types the
    /// text itself, and the clipboard is left alone; without it there is nothing on
    /// iOS that can type into another app, so the clipboard is the only way to hand
    /// the text over.
    public static var keyboardIsVisible: Bool {
        let seen = defaults?.double(forKey: "keyboardVisible") ?? 0
        return seen > 0 && Date().timeIntervalSince1970 - seen < 5
    }

    public static func keyboardIsShowing(_ showing: Bool) {
        defaults?.set(showing ? Date().timeIntervalSince1970 : 0, forKey: "keyboardVisible")
    }

    private static let defaults = UserDefaults(suiteName: Transcriber.appGroup)

    /// The URL the keyboard opens to wake the app when iOS has reclaimed it.
    public static let wakeURL = URL(string: "freescribe://listen")!

    /// The loudness the app is hearing, for the keyboard to draw.
    ///
    /// Four bytes in the shared container, overwritten as fast as the microphone
    /// reports and read by whoever is drawing. A notification per buffer would be
    /// both chattier and slower, and a dropped reading costs nothing — the next one
    /// is along in a few milliseconds.
    public static func publish(level: Float) {
        guard let url = levelURL else { return }
        var value = level
        // Not atomic: four bytes written twenty times a second, and a torn read is
        // caught by the size check in `level` and reads as silence for one frame.
        try? Data(bytes: &value, count: MemoryLayout<Float>.size).write(to: url)
    }

    public static var level: Float {
        guard let url = levelURL,
              let data = try? Data(contentsOf: url),
              data.count == MemoryLayout<Float>.size
        else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    /// Looked up once. Both sides touch this twenty times a second.
    private static let levelURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: Transcriber.appGroup)?
        .appending(path: "level.bin")

    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    /// Darwin notifications carry no payload and their callback is a bare C function,
    /// so the handlers live in a table the callback can reach.
    /// Registering the same name twice replaces the handler rather than adding a
    /// second observer. iOS rebuilds the keyboard's controller inside one extension
    /// process, so observers otherwise accumulate and every dictation is typed once
    /// per rebuild.
    public static func observe(_ name: String, handler: @escaping @Sendable () -> Void) {
        let alreadyObserving = Handlers.shared.set(name, handler)
        guard !alreadyObserving else { return }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, name, _, _ in
                guard let name = name?.rawValue as String? else { return }
                Handlers.shared.fire(name)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private final class Handlers: @unchecked Sendable {
        static let shared = Handlers()
        private let lock = NSLock()
        private var handlers: [String: @Sendable () -> Void] = [:]

        /// Returns whether this name was already being observed.
        func set(_ name: String, _ handler: @escaping @Sendable () -> Void) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let existing = handlers[name] != nil
            handlers[name] = handler
            return existing
        }

        func fire(_ name: String) {
            lock.lock()
            let handler = handlers[name]
            lock.unlock()
            handler?()
        }
    }
}
