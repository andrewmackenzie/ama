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

    /// Where the cue lives and how it's drawn:
    ///   glyph → a small emoji/SF-Symbol pill near the bottom center (classic).
    ///   notch → a wide bar descending from the top-center notch, with a
    ///           voice-reactive waveform (Talkify-style).
    enum Layout: Equatable {
        case glyph
        case notch
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    private var layout: Layout = .glyph

    /// Switch the overlay's look. Rebuilds the window on next show so its size
    /// and root view match the new layout.
    func setLayout(_ layout: Layout) {
        guard layout != self.layout else { return }
        self.layout = layout
        window?.orderOut(nil)
        window = nil
    }

    func show(_ state: State) {
        ensureWindow()
        if state == .recording { model.resetLevel() }
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            position(window)
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

    /// Flash the done glyph briefly, then fade out. Called when processing finished cleanly.
    func finish() {
        ensureWindow()
        guard let window else { return }
        if !window.isVisible {
            position(window)
            window.orderFrontRegardless()
        }
        model.state = .done
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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

    /// Set the glyph point size, the SF Symbol tint (emoji ignore the tint), and
    /// the pill behind the glyph (its color/opacity and how far it extends past
    /// the glyph).
    func setStyle(size: CGFloat, symbolColor: Color, pillColor: Color, pillPadding: CGFloat) {
        model.size = size
        model.symbolColor = symbolColor
        model.pillColor = pillColor
        model.pillPadding = pillPadding
    }

    /// Panel content size for the current layout. The notch bar is wide and
    /// short; the glyph pill is a small square.
    private var contentSize: NSSize {
        switch layout {
        case .glyph: return NSSize(width: 180, height: 180)
        case .notch: return NSSize(width: 360, height: 128)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Sit above the menu bar and other apps' full-screen windows. `.statusBar`
        // (25) isn't high enough to draw over a full-screen Space, so the cue would
        // silently not appear when dictating into e.g. a full-screen terminal.
        // `mainMenu + 3` owns the strip above the menu bar and full-screen apps
        // without any private API (the level Talkify's notch HUD uses).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let root = NSHostingView(rootView: OverlayRoot(model: model, layout: layout))
        root.frame = panel.contentView?.bounds ?? .zero
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        window = panel
    }

    /// Place the window for the current layout: notch descends from the top
    /// center; glyph floats near the bottom center.
    private func position(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        switch layout {
        case .glyph:
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.minY + 20
            ))
        case .notch:
            // Hug the physical top edge (over the menu bar / notch), centered.
            let full = screen.frame
            window.setFrameOrigin(NSPoint(
                x: full.midX - frame.width / 2,
                y: full.maxY - frame.height
            ))
        }
    }
}

/// Chooses the SwiftUI cue for the active layout so the hosting view stays one
/// type regardless of which look is showing.
private struct OverlayRoot: View {
    @ObservedObject var model: OverlayModel
    let layout: RecordingOverlay.Layout

    var body: some View {
        switch layout {
        case .glyph: OverlayEmoji(model: model)
        case .notch: NotchHUD(model: model)
        }
    }
}

/// Borderless panel that keeps the exact frame we set. AppKit otherwise
/// constrains a window to sit below the menu-bar strip, which would pull the
/// cue out from over a full-screen Space. Returning the frame unchanged (as
/// Talkify's notch HUD does) lets us place it wherever we computed.
private final class OverlayPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Observable state for the SwiftUI cue.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: RecordingOverlay.State = .hidden
    @Published var listening = Glyph.defaultListening
    @Published var processing = Glyph.defaultProcessing
    @Published var done = Glyph.defaultDone
    @Published var size: CGFloat = GlyphSize.medium
    @Published var symbolColor: Color = RGBAColor.defaultSymbol.color
    @Published var pillColor: Color = RGBAColor.defaultPill.color
    @Published var pillPadding: CGFloat = 28
    /// Smoothed mic level (0…1), for variable-value SF Symbols while recording.
    @Published var level: CGFloat = 0
    /// Rolling history of recent shaped levels (newest last), for the notch
    /// HUD's scrolling waveform. Fixed length so the bars don't reflow.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.barCount)
    static let barCount = 28
    private var smooth: Float = 0

    func updateLevel(_ raw: Float) {
        // Match the old waveform shaping so quiet speech still moves the meter.
        let shaped = min(1, sqrt(max(0, raw)) * 3.4)
        // Light smoothing only — keep it snappy so meter dots flip on/off with
        // speech and you can feel sentence endings, not a slow flowing fill.
        smooth += (shaped - smooth) * 0.8
        level = CGFloat(smooth)
        levels.removeFirst()
        levels.append(CGFloat(smooth))
    }

    func resetLevel() {
        smooth = 0
        level = 0
        levels = Array(repeating: 0, count: OverlayModel.barCount)
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
            // Pill backing so the glyph reads on any wallpaper. Color, opacity,
            // and how far it extends past the glyph are all user-adjustable.
            Circle()
                .fill(model.pillColor)
                .frame(width: model.size + model.pillPadding, height: model.size + model.pillPadding)
            content
        }
        .frame(width: 180, height: 180)
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

// MARK: - Notch HUD

/// A wide bar that drops from the top-center notch and reacts to your voice.
/// Recording shows a live waveform, transcribing an indeterminate pulse, done a
/// checkmark; hidden slides the bar back up under the notch.
private struct NotchHUD: View {
    @ObservedObject var model: OverlayModel

    private var isVisible: Bool { model.state != .hidden }

    var body: some View {
        VStack(spacing: 0) {
            NotchBar(model: model)
                .offset(y: isVisible ? 0 : -140)
                .opacity(isVisible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: 360, height: 128)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.state)
    }
}

private struct NotchBar: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        ZStack {
            NotchShape(cornerRadius: 20)
                .fill(Color.black)
                .overlay(
                    NotchShape(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            content
                .padding(.horizontal, 22)
        }
        .frame(width: 300, height: 54)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .recording:
            HStack(spacing: 12) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                WaveformRow(levels: model.levels)
            }
        case .transcribing:
            TranscribingPulse()
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .hidden:
            Color.clear
        }
    }
}

/// Fixed-count vertical bars driven by the rolling level history, so speech
/// scrolls right-to-left like a live meter.
private struct WaveformRow: View {
    let levels: [CGFloat]
    private let maxHeight: CGFloat = 34

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.55 + 0.45 * level))
                    .frame(width: 4, height: max(3, level * maxHeight))
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.05), value: levels)
    }
}

/// Indeterminate "working on it" pulse: three dots breathing in sequence.
private struct TranscribingPulse: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (sin(t * 4 - Double(i) * 0.7) + 1) / 2   // 0…1
                    Circle()
                        .fill(Color.white.opacity(0.4 + 0.6 * phase))
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.7 + 0.5 * phase)
                }
            }
        }
    }
}

/// A rectangle with square top corners (flush with the screen edge) and rounded
/// bottom corners, so the bar reads as an extension of the notch.
private struct NotchShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}
