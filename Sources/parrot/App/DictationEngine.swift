import AppKit
import Foundation
import SwiftUI

/// The dictation pipeline, extracted from the old inline `Run.run()` wiring so
/// both the GUI (`AppDelegate`) and the CLI (`Run`) drive the exact same code:
/// hotkey → capture → transcribe → inject, with optional overlay + history.
@MainActor
final class DictationEngine: ObservableObject {
    enum Status: Equatable {
        case loading          // warming up / downloading the model
        case idle             // listening for the hotkey
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var status: Status = .loading
    @Published private(set) var currentModelID: String
    @Published private(set) var lastTranscript: String = ""
    /// True once the accessibility-backed hotkey tap is live.
    @Published private(set) var hotkeyActive = false
    /// True while in hands-free (double-tap) dictation; press again to stop.
    @Published private(set) var isLocked = false

    private let monitor: HotkeyMonitor
    private let capture = AudioCapture()
    private var transcriber: WhisperKitTranscriber
    private var overlay: RecordingOverlay?
    private var history: History?

    private var overlayEnabled: Bool
    private let dumpWav: Bool
    private var modelReady = false

    // Per-stage overlay glyphs (emoji or SF Symbol) + shared size/tint.
    private var listeningGlyph: Glyph
    private var processingGlyph: Glyph
    private var doneGlyph: Glyph
    private var glyphSize: CGFloat
    private var symbolColor: Color

    // AI text cleanup (Apple Foundation Models).
    private var cleanupEnabled: Bool
    private var writingStyle: String

    // Double-tap-to-lock state.
    private var doubleTapLockEnabled: Bool
    /// Max gap between the two taps to count as a double-tap.
    private let doubleTapWindow: TimeInterval = 0.35
    /// A press-release shorter than this is treated as a "tap" (a possible first
    /// tap of a double-tap) rather than a push-to-talk hold.
    private let shortTapDwell: TimeInterval = 0.30
    private var pressTime: Date?
    private var awaitingSecondTap = false
    private var pendingTapSamples: [Float]?
    private var deferredTranscribe: DispatchWorkItem?
    /// Set when a press is consumed as a control gesture (lock/stop) so its
    /// matching release is ignored.
    private var ignoreNextRelease = false

    init(
        model: TranscriptionModel,
        hotkey: Hotkey,
        showOverlay: Bool,
        history: History? = nil,
        doubleTapLock: Bool = true,
        cleanup: Bool = false,
        writingStyle: String = "",
        listeningGlyph: Glyph = .defaultListening,
        processingGlyph: Glyph = .defaultProcessing,
        doneGlyph: Glyph = .defaultDone,
        glyphSize: CGFloat = GlyphSize.medium.points,
        symbolColor: Color = RGBAColor.defaultSymbol.color,
        dumpWav: Bool = false,
        debugHotkey: Bool = false
    ) {
        self.currentModelID = model.id
        self.transcriber = WhisperKitTranscriber(model: model)
        self.monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        self.overlayEnabled = showOverlay
        self.history = history
        self.doubleTapLockEnabled = doubleTapLock
        self.cleanupEnabled = cleanup
        self.writingStyle = writingStyle
        self.listeningGlyph = listeningGlyph
        self.processingGlyph = processingGlyph
        self.doneGlyph = doneGlyph
        self.glyphSize = glyphSize
        self.symbolColor = symbolColor
        self.dumpWav = dumpWav
        if showOverlay {
            self.overlay = makeOverlay()
        }
    }

    /// Build an overlay wired to the audio meter and current glyph choices.
    private func makeOverlay() -> RecordingOverlay {
        let overlay = RecordingOverlay()
        overlay.setGlyphs(listening: listeningGlyph, processing: processingGlyph, done: doneGlyph)
        overlay.setStyle(size: glyphSize, symbolColor: symbolColor)
        capture.onLevel = { level in overlay.pushLevel(level) }
        return overlay
    }

    // MARK: - Lifecycle

    /// Register the hotkey tap and warm up the model. Safe to call again after a
    /// failure (e.g. once the user grants Accessibility).
    func start() {
        startHotkey()
        warmUpModel()
    }

    /// Attempt to register the global hotkey tap. Sets `hotkeyActive` and, on
    /// failure, surfaces an error status (usually missing Accessibility).
    func startHotkey() {
        guard !hotkeyActive else { return }
        do {
            try monitor.start { [weak self] event in
                guard let self else { return }
                switch event {
                case .pressed: self.handlePress()
                case .released: self.handleRelease()
                }
            }
            hotkeyActive = true
            // Clear a prior accessibility error now that the tap is live.
            status = modelReady ? .idle : .loading
        } catch {
            hotkeyActive = false
            status = .error("Accessibility permission needed for the hotkey.")
        }
    }

    private func warmUpModel() {
        if hotkeyActive { status = .loading }
        let transcriber = self.transcriber
        Task {
            do {
                try await transcriber.warmUp()
                await MainActor.run {
                    self.modelReady = true
                    if self.hotkeyActive { self.status = .idle }
                }
            } catch {
                await MainActor.run {
                    self.status = .error("Model failed to load: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        monitor.stop()
        hotkeyActive = false
    }

    // MARK: - Settings changes

    func setHotkey(_ hotkey: Hotkey) {
        monitor.setHotkey(hotkey)
    }

    /// Set (or clear) the history sink transcripts are appended to.
    func setHistory(_ history: History?) {
        self.history = history
    }

    func setCleanup(_ enabled: Bool) { cleanupEnabled = enabled }
    func setWritingStyle(_ style: String) { writingStyle = style }

    func setDoubleTapLock(_ enabled: Bool) {
        doubleTapLockEnabled = enabled
        if !enabled {
            // Flush any pending first-tap clip so nothing is left dangling.
            cancelDeferredTranscribe()
            if awaitingSecondTap {
                awaitingSecondTap = false
                let samples = pendingTapSamples ?? []
                pendingTapSamples = nil
                transcribeAndInject(samples)
            }
        }
    }

    func setOverlayEnabled(_ enabled: Bool) {
        guard enabled != overlayEnabled else { return }
        overlayEnabled = enabled
        if enabled {
            self.overlay = makeOverlay()
        } else {
            overlay?.hide()
            overlay = nil
            capture.onLevel = nil
        }
    }

    /// Update the per-stage overlay glyphs live.
    func setGlyphs(listening: Glyph, processing: Glyph, done: Glyph) {
        listeningGlyph = listening
        processingGlyph = processing
        doneGlyph = done
        overlay?.setGlyphs(listening: listening, processing: processing, done: done)
    }

    /// Update the overlay glyph size and SF Symbol tint live.
    func setGlyphStyle(size: CGFloat, symbolColor: Color) {
        glyphSize = size
        self.symbolColor = symbolColor
        overlay?.setStyle(size: size, symbolColor: symbolColor)
    }

    /// Flash the overlay through all three stages so the user can preview their
    /// glyph choices without dictating. No-op if the overlay is disabled.
    func previewGlyphs() {
        guard let overlay else { return }
        overlay.show(.recording)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { overlay.show(.transcribing) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { overlay.finish() }
    }

    /// Switch to a different model: swap the transcriber and warm it up.
    func reload(model: TranscriptionModel) {
        currentModelID = model.id
        transcriber = WhisperKitTranscriber(model: model)
        modelReady = false
        status = .loading
        warmUpModel()
    }

    // MARK: - Hotkey gestures
    //
    // Gestures on the push-to-talk key:
    //   • Hold → record while held, transcribe on release (push-to-talk).
    //   • Double-tap → lock into hands-free dictation; press again to stop.
    // To keep push-to-talk instant, only a *short* tap defers briefly to see if
    // a second tap follows; a real hold transcribes immediately on release.

    private func handlePress() {
        // Ignore presses until the model is ready.
        if case .loading = status { return }

        if isLocked {
            // Press-to-stop while locked.
            ignoreNextRelease = true
            finishLocked()
            return
        }

        if awaitingSecondTap {
            // Second tap → enter hands-free locked mode; discard the first clip.
            awaitingSecondTap = false
            cancelDeferredTranscribe()
            pendingTapSamples = nil
            ignoreNextRelease = true
            enterLocked()
            return
        }

        // Normal press → begin a (tentative) push-to-talk recording.
        startCapture()
        pressTime = Date()
    }

    private func handleRelease() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        if isLocked { return }
        guard status == .recording else {
            _ = capture.stop()
            return
        }

        let dwell = pressTime.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let samples = capture.stop()

        if doubleTapLockEnabled, dwell < shortTapDwell {
            // Possibly the first tap of a double-tap. Hold the clip and wait a
            // moment; if a second tap arrives we discard it and lock instead.
            // Keep the pill up during the wait so it stays continuous into lock.
            pendingTapSamples = samples
            awaitingSecondTap = true
            status = .idle
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.awaitingSecondTap = false
                let pending = self.pendingTapSamples ?? []
                self.pendingTapSamples = nil
                self.transcribeAndInject(pending)
            }
            deferredTranscribe = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        } else {
            // Normal push-to-talk.
            transcribeAndInject(samples)
        }
    }

    // MARK: - Recording helpers

    private func startCapture() {
        do {
            try capture.start()
            status = .recording
            overlay?.show(.recording)
        } catch {
            log("capture failed: \(error)")
            status = .idle
            overlay?.hide()
        }
    }

    private func enterLocked() {
        startCapture()
        if status == .recording {
            isLocked = true
        }
    }

    private func finishLocked() {
        isLocked = false
        let samples = capture.stop()
        transcribeAndInject(samples)
    }

    private func cancelDeferredTranscribe() {
        deferredTranscribe?.cancel()
        deferredTranscribe = nil
    }

    private func transcribeAndInject(_ samples: [Float]) {
        if dumpWav, !samples.isEmpty {
            try? WAVWriter.write(samples: samples, sampleRate: 16_000, to: "/tmp/ama-last.wav")
        }
        guard !samples.isEmpty else {
            overlay?.hide()
            status = .idle
            return
        }
        status = .transcribing
        overlay?.show(.transcribing)

        let transcriber = self.transcriber
        let style = writingStyle
        // Read the target (frontmost) app now, on the main actor, so cleanup can
        // adapt to it — and skip cleanup entirely in code/terminal apps.
        let appContext = AppContext.frontmost()
        let doCleanup = cleanupEnabled && !appContext.category.skipsCleanup
        Task {
            do {
                var text = try await transcriber.transcribe(samples)
                if doCleanup, !text.isEmpty {
                    text = await TextCleaner.clean(text, profile: style, context: appContext.promptContext)
                }
                let finalText = text
                await MainActor.run {
                    if !finalText.isEmpty {
                        TextInjector.inject(finalText)
                        self.lastTranscript = finalText
                        self.history?.add(finalText)
                    }
                    self.overlay?.finish()
                    self.status = .idle
                }
            } catch {
                await MainActor.run {
                    self.log("transcription failed: \(error)")
                    self.overlay?.hide()
                    self.status = .idle
                }
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
