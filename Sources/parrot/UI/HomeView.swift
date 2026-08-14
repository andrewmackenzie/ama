import AppKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var history: History

    @State private var testText = ""
    @State private var checks: [Check] = DoctorReport.run()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if !DoctorReport.allOK(checks) { permissionBanner }
                if let info = engine.progressInfo { progressPanel(info) }
                testArea
                recentsHeader
            }
            .padding(20)
            .padding(.bottom, 0)

            recentsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { checks = DoctorReport.run() }
        // Re-run the permission checks when the app regains focus (e.g. returning
        // from System Settings after granting) or once the hotkey tap goes live,
        // so the banner clears without needing a relaunch.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checks = DoctorReport.run()
        }
        .onChange(of: engine.hotkeyActive) { _, _ in checks = DoctorReport.run() }
        .onChange(of: engine.status) { _, _ in checks = DoctorReport.run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text(subheadline).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(engine.currentModelID)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // The app's brand mark (the ink-and-gold "a"), matching the Dock icon.
    // The current state is conveyed by the headline/subheadline text.
    private var statusIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 42, height: 42)
    }

    // MARK: - Permission banner

    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ama needs permissions to work").fontWeight(.semibold)
                Text("Grant Accessibility and Microphone access to start dictating.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                NotificationCenter.default.post(name: .amaOpenPreferences, object: "permissions")
            }
        }
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.35)))
    }

    // MARK: - Test area

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try it here")
                .font(.subheadline.weight(.semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $testText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 86)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                if testText.isEmpty {
                    // Match the TextEditor's text origin: 8pt outer padding + the
                    // NSTextView's ~5pt line-fragment padding on the leading edge.
                    Text("Click here, then hold \(settings.hotkey.shortName) and speak to test dictation — nothing leaves your Mac.")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 13)
                        .padding(.trailing, 13)
                        .allowsHitTesting(false)
                }
            }
            if !testText.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear") { testText = "" }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    // MARK: - Transcription progress panel

    // Every field WhisperKit exposes during (and after) a transcription. Kept
    // deliberately dense so real dictation lengths can be judged against it.
    private func progressPanel(_ info: TranscriptionProgressInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Transcription progress").font(.subheadline.weight(.semibold))
                Text(info.isFinal ? "FINAL" : "LIVE")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((info.isFinal ? Color.green : Color.orange).opacity(0.2)))
                    .foregroundStyle(info.isFinal ? Color.green : Color.orange)
                Spacer()
                Text("\(Int((min(max(info.fractionCompleted, 0), 1)) * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            ProgressView(value: min(max(info.fractionCompleted, 0), 1))

            Text(info.totalSeconds > 0
                 ? String(format: "%.0fs / %.0fs audio seeked · updates per 30s window",
                          info.completedSeconds, info.totalSeconds)
                 : "audio seek: n/a")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                metric("Window", "\(info.windowId)")
                metric("Tokens", "\(info.tokenCount)")
                metric("Elapsed", String(format: "%.2fs", info.elapsed))
                metric("Temperature", fmtF(info.temperature))
                metric("Avg logprob", fmtF(info.avgLogprob))
                metric("Compression", fmtF(info.compressionRatio))
                if info.isFinal {
                    metric("Tokens/sec", fmtD(info.tokensPerSecond))
                    metric("Real-time ×", fmtD(info.realTimeFactor))
                    metric("Pipeline", fmtSecs(info.fullPipelineSeconds))
                    metric("Input audio", fmtSecs(info.inputAudioSeconds))
                    metric("Decode loops", fmtInt(info.totalDecodingLoops))
                }
            }

            if !info.text.isEmpty {
                Text(info.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func fmtF(_ v: Float?) -> String { v.map { String(format: "%.3f", $0) } ?? "—" }
    private func fmtD(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    private func fmtSecs(_ v: Double?) -> String { v.map { String(format: "%.2fs", $0) } ?? "—" }
    private func fmtInt(_ v: Double?) -> String { v.map { String(Int($0)) } ?? "—" }

    // MARK: - Recents

    private var recentsHeader: some View {
        HStack {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if !history.items.isEmpty {
                Button("Clear All") { history.clear() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }

    @ViewBuilder
    private var recentsList: some View {
        if history.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("Your dictations will show up here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 40)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(history.items.prefix(20)) { item in
                        RecentCard(item: item) { history.remove(item.id) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Status mapping

    private var headline: String {
        if engine.isLocked { return "Listening (hands-free)" }
        switch engine.status {
        case .idle: return "Ready to dictate"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .loading: return "Loading model…"
        case .error: return "Needs attention"
        }
    }

    private var subheadline: String {
        if engine.isLocked {
            return "Press \(settings.hotkey.shortName) once to stop and insert."
        }
        switch engine.status {
        case .error(let message): return message
        case .loading: return "Preparing \(engine.currentModelID)…"
        default:
            let lockHint = settings.doubleTapLock ? " · double-tap for hands-free" : ""
            return "Hold \(settings.hotkey.shortName) and speak\(lockHint)"
        }
    }
}

// MARK: - Recent card

private struct RecentCard: View {
    let item: Transcript
    let onDelete: () -> Void
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    copy(item.text)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { didCopy = false }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(didCopy ? Color.green : .secondary)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Copy")
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .help("Delete")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if let raw = item.raw {
                // Cleanup ran: show what Whisper heard, then the cleaned result.
                labeled("Heard", raw, emphasized: false)
                labeled("Cleaned", item.text, emphasized: true)
            } else {
                Text(item.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private func labeled(_ label: String, _ value: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
                .foregroundStyle(emphasized ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
