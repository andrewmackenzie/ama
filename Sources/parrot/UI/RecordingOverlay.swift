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
    private var rebuildObservers: [NSObjectProtocol] = []

    init() {
        // The window server can strand a `.screenSaver`-level panel across a
        // display sleep/wake or a screen reconfiguration: the panel stays
        // non-nil (so `ensureWindow()` never rebuilds it) but
        // `orderFrontRegardless()` no longer draws it, and the cue silently
        // stops appearing until relaunch — "the overlay stops showing after the
        // Mac's been up a while." Displays sleep far more often than the system
        // does, so `screensDidWake` is the usual trigger. On any of these,
        // invalidate the panel so the next `show()` builds a fresh one.
        let rebuild: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        rebuildObservers = [
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: rebuild),
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: rebuild),
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: rebuild),
        ]
    }

    deinit {
        let ws = NSWorkspace.shared.notificationCenter
        for token in rebuildObservers {
            ws.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Drop the panel so the next `show()` rebuilds it via `ensureWindow()`.
    /// Cheap: rebuilding is deferred to the next dictation, and a stranded panel
    /// is already invisible, so there's nothing to flash.
    func invalidate() {
        window?.orderOut(nil)
        window = nil
        model.state = .hidden
    }

    func show(_ state: State) {
        ensureWindow()
        if state == .recording { model.resetLevel() }
        guard let window else { return }
        // Whether to play the grow-in animation: only when coming from nothing.
        // This flag must NOT gate the ordering — that was the full-screen bug.
        let appearing = model.state == .hidden || !window.isVisible
        // Re-pull the panel onto the *currently active* Space on every show. A HUD
        // ordered-in on one Space (e.g. the desktop) does not follow you into a
        // full-screen app's Space on its own, and we can't skip `orderFrontRegardless`
        // to find out: after a Space switch `window.isVisible` reports a stale `true`
        // while the panel sits off-screen on the old Space. Gating on it (the old
        // code) stranded the cue — no overlay when dictating into full-screen
        // Terminal. Ordering front unconditionally lands it on the active Space;
        // re-asserting the collection behavior forces the window server to
        // re-evaluate Space membership.
        presentOnActiveSpace(window)
        if appearing {
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
        // Same reasoning as `show(_:)`: always re-pull onto the active Space rather
        // than trusting `isVisible`, or the done glyph never appears over a
        // full-screen app.
        presentOnActiveSpace(window)
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

    private func ensureWindow() {
        if window != nil { return }
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Sit above the menu bar and other apps' full-screen windows. `.statusBar`
        // (25) and even `mainMenu + 3` (28) aren't reliably high enough to draw
        // over a full-screen Space, so the cue would silently not appear when
        // dictating into e.g. a full-screen terminal. `.screenSaver` (1000) is the
        // classic level for a HUD that must float over full-screen apps, no private
        // API needed. Paired with `.canJoinAllSpaces` + `.fullScreenAuxiliary` below.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // `hidesOnDeactivate = false` only survives *deactivation* (clicking into
        // another app). It does NOT survive an explicit "Hide Ama" (⌘H): AppKit
        // hides every window whose `canHide` is true along with the app. That left
        // the overlay stuck — hidden with the app, and never shown again even after
        // Ama was reopened. Opting out of app-hide keeps the cue a real HUD that
        // fires on the hotkey regardless of whether Ama itself is hidden.
        panel.canHide = false

        let host = NSHostingView(rootView: OverlayEmoji(model: model))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    /// Bring the panel onto the *currently active* Space and order it front. Must
    /// run on every show — see the note in `show(_:)`. Re-asserting the collection
    /// behavior makes the window server re-evaluate which Space the panel joins,
    /// which is what fixes the intermittent no-overlay-over-full-screen bug.
    private func presentOnActiveSpace(_ window: NSPanel) {
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        positionAtBottomCenter(window)
        window.orderFrontRegardless()
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
