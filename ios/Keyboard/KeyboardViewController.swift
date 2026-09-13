import UIKit
import WhisperFlowCore

/// A keyboard you could use for everything, with dictation on top of it: the style
/// to dictate in, and a microphone to hold.
///
/// It records nothing itself, because iOS lets no app extension record — the phone
/// refuses AVAudioEngine, AVAudioRecorder and AVCaptureSession alike. The app holds
/// the microphone and this says when to start and stop, then types what comes back.
@MainActor
final class KeyboardViewController: UIInputViewController {
    private let style = UIButton(type: .system)
    private let mic = UIButton(type: .system)
    private let status = UILabel()
    private var keys = UIStackView()

    private var shifted = true
    private var capsLocked = false
    private var layer = Layer.letters
    private var lastTyped: UUID?
    private var waitingSince: Date?
    private let waveform = WaveformView()
    private let prompt = UILabel()
    /// A tap leaves the microphone on; a hold ends when the finger lifts. Both are
    /// natural, and which one was meant is decided by how long the press lasted.
    private var pressedAt: Date?
    private var latched = false
    private var meter: Timer?
    private var heartbeat: Timer?

    private enum Layer {
        case letters, numbers, symbols

        var rows: [[String]] {
            switch self {
            case .letters:
                [Array("qwertyuiop").map(String.init),
                 Array("asdfghjkl").map(String.init),
                 Array("zxcvbnm").map(String.init)]
            case .numbers:
                [Array("1234567890").map(String.init),
                 ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
                 [".", ",", "?", "!", "'"]]
            case .symbols:
                [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
                 ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                 [".", ",", "?", "!", "'"]]
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Left where the app can read it: only an extension knows whether it has Full
        // Access, and the app's setup list needs the answer.
        Handoff.keyboardHasFullAccess = hasFullAccess

        buildUI()
        Handoff.observe(Handoff.transcript) { [weak self] in
            Task { @MainActor in self?.typeLatest() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The app checks this to decide whether the text needs to go via the
        // clipboard, or whether this keyboard is there to type it.
        Handoff.keyboardIsShowing(true)
        beat()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        heartbeat?.invalidate()
        Handoff.keyboardIsShowing(false)
    }

    /// Says "still here" while the keyboard stays up, so the flag going stale means
    /// the keyboard really is gone rather than merely quiet.
    private func beat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Handoff.keyboardIsShowing(true) }
        }
    }

    // MARK: Building

    private func buildUI() {
        view.addSubview(toolbar)
        waveform.backgroundColor = .clear
        waveform.isHidden = true
        waveform.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(waveform)

        prompt.font = .preferredFont(forTextStyle: .callout)
        prompt.textColor = .secondaryLabel
        prompt.textAlignment = .center
        prompt.isHidden = true
        prompt.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(prompt)

        keys = UIStackView(arrangedSubviews: [])
        keys.axis = .vertical
        keys.spacing = 8
        keys.distribution = .fillEqually
        keys.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keys)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            toolbar.heightAnchor.constraint(equalToConstant: 54),

            keys.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            keys.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            keys.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            keys.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            view.heightAnchor.constraint(equalToConstant: 300),

            // The bars take the keys' place while dictating, rather than sitting on
            // top of them: what is behind a keyboard mid-sentence is not interesting.
            waveform.topAnchor.constraint(equalTo: keys.topAnchor, constant: 12),
            waveform.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            waveform.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            waveform.heightAnchor.constraint(equalToConstant: 110),

            prompt.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 16),
            prompt.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            prompt.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        layoutKeys()
    }

    private lazy var toolbar: UIStackView = {
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabel
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.8

        style.showsMenuAsPrimaryAction = true
        style.changesSelectionAsPrimaryAction = false
        style.configuration = {
            var config = UIButton.Configuration.gray()
            config.image = UIImage(systemName: "chevron.down")
            config.imagePlacement = .trailing
            config.imagePadding = 6
            config.buttonSize = .small
            return config
        }()

        var micConfig = UIButton.Configuration.tinted()
        micConfig.image = UIImage(
            systemName: "mic.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        )
        micConfig.cornerStyle = .capsule
        micConfig.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        mic.configuration = micConfig
        mic.addTarget(self, action: #selector(startTalking), for: .touchDown)
        for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
            mic.addTarget(self, action: #selector(stopTalking), for: event)
        }

        let bar = UIStackView(arrangedSubviews: [status, style, mic])
        bar.spacing = 8
        bar.alignment = .center
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    /// Rebuilds the key rows for the current layer and shift state.
    private func layoutKeys() {
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let rows = layer.rows
        for (index, row) in rows.enumerated() {
            let line = UIStackView()
            line.spacing = 5
            line.distribution = .fillEqually

            // The last row carries shift and backspace on either side of the letters,
            // which are wider than a key and so sit outside the equal distribution.
            if index == rows.count - 1 {
                let wrapper = UIStackView()
                wrapper.spacing = 5
                wrapper.addArrangedSubview(modifier(
                    symbol: layer == .letters
                        ? (capsLocked ? "capslock.fill" : shifted ? "shift.fill" : "shift")
                        : nil,
                    title: layer == .letters ? nil : (layer == .numbers ? "#+=" : "123"),
                    action: #selector(toggleShift)
                ))
                for key in row { line.addArrangedSubview(self.key(key)) }
                wrapper.addArrangedSubview(line)
                wrapper.addArrangedSubview(modifier(symbol: "delete.left", title: nil, action: #selector(backspace)))
                line.widthAnchor.constraint(equalTo: wrapper.widthAnchor, multiplier: 0.72).isActive = true
                keys.addArrangedSubview(wrapper)
                continue
            }

            for key in row { line.addArrangedSubview(self.key(key)) }
            keys.addArrangedSubview(line)
        }

        keys.addArrangedSubview(bottomRow())
    }

    private func bottomRow() -> UIStackView {
        let switcher = modifier(symbol: nil, title: layer == .letters ? "123" : "ABC", action: #selector(switchLayer))

        let globe = modifier(symbol: "globe", title: nil, action: nil)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let space = key(" ")
        space.setTitle("space", for: .normal)
        space.titleLabel?.font = .systemFont(ofSize: 15)

        let enter = modifier(symbol: nil, title: "return", action: #selector(newLine))

        let row = UIStackView(arrangedSubviews: [switcher, globe, space, enter])
        row.spacing = 5
        space.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.42).isActive = true
        switcher.widthAnchor.constraint(equalTo: enter.widthAnchor).isActive = true
        return row
    }

    private func key(_ character: String) -> UIButton {
        let button = UIButton(type: .system)
        let label = layer == .letters && (shifted || capsLocked) ? character.uppercased() : character
        button.setTitle(label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 5
        button.accessibilityLabel = character == " " ? "space" : character
        button.addAction(UIAction { [weak self] _ in self?.type(character) }, for: .touchUpInside)
        return button
    }

    private func modifier(symbol: String?, title: String?, action: Selector?) -> UIButton {
        let button = UIButton(type: .system)
        if let symbol { button.setImage(UIImage(systemName: symbol), for: .normal) }
        if let title {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15)
        }
        button.tintColor = .label
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 5
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        return button
    }

    // MARK: Typing

    private func type(_ character: String) {
        let label = layer == .letters && (shifted || capsLocked) ? character.uppercased() : character
        textDocumentProxy.insertText(label)

        // Shift is for one letter unless it was locked, which is what everybody
        // expects and nobody says out loud.
        if shifted, !capsLocked, layer == .letters {
            shifted = false
            layoutKeys()
        }
    }

    @objc private func backspace() { textDocumentProxy.deleteBackward() }
    @objc private func newLine() { textDocumentProxy.insertText("\n") }

    @objc private func toggleShift(_ sender: UIButton) {
        guard layer == .letters else {
            layer = layer == .numbers ? .symbols : .numbers
            layoutKeys()
            return
        }

        // Double tap locks it, the same as the system keyboard.
        if shifted, !capsLocked, sender.isSelected {
            capsLocked = true
        } else if capsLocked {
            capsLocked = false
            shifted = false
        } else {
            shifted.toggle()
        }
        sender.isSelected = true
        layoutKeys()
    }

    @objc private func switchLayer() {
        layer = layer == .letters ? .numbers : .letters
        layoutKeys()
    }

    // MARK: Dictation

    @objc private func startTalking() {
        guard ready else {
            openApp()
            return
        }

        // Pressing the check mark is how a tapped dictation ends.
        if latched {
            latched = false
            finish()
            return
        }

        pressedAt = Date()
        Handoff.post(Handoff.start)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        showAudioMode()
    }

    @objc private func stopTalking() {
        guard ready, let pressedAt else { return }

        // A quick tap means "keep listening until I say"; a hold ends here.
        if Date().timeIntervalSince(pressedAt) < 0.4 {
            latched = true
            self.pressedAt = nil
            setMic(symbol: "checkmark", prominent: true)
            prompt.text = "Speak, then tap the check mark"
            return
        }

        self.pressedAt = nil
        finish()
    }

    /// Ends the dictation, whichever way it was started.
    private func finish() {
        Handoff.post(Handoff.stop)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        setMic(symbol: "mic.fill", prominent: false)
        prompt.text = "Transcribing…"
        meter?.invalidate()
        status.text = "Transcribing…"
        waitingSince = Date()

        // The app answers with a notification. If it does not, it was killed in the
        // background, and saying so beats a status line that never changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let since = waitingSince, Date().timeIntervalSince(since) >= 8 else { return }
            waitingSince = nil
            showKeys()
            refresh()
        }
    }

    private var ready: Bool { hasFullAccess && Handoff.isListening }

    // MARK: Audio mode

    /// The keys give way to the sound of your own voice while you dictate.
    private func showAudioMode() {
        keys.isHidden = true
        waveform.isHidden = false
        prompt.isHidden = false
        prompt.text = "Listening — let go to insert"
        waveform.reset()
        status.text = "Listening…"

        // The app writes what it hears into the shared container; this reads it.
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            self?.waveform.append(Handoff.level)
        }
    }

    private func showKeys() {
        meter?.invalidate()
        meter = nil
        latched = false
        pressedAt = nil
        keys.isHidden = false
        waveform.isHidden = true
        prompt.isHidden = true
        setMic(symbol: "mic.fill", prominent: false)
    }

    private func setMic(symbol: String, prominent: Bool) {
        var config = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        )
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
        mic.configuration = config
    }

    private func typeLatest() {
        waitingSince = nil
        guard let latest = History.load().entries.first, latest.id != lastTyped else { return }
        lastTyped = latest.id
        textDocumentProxy.insertText(latest.text)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showKeys()
        refresh()
    }

    /// Opening a URL is not part of a keyboard's own API, so it goes up the responder
    /// chain to whoever does have it. Unofficial, but it only ever opens this
    /// keyboard's own app, which dictation keyboards on the App Store (Wispr Flow
    /// among them) do the same way.
    private func openApp() {
        status.text = "Opening Free Scribe…"
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(Handoff.wakeURL)
                return
            }
            responder = current.next
        }
        status.text = "Open Free Scribe to dictate."
    }

    // MARK: State

    private func refresh() {
        style.setTitle(currentStyle.label, for: .normal)
        style.menu = UIMenu(children: DictationStyle.allCases.map { option in
            UIAction(title: option.label, state: option == currentStyle ? .on : .off) { [weak self] _ in
                UserDefaults(suiteName: Transcriber.appGroup)?.set(option.rawValue, forKey: "style")
                self?.refresh()
            }
        })

        guard hasFullAccess else {
            status.text = "Allow Full Access in Settings"
            return
        }
        status.text = Handoff.isListening ? "Tap or hold to talk\(remaining)" : "Tap the microphone to start"
    }

    private var currentStyle: DictationStyle {
        let raw = UserDefaults(suiteName: Transcriber.appGroup)?.string(forKey: "style") ?? ""
        return DictationStyle(rawValue: raw) ?? .tidy
    }

    private var remaining: String {
        guard let ends = Handoff.sessionEnds else { return "" }
        return " · \(max(0, Int(ends.timeIntervalSinceNow / 60) + 1))m"
    }
}
