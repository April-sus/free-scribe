import AppKit
import SwiftUI

/// The floating capsule that appears while you dictate.
///
/// It must never take keyboard focus: the transcript is pasted into whatever app
/// was frontmost, so if this panel activates, the ⌘V lands here instead.
@MainActor
final class PillWindow {
    private static let size = NSSize(width: 260, height: 56)
    private static let bottomMargin: CGFloat = 120

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ state: AppState) {
        hideTask?.cancel()
        let panel = panel ?? makePanel(state)
        self.panel = panel
        reposition(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    /// Show, then hide on its own — used for errors, which have no natural end.
    func flash(_ state: AppState, seconds: Double = 4) {
        show(state)
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            hide()
        }
    }

    private func makePanel(_ state: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(state: state))
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.minY + Self.bottomMargin
        ))
    }
}

private struct PillView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Waveform(levels: state.levels, active: state.phase == .recording)
                .frame(width: 84, height: 24)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(ring, lineWidth: 1.5))
    }

    /// The border carries the state, so the pill reads at a glance without reading.
    private var ring: Color {
        switch state.phase {
        case .recording: Theme.accent.opacity(0.65)
        case .transcribing: Theme.accent.opacity(0.3)
        case .error: Theme.warning.opacity(0.7)
        default: .primary.opacity(0.1)
        }
    }

    private var label: String {
        switch state.phase {
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        case .error(let message): message
        default: state.statusText
        }
    }
}

/// Mirrored bars driven by the recorder's RMS history.
private struct Waveform: View {
    let levels: [Float]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            let count = 16
            let spacing: CGFloat = 3
            let barWidth = (size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            let recent = Array(levels.suffix(count))

            for index in 0..<count {
                // Right-align the history so new samples enter from the right.
                let offset = count - recent.count
                let level = index >= offset ? CGFloat(recent[index - offset]) : 0
                let height = max(3, level * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(active ? Theme.accent : .secondary.opacity(0.5))
                )
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}
