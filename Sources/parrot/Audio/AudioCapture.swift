import AVFoundation
import ExceptionCatcher
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
final class AudioCapture {
    enum CaptureError: Error {
        case engineStartFailed(Error)
        case converterCreationFailed
        case noInputAvailable
        case tapInstallFailed(Error)
    }

    static let targetSampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private var prewarmEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var isRecording = false
    private let lock = NSLock()
    /// Throttle for the level callback (audio-thread only), in mach nanoseconds.
    private var lastLevelNanos: UInt64 = 0

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    func start() throws {
        guard !isRecording else { return }
        stopPrewarm()   // release the priming stream before we take the mic
        lastLevelNanos = 0

        // Rebuild the engine every start. A long-lived AVAudioEngine caches the
        // input node's hardware format; after a sleep/wake cycle or an audio
        // device change that cache goes stale, so outputFormat(forBus:) returns
        // a plausible-but-wrong format that passes the checks below yet makes
        // installTap throw against the live hardware format. A fresh engine
        // reads the format from the current default device. (Real, shipped
        // crash in 0.1.50: installTap threw ~86 min in, across a wake.)
        engine = AVAudioEngine()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // A 0-channel / 0-sample-rate input format means there's no usable mic
        // right now (permission not granted yet, or no input device). Installing
        // a tap with such a format throws an Obj-C exception that crashes the
        // process, so bail out gracefully and let the caller surface it.
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.noInputAvailable
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterCreationFailed
        }
        self.converter = converter

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        // Defensively remove any stale tap before installing — installing a
        // second tap on the same bus throws an Obj-C exception (a crash).
        input.removeTap(onBus: 0)

        // Tap with input format; convert inside the callback. A small buffer
        // means frequent callbacks (~40/s), so the overlay's mic meter reacts
        // snappily to speech instead of lagging behind it.
        //
        // installTap raises an Obj-C NSException (which Swift's do/catch can't
        // catch — it would abort the app) if the format still doesn't match the
        // hardware, e.g. a device change between the format read above and here.
        // Catch it via the shim and surface it as a throwable Swift error.
        if let ex = ex_catching({
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.process(buffer: buffer, converter: converter, targetFormat: targetFormat)
            }
        }) {
            throw CaptureError.tapInstallFailed(ex)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }

        isRecording = true
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false

        lock.lock()
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        return captured
    }

    /// Spin the input device up briefly so the first real capture after a system
    /// wake isn't silent. After sleep the audio HAL delivers nothing until some
    /// stream has actually run on it; without this priming the first couple of
    /// dictations post-wake come back empty — the overlay and mic meter work,
    /// but the clip is silence. A ~1s no-op stream resumes the device, then we
    /// release the mic. No-op while a real capture is in progress or already
    /// priming. Call on the main thread (e.g. from the system-wake notification).
    func prewarm() {
        guard !isRecording, prewarmEngine == nil else { return }
        let warm = AVAudioEngine()
        let input = warm.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        // A no-op tap makes the engine actually pull from the device. installTap
        // can throw an Obj-C exception (see start()), so guard it the same way.
        if ex_catching({
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
        }) != nil { return }
        guard (try? warm.start()) != nil else {
            input.removeTap(onBus: 0)
            return
        }
        prewarmEngine = warm
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.stopPrewarm()
        }
    }

    private func stopPrewarm() {
        guard let warm = prewarmEngine else { return }
        warm.stop()
        warm.inputNode.removeTap(onBus: 0)
        prewarmEngine = nil
    }

    private func process(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Output buffer capacity scales with sample-rate ratio.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outCapacity
        ) else { return }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, let channelData = outBuffer.floatChannelData else { return }

        let count = Int(outBuffer.frameLength)
        let ptr = channelData[0]
        let chunk = Array(UnsafeBufferPointer(start: ptr, count: count))

        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        // Forward the level to the overlay at most ~30×/s. The tap fires ~47×/s
        // (1024-frame buffer); without throttling that floods the main actor with
        // UI updates and can stall it. `lastLevelNanos` is touched only here on
        // the (serialized) audio thread, so it needs no lock.
        if let onLevel {
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastLevelNanos >= 33_000_000 {
                lastLevelNanos = now
                onLevel(computeRMS(chunk))
            }
        }
    }
}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

func computeRMS(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
