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

                Toggle("Double-tap to lock (hands-free)", isOn: $settings.doubleTapLock)
                    .onChange(of: settings.doubleTapLock) { _, newValue in
                        engine.setDoubleTapLock(newValue)
                    }
                Text("Double-tap the key to keep dictating without holding it; press once to stop. Turn off for instant push-to-talk on very short taps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Text cleanup") {
                Toggle("Clean up dictated text (AI)", isOn: $settings.cleanupEnabled)
                    .onChange(of: settings.cleanupEnabled) { _, newValue in
                        engine.setCleanup(newValue)
                    }
                    .disabled(!TextCleaner.isSupported)

                if let reason = TextCleaner.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Runs Apple's on-device model after transcription: removes filler, fixes punctuation, formats spoken lists, and applies self-corrections. Nothing leaves your Mac. Adds about a second.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.cleanupEnabled, TextCleaner.isSupported {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Writing style")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("Reset to default") {
                                settings.writingStyle = TextCleaner.defaultProfile
                                engine.setWritingStyle(TextCleaner.defaultProfile)
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                        TextEditor(text: $settings.writingStyle)
                            .font(.system(.callout, design: .default))
                            .frame(minHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            .onChange(of: settings.writingStyle) { _, newValue in
                                engine.setWritingStyle(newValue)
                            }
                        Text("How Ama should format your text (tone, lists, email greeting/sign-off). Seeded from your preferences; edit freely.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
