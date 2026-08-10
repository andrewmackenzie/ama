import Foundation
import WhisperKit

actor WhisperKitTranscriber: Transcriber {
    let modelID: String
    private let model: TranscriptionModel
    private var pipeline: WhisperKit?

    init(model: TranscriptionModel) {
        self.modelID = model.id
        self.model = model
    }

    /// Loads the model into memory; downloads first if not already on disk.
    /// Call once at startup so the first hotkey press isn't blocked on model
    /// download/load.
    func warmUp() async throws {
        if pipeline != nil { return }
        guard let whisperKitID = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        FileHandle.standardError.write(Data("loading \(model.id)...\n".utf8))
        // Run inference on the GPU, not the Neural Engine.
        //
        // WhisperKit defaults the audio encoder and (autoregressive) text decoder
        // to `.cpuAndNeuralEngine`. The ANE is a *shared, serialized* system
        // resource: on macOS 26 the OS itself (Apple Intelligence, Siri, Photos
        // analysis) hammers it in the background. When another process holds the
        // ANE, CoreML's async prediction suspends and its continuation isn't
        // resumed until the ANE frees — so the app sits fully idle (every thread
        // parked on a semaphore, the ANEServices thread waiting) for an
        // unpredictable stretch. That is the intermittent "stuck processing" stall:
        // variable 2–213s, often the first dictation, sometimes ~1 in 5.
        //
        // The GPU is effectively private to the app and not contended by system
        // ML, so decode never queues behind another process. For the default
        // base.en model it's just as fast; larger models are marginally slower but
        // never stall. `prefill` stays on CPU (its default).
        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndGPU,
            prefillCompute: .cpuOnly
        )
        let config = WhisperKitConfig(model: whisperKitID, computeOptions: compute, verbose: false, prewarm: true, load: true)
        pipeline = try await WhisperKit(config)
        // Run one throwaway inference on silence so the first *real* dictation
        // doesn't pay the one-time Neural Engine graph-specialization cost
        // (loading the model isn't enough; the first transcribe compiles it).
        if let pipeline {
            // Prime with real (synthesized) speech, not silence or noise: those
            // don't generate enough tokens to compile the decoder, so the first
            // real dictation still pays the one-time Neural Engine decoder
            // compile. A real-speech decode warms the full path.
            _ = try? await pipeline.transcribe(audioArray: PrimingAudio.samples)
        }
        FileHandle.standardError.write(Data("✓ \(model.id) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if pipeline == nil { try await warmUp() }
        guard let pipeline else { throw TranscriberError.notLoaded }

        let results = try await pipeline.transcribe(audioArray: audio)
        let raw = results.map(\.text).joined(separator: " ")
        return Self.sanitize(raw)
    }

    /// Strip Whisper's non-speech bracket tokens ([BLANK_AUDIO], [MUSIC],
    /// (silence), <|nospeech|>, etc.) and collapse whitespace. When the model
    /// hears silence it emits these literally; we don't want to paste them.
    static func sanitize(_ text: String) -> String {
        let patterns = [
            #"\[[^\]]*\]"#,        // [BLANK_AUDIO], [MUSIC], [Applause]
            #"\([^)]*\)"#,          // (silence), (music playing)
            #"<\|[^|]*\|>"#,        // <|nospeech|>, <|endoftext|>
            #"\*[^*]*\*"#,          // *background noise*
        ]
        var out = text
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriberError: Error {
    case missingEngineID
    case notLoaded
}
