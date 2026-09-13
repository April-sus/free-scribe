import UIKit

/// The bars that move with your voice, as the Mac's pill and the Windows window
/// both draw them: a rolling history of loudness, newest on the right.
///
/// Seeing your own voice is the difference between "it is not working" and "speak
/// up" — with no bars there is nothing to tell you which, until the transcript
/// comes back empty.
final class WaveformView: UIView {
    private var levels: [CGFloat] = []
    private let capacity = 34

    func reset() {
        levels.removeAll()
        setNeedsDisplay()
    }

    /// The level arrives already scaled: `Recorder.rms` maps roughly -50 dB…0 dB
    /// onto 0…1, which is why the Mac's pill draws it straight against the height.
    /// Rescaling it here is what made every bar full — anything but silence was
    /// already past the top.
    func append(_ level: Float) {
        levels.append(min(max(CGFloat(level), 0), 1))
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !levels.isEmpty else { return }

        let spacing: CGFloat = 4
        let width = (rect.width - spacing * CGFloat(capacity - 1)) / CGFloat(capacity)
        let middle = rect.midY
        let colour = tintColor ?? .systemBlue

        for (index, level) in levels.enumerated() {
            // Drawn from the right, so the newest sound is nearest the microphone.
            let slot = capacity - levels.count + index
            let x = CGFloat(slot) * (width + spacing)
            // As the Mac draws it: the level against the full height, with a floor
            // thin enough that a quiet room reads as a flat line.
            let height = max(2, level * rect.height * 0.9)
            let bar = UIBezierPath(
                roundedRect: CGRect(x: x, y: middle - height / 2, width: width, height: height),
                cornerRadius: width / 2
            )
            colour.withAlphaComponent(0.25 + 0.75 * level).setFill()
            bar.fill()
        }
    }
}
