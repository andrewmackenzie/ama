import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var history: History

    @State private var loginItemNote: String?

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Push-to-talk key", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                .onChange(of: settings.hotkey) { _, newValue in
                    engine.setHotkey(newValue)
                }

                Toggle("Show recording overlay", isOn: $settings.showOverlay)
                    .onChange(of: settings.showOverlay) { _, newValue in
                        engine.setOverlayEnabled(newValue)
                    }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, newValue in
                        if !LoginItem.set(newValue) {
                            loginItemNote = "Couldn't update login item. Run Ama from /Applications and try again."
                        } else {
                            loginItemNote = nil
                        }
                    }
                if let loginItemNote {
                    Text(loginItemNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("History") {
                Toggle("Keep a history of transcripts", isOn: $settings.keepHistory)
                    .onChange(of: settings.keepHistory) { _, newValue in
                        engine.setHistory(newValue ? history : nil)
                    }
                Stepper(value: $settings.historyLimit, in: 20...2000, step: 20) {
                    Text("Keep the most recent \(settings.historyLimit)")
                }
                .onChange(of: settings.historyLimit) { _, newValue in
                    history.setLimit(newValue)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
