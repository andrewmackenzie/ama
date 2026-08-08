import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var models: ModelManager

    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(ModelRegistry.shared, id: \.id) { model in
                    row(model)
                }
            } header: {
                Text("Transcription models")
            } footer: {
                Text("Models run fully on-device on the Apple Neural Engine. Larger models are more accurate but slower to download and load.")
                    .font(.caption)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        // Re-check on-disk presence after a download finishes.
        .id(models.revision)
    }

    @ViewBuilder
    private func row(_ model: TranscriptionModel) -> some View {
        let isSelected = settings.modelID == model.id
        let isDownloaded = models.isDownloaded(model)
        let isDownloading = models.downloadingID == model.id

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName).fontWeight(.medium)
                    if isSelected {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text("\(model.sizeMB) MB · \(model.languages.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.blurb.isEmpty {
                    Text(model.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if isDownloading {
                ProgressView(value: models.progress)
                    .frame(width: 90)
            } else if isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Use") { select(model) }
                }
            } else {
                Button("Download") { download(model) }
            }
        }
        .padding(.vertical, 2)
    }

    private func select(_ model: TranscriptionModel) {
        settings.modelID = model.id
        engine.reload(model: model)
    }

    private func download(_ model: TranscriptionModel) {
        errorMessage = nil
        Task {
            do {
                try await models.download(model)
            } catch {
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
