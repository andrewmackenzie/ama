import SwiftUI

struct HomeView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var history: History

    var body: some View {
        VStack(spacing: 28) {
            statusBadge

            VStack(spacing: 6) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                Text(subheadline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !history.items.isEmpty {
                recent
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Status

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.15))
                .frame(width: 120, height: 120)
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(accent)
                .symbolEffect(.pulse, isActive: isActive)
        }
        .padding(.top, 24)
    }

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
        switch engine.status {
        case .idle: return "Ready to dictate"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .loading: return "Loading model…"
        case .error: return "Needs attention"
        }
    }

    private var subheadline: String {
        switch engine.status {
        case .error(let message): return message
        case .loading: return "Preparing \(engine.currentModelID). First run downloads the model."
        default:
            return "Click into any text field, then hold \(settings.hotkey.shortName) and speak.\nModel: \(engine.currentModelID)"
        }
    }

    // MARK: - Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(history.items.prefix(3)) { item in
                Text(item.text)
                    .lineLimit(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: 420)
    }
}
