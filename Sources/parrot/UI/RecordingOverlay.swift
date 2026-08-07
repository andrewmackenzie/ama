import AppKit
import QuartzCore
import SwiftUI

/// Borderless, click-through ripple-dot near the bottom of the active screen.
/// Driven by the daemon's hotkey + transcription lifecycle.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
    }

    /// Square canvas side. Big enough for rings to travel before they fade.
    static let side: CGFloat = 132

    private var window: NSPanel?
    private let model = OverlayModel()

    func show(_ state: State) {
        ensureWindow()
        if state == .recording {
            model.reset()
        }
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

    func hide() {
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away.
        let window = self.window
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            // If something re-showed the pill during the animation (e.g. a fast
            // double-tap-to-lock), don't pull the window — it's wanted again.
            if model.state == .hidden {
                window?.orderOut(nil)
            }
        }
    }

    /// Push a new audio level (0…~1 RMS). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let side = Self.side
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false               // the dot draws its own soft glow
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayDot(model: model))
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
        // Sit the dot's center a comfortable distance above the bottom edge.
        let y = visible.minY + 20
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Model

/// A single expanding ring shed by a loud moment.
private struct Ring: Identifiable {
    let id: Int
    var radius: CGFloat
    var velocity: CGFloat   // points / second
    var alpha: CGFloat
    var lineWidth: CGFloat
}

/// Observable state + ripple physics for the SwiftUI dot.
/// A ~60fps timer integrates ring positions; `pushLevel` feeds it audio and
/// detects onsets (loud peaks) that launch new rings.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: RecordingOverlay.State = .hidden {
        didSet { syncTimer() }
    }
    /// Bumped every animation frame so `Canvas` redraws. Ring data lives in
    /// plain storage to keep per-frame publishing cheap.
    @Published private(set) var frameTick: Int = 0

    // Physics geometry (points), sized for the 132pt canvas.
    private let coreBase: CGFloat = 6.5
    private let coreSwell: CGFloat = 8.0
    private let maxRadius: CGFloat = RecordingOverlay.side / 2 - 4

    // Onset thresholds (on the shaped 0…1 loudness).
    private let onsetRise: Float = 0.16
    private let onsetFloor: Float = 0.46
    private let onsetGap: CFTimeInterval = 0.32

    // Live state read by the view each frame.
    fileprivate private(set) var rings: [Ring] = []
    private(set) var coreLevel: CGFloat = 0        // smoothed 0…1, drives the dot's swell

    private var smooth: Float = 0
    private var prevLoud: Float = 0
    private var lastOnset: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = 0
    private var nextRingID = 0
    private var transcribeClock: CFTimeInterval = 0

    private var timer: Timer?

    // MARK: audio in

    func pushLevel(_ level: Float) {
        // Match the waveform shaping so quiet RMS still reads as motion.
        let loud = min(1.0, sqrt(max(0, level)) * 3.4)
        let now = CACurrentMediaTime()
        let rising = loud - prevLoud
        if rising > onsetRise, loud > onsetFloor, now - lastOnset > onsetGap {
            launchRing(strength: CGFloat(min(1, loud)))
            lastOnset = now
        }
        prevLoud = loud
        // Target for the smoothed core; actual easing happens in step().
        latestLoud = loud
    }

    private var latestLoud: Float = 0

    func reset() {
        rings.removeAll()
        smooth = 0
        prevLoud = 0
        latestLoud = 0
        coreLevel = 0
        transcribeClock = 0
    }

    // MARK: physics

    private func launchRing(strength: CGFloat) {
        let core = coreBase + strength * coreSwell
        rings.append(Ring(
            id: nextRingID,
            radius: core,
            velocity: 15 + strength * 34,        // slow, momentum-y (tuned in the study)
            alpha: 0.5 + strength * 0.25,
            lineWidth: 2.4
        ))
        nextRingID &+= 1
    }

    private func syncTimer() {
        let shouldRun = state != .hidden || !rings.isEmpty
        if shouldRun, timer == nil {
            lastTick = CACurrentMediaTime()
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !shouldRun, timer != nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func step() {
        let now = CACurrentMediaTime()
        var dt = now - lastTick
        lastTick = now
        if dt > 0.05 { dt = 0.05 }
        let dtF = Float(dt)

        // While transcribing there's no mic; breathe a synthetic level so the
        // dot keeps a calm, self-driven pulse and sheds a slow ring now and then.
        if state == .transcribing {
            transcribeClock += dt
            let breathe = Float((sin(transcribeClock * 2.0) + 1) / 2) * 0.5 + 0.12
            latestLoud = breathe
            if transcribeClock.truncatingRemainder(dividingBy: 1.25) < dt {
                launchRing(strength: 0.45)
            }
        }

        // Ease the core toward the latest loudness.
        smooth += (latestLoud - smooth) * min(1, dtF * 14)
        if state == .hidden { latestLoud = 0 }
        coreLevel = CGFloat(smooth)

        // Advance + fade rings.
        let core = coreBase + coreLevel * coreSwell
        for i in rings.indices.reversed() {
            rings[i].radius += rings[i].velocity * CGFloat(dt)
            let fade = CGFloat(dt) * 0.42 * (0.5 + rings[i].radius / maxRadius)
            rings[i].alpha -= fade
            if rings[i].alpha <= 0 || rings[i].radius > maxRadius {
                rings.remove(at: i)
            }
        }
        _ = core

        frameTick &+= 1

        // Stop the clock once everything's settled and we're hidden.
        if state == .hidden, rings.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - View

private struct OverlayDot: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Palette(scheme)
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let core = 6.5 + model.coreLevel * 8.0

            // Expanding rings.
            for ring in model.rings {
                let rect = CGRect(
                    x: c.x - ring.radius, y: c.y - ring.radius,
                    width: ring.radius * 2, height: ring.radius * 2
                )
                ctx.stroke(
                    Path(ellipseIn: rect),
                    with: .color(palette.ring.opacity(Double(max(0, ring.alpha)))),
                    lineWidth: ring.lineWidth
                )
            }

            // Soft backing halo so the core stays legible on any wallpaper.
            let haloR = core * 2.4
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - haloR, y: c.y - haloR, width: haloR * 2, height: haloR * 2)),
                with: .radialGradient(
                    Gradient(colors: [palette.backing, palette.backing.opacity(0)]),
                    center: c, startRadius: 0, endRadius: haloR
                )
            )

            // Blue glow that intensifies with your voice.
            let glowR = core * 2.9
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                with: .radialGradient(
                    Gradient(colors: [
                        palette.glow.opacity(0.30 + Double(model.coreLevel) * 0.38),
                        palette.glow.opacity(0),
                    ]),
                    center: c, startRadius: 0, endRadius: glowR
                )
            )

            // The core dot.
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                with: .color(palette.core)
            )
        }
        // `frameTick` is @Published; each tick invalidates this ObservedObject,
        // re-evaluates the body, and redraws the Canvas from fresh ring state.
        .frame(width: RecordingOverlay.side, height: RecordingOverlay.side)
        .scaleEffect(model.state == .hidden ? 0.4 : 1)
        .opacity(model.state == .hidden ? 0 : 1)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.28), value: model.state)
    }
}

/// Light/dark-adaptive colors. Light mode uses a saturated blue so the dot and
/// rings read on bright wallpapers; dark mode uses the airy accent blue.
private struct Palette {
    let core: Color
    let ring: Color
    let glow: Color
    let backing: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            core = Color(red: 0.82, green: 0.88, blue: 1.0)      // #D0E0FF
            ring = Color(red: 0.59, green: 0.75, blue: 1.0)      // #96BFFF
            glow = Color(red: 0.36, green: 0.55, blue: 1.0)      // #5B8BFF
            backing = Color.black.opacity(0.30)
        } else {
            core = Color(red: 0.15, green: 0.40, blue: 0.90)     // #2666E6
            ring = Color(red: 0.20, green: 0.45, blue: 0.92)     // #3373EB
            glow = Color(red: 0.28, green: 0.50, blue: 1.0)      // #477FFF
            backing = Color.white.opacity(0.55)
        }
    }
}
