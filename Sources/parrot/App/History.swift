import Foundation

/// A single dictated transcript.
struct Transcript: Codable, Identifiable, Equatable {
    let id: UUID
    /// The final text that was inserted (cleaned, if cleanup ran).
    let text: String
    /// The raw Whisper output before cleanup. `nil` when there was no cleanup
    /// (or on legacy items), i.e. when it would equal `text`.
    let raw: String?
    let date: Date

    init(id: UUID = UUID(), text: String, raw: String? = nil, date: Date) {
        self.id = id
        self.text = text
        self.raw = raw
        self.date = date
    }
}

/// Rolling log of past transcripts, persisted as JSON under Application Support.
/// Newest first. Writes are best-effort; a failure to persist never blocks
/// dictation.
@MainActor
final class History: ObservableObject {
    @Published private(set) var items: [Transcript] = []

    private let fileURL: URL
    private var limit: Int

    init(fileURL: URL = AppPaths.historyFile, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = limit
        load()
    }

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        if items.count > limit {
            items = Array(items.prefix(limit))
            persist()
        }
    }

    func add(_ text: String, raw: String? = nil, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Only keep the raw output when it actually differs from the final text
        // (i.e. cleanup changed something worth showing).
        let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawToStore = (trimmedRaw?.isEmpty == false && trimmedRaw != trimmed) ? trimmedRaw : nil
        items.insert(Transcript(text: trimmed, raw: rawToStore, date: date), at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([Transcript].self, from: data) {
            items = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
