import Foundation

/// A single dictated transcript.
struct Transcript: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date

    init(id: UUID = UUID(), text: String, date: Date) {
        self.id = id
        self.text = text
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

    func add(_ text: String, date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(Transcript(text: trimmed, date: date), at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
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
