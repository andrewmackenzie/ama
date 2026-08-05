import Foundation
import WhisperKit

/// Tracks which transcription models are present on disk and downloads missing
/// ones with progress, for the Models screen.
///
/// WhisperKit stores CoreML models under the swift-transformers Hub default
/// (`~/Documents/huggingface/models/<repo>/<variant>/`). We check that path for
/// presence and drive downloads through `WhisperKit.download`, which is
/// idempotent — it no-ops when the variant is already cached.
@MainActor
final class ModelManager: ObservableObject {
    /// id of the model currently downloading, if any.
    @Published private(set) var downloadingID: String?
    /// 0…1 progress for the active download.
    @Published private(set) var progress: Double = 0
    /// Bumped after a download completes so views re-check presence.
    @Published private(set) var revision = 0

    private static let repo = "argmaxinc/whisperkit-coreml"

    private var hubBase: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// Folder a given model's files land in once downloaded.
    private func modelFolder(for model: TranscriptionModel) -> URL? {
        guard let variant = model.whisperKitID else { return nil }
        return hubBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.repo, isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    func isDownloaded(_ model: TranscriptionModel) -> Bool {
        guard let folder = modelFolder(for: model) else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        return !contents.isEmpty
    }

    func download(_ model: TranscriptionModel) async throws {
        guard let variant = model.whisperKitID else {
            throw TranscriberError.missingEngineID
        }
        downloadingID = model.id
        progress = 0
        defer {
            downloadingID = nil
            progress = 0
            revision += 1
        }
        _ = try await WhisperKit.download(variant: variant, from: Self.repo) { prog in
            Task { @MainActor in
                self.progress = prog.fractionCompleted
            }
        }
    }
}
