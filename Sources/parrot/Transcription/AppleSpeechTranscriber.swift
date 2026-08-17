import AVFoundation
import Foundation
import Speech

/// On-device transcription via Apple's `SpeechAnalyzer` / `SpeechTranscriber`
/// (macOS 26+). This replaces the WhisperKit engine:
///
///   - No model downloads for us to manage — the language model is Apple-managed
///     through `AssetInventory`, installed once and shared across apps.
///   - No Neural Engine contention: Apple Speech doesn't fight the OS for the ANE
///     the way a WhisperKit CoreML decode did (the old intermittent-stall source).
///   - Streaming-capable, though ama records a full clip and transcribes on
///     release, so here we feed the whole buffer through a fresh analyzer and read
///     back the finalized text.
///
/// A warm "prepared" session is kept ready so the first hotkey press doesn't wait
/// on model preparation. Each `SpeechAnalyzer` is single-use (finalizing finishes
/// it), so a transcribe consumes the prepared session and prewarms the next.
actor AppleSpeechTranscriber: Transcriber {
    nonisolated let modelID = "Apple Speech (on-device)"

    /// A ready-to-run analyzer for a locale, built ahead of the keypress.
    private struct PreparedSession {
        let locale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let audioFormat: AVAudioFormat
    }

    private let localeIdentifier: String?
    private var prepared: PreparedSession?
    private var reservedLocale: Locale?

    init(localeIdentifier: String? = nil) {
        self.localeIdentifier = localeIdentifier
    }

    /// Build a prepared session so the first dictation is instant. Safe to call
    /// again; a no-op once warm.
    func warmUp() async throws {
        if prepared != nil { return }
        FileHandle.standardError.write(Data("preparing Apple Speech…\n".utf8))
        prepared = try await makePreparedSession()
        FileHandle.standardError.write(Data("✓ Apple Speech ready\n".utf8))
    }

    func transcribe(
        _ audio: [Float],
        onProgress: (@Sendable (TranscriptionProgressInfo) -> Void)? = nil
    ) async throws -> String {
        guard !audio.isEmpty else { return "" }

        let session = try await takePreparedSession()
        // Prepare the next session in the background regardless of how this ends,
        // so the following press is warm again.
        defer { prewarmNext() }

        let start = Date()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(64)
        )

        // Collect finalized text, streaming partials to the progress panel.
        let resultTask = Task { () throws -> String in
            var finalized = ""
            for try await result in session.transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                } else if let onProgress {
                    var info = TranscriptionProgressInfo()
                    info.text = finalized + text
                    info.elapsed = Date().timeIntervalSince(start)
                    onProgress(info)
                }
            }
            return finalized
        }

        try await session.analyzer.start(inputSequence: stream)

        // Feed the whole recorded clip as one buffer in the analyzer's format,
        // then close the input so recognition can finalize.
        let buffer = try Self.makeBuffer(from: audio, format: session.audioFormat)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        try await session.analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await resultTask.value

        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onProgress {
            var info = TranscriptionProgressInfo()
            info.isFinal = true
            info.fractionCompleted = 1
            info.text = clean
            info.elapsed = Date().timeIntervalSince(start)
            info.inputAudioSeconds = Double(audio.count) / AudioCapture.targetSampleRate
            onProgress(info)
        }
        return clean
    }

    // MARK: - Session preparation

    private func takePreparedSession() async throws -> PreparedSession {
        try await warmUp()
        guard let session = prepared else { throw TranscriberError.notLoaded }
        prepared = nil
        return session
    }

    private func prewarmNext() {
        Task { [weak self] in try? await self?.warmUp() }
    }

    private func makePreparedSession() async throws -> PreparedSession {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriberError.unavailable
        }

        let locale = try await resolveLocale()
        try await reserve(locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Bias toward responsiveness so partial text appears while speaking
            // rather than only at pauses.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )

        // Only a missing language model produces a request; installing it is the
        // one step here that can take real time.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let modules: [any SpeechModule] = [transcriber]
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw TranscriberError.missingAudioFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .lingering)
        )
        try await analyzer.prepareToAnalyze(in: audioFormat)

        return PreparedSession(
            locale: locale,
            transcriber: transcriber,
            analyzer: analyzer,
            audioFormat: audioFormat
        )
    }

    /// Resolve the configured (or system) language to a locale Apple Speech
    /// supports, falling back to the system language and then English.
    private func resolveLocale() async throws -> Locale {
        if let localeIdentifier,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) {
            return supported
        }
        if let current = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return current
        }
        if let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
            return english
        }
        guard let first = await SpeechTranscriber.supportedLocales.first else {
            throw TranscriberError.unsupportedLocale
        }
        return first
    }

    private func reserve(_ locale: Locale) async throws {
        if reservedLocale == locale { return }
        if let previous = reservedLocale {
            await AssetInventory.release(reservedLocale: previous)
        }
        _ = try await AssetInventory.reserve(locale: locale)
        reservedLocale = locale
    }

    // MARK: - Audio

    /// Pack the recorded 16 kHz mono clip into an `AVAudioPCMBuffer` in the
    /// analyzer's preferred format, converting sample rate / channel layout if
    /// they differ.
    private static func makeBuffer(from samples: [Float], format outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            sourceBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        if sourceFormat == outputFormat { return sourceBuffer }

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw TranscriberError.converterCreationFailed
        }
        let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw TranscriberError.converterCreationFailed
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry else {
            throw TranscriberError.converterCreationFailed
        }
        return outputBuffer
    }
}

enum TranscriberError: Error {
    case unavailable
    case unsupportedLocale
    case missingAudioFormat
    case converterCreationFailed
    case notLoaded
}
