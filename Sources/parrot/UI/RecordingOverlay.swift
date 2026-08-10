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
        if state == .recording { model.resetLevel() }
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

    /// Feed the mic level (0…~1 RMS). Drives variable-value SF Symbols (e.g.
    /// `microphone.and.signal.meter`) on the recording stage. Safe from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in self.model.updateLevel(level) }
    }

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
    /// Smoothed mic level (0…1), for variable-value SF Symbols while recording.
    @Published var level: CGFloat = 0
    private var smooth: Float = 0

    func updateLevel(_ raw: Float) {
        // Match the old waveform shaping so quiet speech still moves the meter.
        let shaped = min(1, sqrt(max(0, raw)) * 3.4)
        // Light smoothing only — keep it snappy so meter dots flip on/off with
        // speech and you can feel sentence endings, not a slow flowing fill.
        smooth += (shaped - smooth) * 0.8
        level = CGFloat(smooth)
    }

    func resetLevel() {
        smooth = 0
        level = 0
    }
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

    /// The signal meter's dot count (microphone.and.signal.meter has 4).
    private let meterDots = 4.0
    /// Level below which we still show a single "armed" dot. Above it, the
    /// remaining dots fill toward the top as you get louder.
    private let quietFloor = 0.45

    /// While recording, map the mic level to a whole number of lit dots so a
    /// signal-meter glyph snaps on/off like a hardware meter: 1 dot when quiet,
    /// climbing to all 4 when loud. Quantized values keep dots fully on/off.
    private var recordingValue: Double {
        let s = Double(model.level)
        let above = max(0, s - quietFloor) / (1 - quietFloor)   // 0…1 loud range
        let dots = 1 + (above * (meterDots - 1)).rounded()       // 1…4
        return dots / meterDots
    }

    var body: some View {
        ZStack {
            // Dark circular backing so the glyph reads on any wallpaper.
            Circle()
                .fill(Color.black.opacity(0.75))
                .frame(width: model.size + 28, height: model.size + 28)
            content
        }
        .frame(width: 160, height: 96)
        .scaleEffect(model.state == .hidden ? 0.4 : 1)
        .opacity(model.state == .hidden ? 0 : 1)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.24), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .transcribing:
            // No real progress signal, so loop a variable-value fill (0→1) to
            // animate progress.indicator like an indeterminate spinner. Symbols
            // without variable-value support just ignore it.
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: 1.1) / 1.1
                GlyphView(glyph: glyph, size: model.size, symbolColor: model.symbolColor, variableValue: phase)
            }
        case .recording:
            GlyphView(glyph: glyph, size: model.size, symbolColor: model.symbolColor, variableValue: recordingValue)
        default:
            GlyphView(glyph: glyph, size: model.size, symbolColor: model.symbolColor)
        }
    }
}

/// Renders a `Glyph` — emoji as text, SF Symbol as a tinted image. Shared by the
/// overlay and the settings preview so both look identical.
struct GlyphView: View {
    let glyph: Glyph?
    var size: CGFloat = 44
    var symbolColor: Color = .primary
    /// 0…1 fill for variable-value SF Symbols (e.g. signal meters). `nil` renders
    /// the symbol at full value. Ignored by symbols without variable-value support.
    var variableValue: Double? = nil

    var body: some View {
        switch glyph?.kind {
        case .emoji:
            Text(glyph!.value).font(.system(size: size))
        case .symbol:
            let name = symbolExists(glyph!.value) ? glyph!.value : "questionmark.square.dashed"
            // Monochrome so the whole glyph is your chosen color at full strength;
            // variable value dims only the inactive meter dots (a lighter shade of
            // the same color), instead of hierarchical tinting the mic body lighter.
            symbolImage(name)
                .font(.system(size: size * 0.86))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(symbolColor)
        case nil:
            Color.clear
        }
    }

    private func symbolImage(_ name: String) -> Image {
        if let variableValue {
            return Image(systemName: name, variableValue: variableValue)
        }
        return Image(systemName: name)
    }

    private func symbolExists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
