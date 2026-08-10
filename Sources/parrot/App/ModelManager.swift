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
    /// A downloaded model whose files changed upstream (a newer build exists).
    @Published private(set) var updatableModel: TranscriptionModel?

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
        // Record what we just downloaded so we can detect future upstream
        // changes, and clear any pending "update available" for this model.
        if let fp = await Self.remoteFingerprint(variant: variant) {
            Self.storeFingerprint(fp, for: model.id)
        }
        if updatableModel?.id == model.id { updatableModel = nil }
    }

    // MARK: - Update checking

    /// Check each downloaded model against Hugging Face for a newer build. Sets
    /// `updatableModel` to the first one that changed. Cheap: the tree API
    /// returns only file metadata (path + content hash), never the files.
    func checkForUpdates() async {
        for model in ModelRegistry.shared where isDownloaded(model) {
            guard let variant = model.whisperKitID else { continue }
            guard let remote = await Self.remoteFingerprint(variant: variant) else { continue }
            if let stored = Self.storedFingerprint(model.id) {
                if stored != remote {
                    updatableModel = model
                    return
                }
            } else {
                // Downloaded before this feature existed — baseline it now so a
                // future change is detected (we can't retro-detect past changes).
                Self.storeFingerprint(remote, for: model.id)
            }
        }
        updatableModel = nil
    }

    /// A fingerprint of a variant's files upstream: sorted "path:contentHash"
    /// pairs. Changes iff any model file's content changes.
    static func remoteFingerprint(variant: String) async -> String? {
        let encoded = variant.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? variant
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main/\(encoded)?recursive=true"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var parts: [String] = []
        for entry in entries {
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String else { continue }
            let oid: String
            if let lfs = entry["lfs"] as? [String: Any], let o = lfs["oid"] as? String {
                oid = o
            } else if let o = entry["oid"] as? String {
                oid = o
            } else {
                continue
            }
            parts.append("\(path):\(oid)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.sorted().joined(separator: "|")
    }

    private static func fingerprintKey(_ id: String) -> String { "modelFingerprint.\(id)" }
    private static func storedFingerprint(_ id: String) -> String? {
        UserDefaults.standard.string(forKey: fingerprintKey(id))
    }
    private static func storeFingerprint(_ fp: String, for id: String) {
        UserDefaults.standard.set(fp, forKey: fingerprintKey(id))
    }
}
