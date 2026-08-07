import AppKit
import Foundation

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
        dumpWav: Bool = false,
        debugHotkey: Bool = false
    ) {
        self.currentModelID = model.id
        self.transcriber = WhisperKitTranscriber(model: model)
        self.monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        self.overlayEnabled = showOverlay
        self.history = history
        self.doubleTapLockEnabled = doubleTapLock
        self.dumpWav = dumpWav
        if showOverlay {
            let overlay = RecordingOverlay()
            self.overlay = overlay
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
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
            let overlay = RecordingOverlay()
            self.overlay = overlay
            capture.onLevel = { level in overlay.pushLevel(level) }
        } else {
            overlay?.hide()
            overlay = nil
            capture.onLevel = nil
        }
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
            pendingTapSamples = samples
            awaitingSecondTap = true
            overlay?.hide()
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
        Task {
            do {
                let text = try await transcriber.transcribe(samples)
                await MainActor.run {
                    if !text.isEmpty {
                        TextInjector.inject(text)
                        self.lastTranscript = text
                        self.history?.add(text)
                    }
                    self.overlay?.hide()
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
