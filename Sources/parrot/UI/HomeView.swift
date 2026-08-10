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
                testArea
                recentsHeader
            }
            .padding(20)
            .padding(.bottom, 0)

            recentsList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { checks = DoctorReport.run() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(accent)
                .symbolEffect(.pulse, isActive: isActive)
                .frame(width: 30)
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

    private var isActive: Bool {
        switch engine.status {
        case .recording, .transcribing, .loading: return true
        default: return false
        }
    }

    private var accent: Color {
        switch engine.status {
        case .recording: return .red
        case .transcribing, .loading: return .orange
        case .error: return .red
        case .idle: return .accentColor
        }
    }

    private var symbol: String {
        switch engine.status {
        case .recording: return "waveform"
        case .transcribing: return "ellipsis"
        case .loading: return "arrow.down.circle"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "mic.fill"
        }
    }

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
