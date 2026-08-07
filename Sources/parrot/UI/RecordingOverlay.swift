import AppKit
import SwiftUI

/// Borderless, click-through emoji cue near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
///   recording    → 🫵👂  (listening to you)
///   transcribing → 👌    (working on it)
///   done         → 👍    (brief flash, then fades out)
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
        case done
    }

    private var window: NSPanel?
    private let model = OverlayModel()

    func show(_ state: State) {
        ensureWindow()
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    /// Flash 👍 briefly, then fade out. Called when processing finished cleanly.
    func finish() {
        ensureWindow()
        guard let window else { return }
        if !window.isVisible {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
        }
        model.state = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if self.model.state == .done { self.hide() }
        }
    }

    func hide() {
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away.
        let window = self.window
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            // If something re-showed the cue during the animation (e.g. a fast
            // double-tap-to-lock), don't pull the window — it's wanted again.
            if model.state == .hidden {
                window?.orderOut(nil)
            }
        }
    }

    /// Kept for the audio pipeline's `onLevel` callback; the emoji cue ignores it.
    nonisolated func pushLevel(_ level: Float) {}

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayEmoji(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 20
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observable state for the SwiftUI cue.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: RecordingOverlay.State = .hidden
}

private struct OverlayEmoji: View {
    @ObservedObject var model: OverlayModel

    private var glyph: String {
        switch model.state {
        case .recording:    return "🫵👂"
        case .transcribing: return "👌"
        case .done:         return "👍"
        case .hidden:       return ""
        }
    }

    var body: some View {
        Text(glyph)
            .font(.system(size: 44))
            .frame(width: 140, height: 80)
            .scaleEffect(model.state == .hidden ? 0.4 : 1)
            .opacity(model.state == .hidden ? 0 : 1)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: model.state)
    }
}
