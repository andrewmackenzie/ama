import Foundation

/// A snapshot of everything WhisperKit reports about an in-flight (or just
/// finished) transcription. Surfaced live in the main window so the actual
/// numbers can be judged against real dictation lengths.
struct TranscriptionProgressInfo: Sendable, Equatable {
    // Foundation `Progress` on the pipeline — fraction of the audio seeked
    // through so far. Advances per 30s window, so short clips jump straight to 1.
    var fractionCompleted: Double = 0
    var completedSeconds: Double = 0        // Progress.completedUnitCount (audio s)
    var totalSeconds: Double = 0            // Progress.totalUnitCount (audio s)

    // Per-window decode state from the transcription callback.
    var windowId: Int = 0
    var tokenCount: Int = 0
    var text: String = ""                   // partial transcription so far
    var temperature: Float?
    var avgLogprob: Float?
    var compressionRatio: Float?

    // Wall-clock since transcription began (engine-measured).
    var elapsed: Double = 0

    // Filled once the final result is in.
    var isFinal: Bool = false
    var tokensPerSecond: Double?
    var realTimeFactor: Double?
    var fullPipelineSeconds: Double?
    var inputAudioSeconds: Double?
    var totalDecodingLoops: Double?
}

protocol Transcriber {
    var modelID: String { get }
    /// Transcribe audio, optionally reporting live progress. `onProgress` may be
    /// called from a background thread and should hop to the main actor itself.
    func transcribe(_ audio: [Float], onProgress: (@Sendable (TranscriptionProgressInfo) -> Void)?) async throws -> String
}
