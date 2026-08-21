import UIKit
import WhisperFlowCore

/// The keyboard itself. For now it exists to answer one question: how much memory
/// is left once the speech model is loaded inside an extension?
///
/// Extensions are given far less than an app and the ceiling is undocumented, so
/// the figure is measured rather than assumed.
final class KeyboardViewController: UIInputViewController {
    private let readout = UILabel()
    private var transcriber: Transcriber?

    override func viewDidLoad() {
        super.viewDidLoad()

        readout.numberOfLines = 0
        readout.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        readout.textAlignment = .center
        readout.translatesAutoresizingMaskIntoConstraints = false

        let next = UIButton(type: .system)
        next.setTitle("Switch keyboard", for: .normal)
        next.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        next.translatesAutoresizingMaskIntoConstraints = false

        let load = UIButton(type: .system)
        load.setTitle("Load the speech model", for: .normal)
        load.addTarget(self, action: #selector(loadModel), for: .touchUpInside)
        load.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(readout)
        view.addSubview(load)
        view.addSubview(next)

        NSLayoutConstraint.activate([
            readout.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            readout.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            readout.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            load.topAnchor.constraint(equalTo: readout.bottomAnchor, constant: 8),
            load.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            next.topAnchor.constraint(equalTo: load.bottomAnchor, constant: 8),
            next.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])

        report("at launch")
    }

    @objc private func loadModel() {
        report("loading…")
        Task {
            let transcriber = Transcriber()
            do {
                // The smallest model there is. If this does not fit, nothing will.
                try await transcriber.load(model: "openai_whisper-tiny.en") { _ in }
                self.transcriber = transcriber
                report("model loaded")
            } catch {
                report("failed: \(error.localizedDescription)")
            }
        }
    }

    private func report(_ stage: String) {
        let machine = MachineInfo.probe()
        readout.text = """
        \(MemoryProbe.describe(stage))
        device reports \(machine.ramGB) GB, \(machine.freeStorageGB) GB free
        would choose \(ModelPicker.label(for: ModelPicker.fallback(for: machine)))
        """
        NSLog("[free-scribe] %@", readout.text ?? "")
    }
}
