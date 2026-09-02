import Foundation

/// A snapshot of an in-flight (or just finished) transcription, surfaced live in
/// the main window. Most fields date from the WhisperKit engine; with Apple
/// Speech only `text`, `elapsed`, `inputAudioSeconds`, and `isFinal` are filled.
struct TranscriptionProgressInfo: Sendable, Equatable {
    // Fraction of the audio processed so far (0…1).
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

protocol Transcriber: Sendable {
    /// A human-readable label for the active engine (shown in the UI).
    var modelID: String { get }
    /// Prepare the engine so the first transcription isn't blocked on setup.
    func warmUp() async throws
    /// Transcribe audio, optionally reporting live progress. `onProgress` may be
    /// called from a background thread and should hop to the main actor itself.
    func transcribe(_ audio: [Float], onProgress: (@Sendable (TranscriptionProgressInfo) -> Void)?) async throws -> String
    /// Update the recognizer's contextual-bias terms (proper nouns to spell
    /// correctly) live, so a Settings edit takes effect without a relaunch.
    func updateContextualStrings(_ terms: [String]) async
}

extension Transcriber {
    /// Default no-op: engines without recognition-time biasing ignore this.
    func updateContextualStrings(_ terms: [String]) async {}
}
