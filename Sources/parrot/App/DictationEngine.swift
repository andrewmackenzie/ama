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

    private let monitor: HotkeyMonitor
    private let capture = AudioCapture()
    private var transcriber: WhisperKitTranscriber
    private var overlay: RecordingOverlay?
    private var history: History?

    private var overlayEnabled: Bool
    private let dumpWav: Bool
    private var modelReady = false

    init(
        model: TranscriptionModel,
        hotkey: Hotkey,
        showOverlay: Bool,
        history: History? = nil,
        dumpWav: Bool = false,
        debugHotkey: Bool = false
    ) {
        self.currentModelID = model.id
        self.transcriber = WhisperKitTranscriber(model: model)
        self.monitor = HotkeyMonitor(hotkey: hotkey, debug: debugHotkey)
        self.overlayEnabled = showOverlay
        self.history = history
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
                case .pressed: self.beginRecording()
                case .released: self.endRecording()
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

    // MARK: - Recording

    private func beginRecording() {
        // Ignore hotkey presses until the model is ready.
        if case .loading = status { return }
        do {
            try capture.start()
            status = .recording
            overlay?.show(.recording)
        } catch {
            log("capture failed: \(error)")
        }
    }

    private func endRecording() {
        guard status == .recording else {
            // Handle a release that arrives without a matching start.
            _ = capture.stop()
            return
        }
        let samples = capture.stop()
        status = .transcribing
        overlay?.show(.transcribing)

        if dumpWav, !samples.isEmpty {
            try? WAVWriter.write(samples: samples, sampleRate: 16_000, to: "/tmp/parrot-last.wav")
        }

        guard !samples.isEmpty else {
            overlay?.hide()
            status = .idle
            return
        }

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
