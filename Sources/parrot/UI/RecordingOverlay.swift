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

    /// Set the glyph shown for each stage.
    func setGlyphs(listening: Glyph, processing: Glyph, done: Glyph) {
        model.listening = listening
        model.processing = processing
        model.done = done
    }

    /// Set the glyph point size and the SF Symbol tint (emoji ignore the tint).
    func setStyle(size: CGFloat, symbolColor: Color) {
        model.size = size
        model.symbolColor = symbolColor
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 96),
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
    @Published var listening = Glyph.defaultListening
    @Published var processing = Glyph.defaultProcessing
    @Published var done = Glyph.defaultDone
    @Published var size: CGFloat = GlyphSize.medium.points
    @Published var symbolColor: Color = RGBAColor.defaultSymbol.color
}

private struct OverlayEmoji: View {
    @ObservedObject var model: OverlayModel

    private var glyph: Glyph? {
        switch model.state {
        case .recording:    return model.listening
        case .transcribing: return model.processing
        case .done:         return model.done
        case .hidden:       return nil
        }
    }

    var body: some View {
        // Sized to the largest glyph so nothing clips when set to Large.
        GlyphView(glyph: glyph, size: model.size, symbolColor: model.symbolColor)
            .frame(width: 160, height: 96)
            .scaleEffect(model.state == .hidden ? 0.4 : 1)
            .opacity(model.state == .hidden ? 0 : 1)
            .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: model.state)
    }
}

/// Renders a `Glyph` — emoji as text, SF Symbol as a tinted image. Shared by the
/// overlay and the settings preview so both look identical.
struct GlyphView: View {
    let glyph: Glyph?
    var size: CGFloat = 44
    var symbolColor: Color = .primary

    var body: some View {
        switch glyph?.kind {
        case .emoji:
            Text(glyph!.value).font(.system(size: size))
        case .symbol:
            Image(systemName: symbolExists(glyph!.value) ? glyph!.value : "questionmark.square.dashed")
                .font(.system(size: size * 0.86))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolColor)
        case nil:
            Color.clear
        }
    }

    private func symbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
