import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var settings: Settings

    @State private var checks: [Check] = DoctorReport.run()

    var body: some View {
        Form {
            Section {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    row(check)
                }
            } header: {
                Text("Parrot needs these to work")
            } footer: {
                Text("Grant Accessibility and Microphone access, and set the 🌐 key to “Do Nothing” so Fn is a clean push-to-talk key. macOS may require you to quit and reopen Parrot after granting Accessibility.")
                    .font(.caption)
            }

            Section {
                Button("Re-check") { refresh() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func row(_ check: Check) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon(for: check.status)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.name.capitalized).fontWeight(.medium)
                if let detail = statusDetail(check.status) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let remediation = check.remediation {
                    Text(remediation).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButton(for: check)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func actionButton(for check: Check) -> some View {
        if case .ok = check.status {
            EmptyView()
        } else {
            switch check.name {
            case "microphone":
                Button("Grant") { requestMicrophone() }
            case "accessibility":
                Button("Open Settings") { openAccessibilitySettings() }
            case "fn key mapping":
                Button("Open Keyboard") { openKeyboardSettings() }
            default:
                EmptyView()
            }
        }
    }

    private func icon(for status: CheckStatus) -> some View {
        switch status {
        case .ok:
            return Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            return Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .fail:
            return Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func statusDetail(_ status: CheckStatus) -> String? {
        switch status {
        case .ok: return "Granted"
        case .warn(let msg), .fail(let msg): return msg
        }
    }

    // MARK: - Actions

    private func refresh() {
        checks = DoctorReport.run()
        // If accessibility just came through, bring the hotkey tap up.
        if !engine.hotkeyActive {
            engine.startHotkey()
        }
        if DoctorReport.allOK(checks) {
            settings.hasCompletedOnboarding = true
        }
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    private func openAccessibilitySettings() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
