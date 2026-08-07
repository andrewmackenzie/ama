import SwiftUI

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (build \(build))"
    }

    private var thirdParty: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Third-party license file not found in this build.\nRun `make app` to generate it."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ama").font(.title.weight(.semibold))
                    Text("Version \(version)").font(.callout).foregroundStyle(.secondary)
                    Text("On-device push-to-talk dictation.").font(.callout).foregroundStyle(.secondary)
                }
            }

            Text("“Ama” is short for amanuensis — one who writes down what another dictates. Hold the key, speak, and Ama transcribes it on-device and types it at your cursor.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("© 2026 Capstan Networks LLC · MIT licensed. Built on the open-source parrot by Andrew Jones. Transcription by WhisperKit on the Apple Neural Engine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Acknowledgements & third-party licenses")
                .font(.headline)

            ScrollView {
                Text(thirdParty)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("About")
    }
}
