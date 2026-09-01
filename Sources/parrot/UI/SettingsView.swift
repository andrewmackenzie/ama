import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: DictationEngine
    @EnvironmentObject var history: History
    @EnvironmentObject var updateChecker: UpdateChecker

    @State private var loginItemNote: String?
    @State private var checks: [Check] = DoctorReport.run()

    var body: some View {
        Form {
            Section {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    permissionRow(check)
                }
                Button("Re-check") { refreshPermissions() }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Grant Accessibility and Microphone access, and set the 🌐 key to “Do Nothing” so Fn is a clean push-to-talk key. macOS may require you to quit and reopen Ama after granting Accessibility.")
                    .font(.caption)
            }

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

                Toggle("Show transcription progress", isOn: $settings.showTranscriptionProgress)

                Toggle("Double-tap to lock (hands-free)", isOn: $settings.doubleTapLock)
                    .onChange(of: settings.doubleTapLock) { _, newValue in
                        engine.setDoubleTapLock(newValue)
                    }
                Text("Double-tap the key to keep dictating without holding it; press once to stop. Turn off for instant push-to-talk on very short taps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Overlay symbols") {
                Text("Choose what the recording overlay shows for each stage. Emoji uses 👂 🤔 👍; SF Symbols uses tinted glyphs. Open Advanced to customize each stage, the size, and the pill.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Style", selection: overlayPresetBinding) {
                    ForEach(OverlayPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Pick an emoji or SF Symbol for each stage. For emoji, type or paste one, or press ⌃⌘Space for the macOS emoji picker.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        GlyphRow(title: "Listening", glyph: $settings.listeningGlyph,
                                 symbolColor: settings.symbolColor.color,
                                 emojiSuggestions: GlyphSuggestions.listeningEmoji,
                                 symbolSuggestions: GlyphSuggestions.listeningSymbols)
                            .onChange(of: settings.listeningGlyph) { _, _ in pushGlyphs() }
                        GlyphRow(title: "Processing", glyph: $settings.processingGlyph,
                                 symbolColor: settings.symbolColor.color,
                                 emojiSuggestions: GlyphSuggestions.processingEmoji,
                                 symbolSuggestions: GlyphSuggestions.processingSymbols)
                            .onChange(of: settings.processingGlyph) { _, _ in pushGlyphs() }
                        GlyphRow(title: "Done", glyph: $settings.doneGlyph,
                                 symbolColor: settings.symbolColor.color,
                                 emojiSuggestions: GlyphSuggestions.doneEmoji,
                                 symbolSuggestions: GlyphSuggestions.doneSymbols)
                            .onChange(of: settings.doneGlyph) { _, _ in pushGlyphs() }

                        SliderRow(title: "Glyph size", value: $settings.glyphPointSize,
                                  range: Double(GlyphSize.minPoints)...Double(GlyphSize.maxPoints))
                            .onChange(of: settings.glyphPointSize) { _, _ in pushStyle() }
                        SliderRow(title: "Pill size", value: $settings.pillPadding, range: 8...72)
                            .onChange(of: settings.pillPadding) { _, _ in pushStyle() }

                        ColorPicker(selection: symbolColorBinding, supportsOpacity: true) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("SF Symbol color")
                                Text("Emoji keep their own colors.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ColorPicker(selection: pillColorBinding, supportsOpacity: true) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Pill color")
                                Text("The rounded background behind the glyph. Lower the opacity for a see-through pill.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout.weight(.semibold))

                HStack {
                    Button("Preview in overlay") { engine.previewGlyphs() }
                        .disabled(!settings.showOverlay)
                    Spacer()
                    Button("Reset to defaults") {
                        settings.overlayPreset = .symbol
                        settings.listeningGlyph = .defaultListening
                        settings.processingGlyph = .defaultProcessing
                        settings.doneGlyph = .defaultDone
                        settings.glyphPointSize = Double(GlyphSize.medium)
                        settings.symbolColor = .defaultSymbol
                        settings.pillColor = .defaultPill
                        settings.pillPadding = 28
                        pushGlyphs()
                        pushStyle()
                    }
                    .buttonStyle(.link)
                }
                if !settings.showOverlay {
                    Text("The overlay is off — turn on “Show recording overlay” above to see these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Section("Software Update") {
                Button("Check for Updates") {
                    Task { await updateChecker.check() }
                }
                .disabled(updateChecker.isChecking)

                updateStatus
            }

            Section("Text cleanup") {
                Toggle(isOn: $settings.cleanupEnabled) {
                    HStack(spacing: 6) {
                        Text("Clean up dictated text (on-device AI)")
                        Text("BETA")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
                .onChange(of: settings.cleanupEnabled) { _, newValue in
                    engine.setCleanup(newValue)
                }
                .disabled(!TextCleaner.isSupported)

                if let reason = TextCleaner.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Beta. Removes filler words (um, uh, false starts), applies spoken self-corrections, and fixes punctuation. Runs Apple's on-device model after transcription, so nothing leaves your Mac, but it uses noticeably more processing and adds a moment before text appears. When the Neural Engine is busy it can take longer.")
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

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Word corrections")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Button("Reset to default") {
                                settings.cleanupCorrections = TextCleaner.defaultCorrections
                                engine.setCleanupCorrections(TextCleaner.defaultCorrections)
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                        TextEditor(text: $settings.cleanupCorrections)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                            .onChange(of: settings.cleanupCorrections) { _, newValue in
                                engine.setCleanupCorrections(newValue)
                            }
                        Text("Fix proper nouns the transcriber mishears. One rule per line: `Correct = misheard, variants`. Applied exactly (not by the model), so it's reliable. Whole-word and case-insensitive. Skip everyday homophones like \"cloud\" — a blind swap would break normal use.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Advanced: cleanup system prompt") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("This is the exact instruction sent to the on-device model — the core rules and examples that keep it cleaning text instead of replying to it. Edit only if you understand prompt design; a bad prompt can make cleanup add words, chat back, or fail. Use Reset if it misbehaves.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $settings.cleanupSystemPrompt)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 180)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                                .onChange(of: settings.cleanupSystemPrompt) { _, newValue in
                                    engine.setCleanupSystemPrompt(newValue)
                                }
                            HStack {
                                Spacer()
                                Button("Reset to default") {
                                    settings.cleanupSystemPrompt = TextCleaner.defaultSystemPrompt
                                    engine.setCleanupSystemPrompt(TextCleaner.defaultSystemPrompt)
                                }
                                .font(.caption)
                                .buttonStyle(.link)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout.weight(.semibold))
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
        .navigationTitle("Ama Settings")
        .onAppear(perform: refreshPermissions)
        // Re-run the checks when the app regains focus (e.g. returning from System
        // Settings after granting) so the rows update without needing "Re-check".
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checks = DoctorReport.run()
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private func permissionRow(_ check: Check) -> some View {
        HStack(alignment: .top, spacing: 12) {
            permissionIcon(for: check.status)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.name.capitalized).fontWeight(.medium)
                if let detail = permissionDetail(check.status) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if let remediation = check.remediation {
                    Text(remediation).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            permissionActionButton(for: check)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func permissionActionButton(for check: Check) -> some View {
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

    private func permissionIcon(for status: CheckStatus) -> some View {
        switch status {
        case .ok:
            return Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            return Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .fail:
            return Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func permissionDetail(_ status: CheckStatus) -> String? {
        switch status {
        case .ok: return "Granted"
        case .warn(let msg), .fail(let msg): return msg
        }
    }

    private func refreshPermissions() {
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
            DispatchQueue.main.async { refreshPermissions() }
        }
    }

    private func openAccessibilitySettings() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openKeyboardSettings() {
        openURL("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The result line beneath "Check for Updates". Driven by `lastOutcome`, so
    /// the twice-daily background check refreshes it for free — same instance.
    @ViewBuilder
    private var updateStatus: some View {
        if updateChecker.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch updateChecker.lastOutcome {
            case nil:
                Text("Ama \(updateChecker.currentShortVersion).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .upToDate(let version):
                Text("Ama \(version) is the latest version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .updateAvailable(let update):
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ama \(update.shortVersion) is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(updateChecker.isDownloading ? "Downloading…" : "Download and install") {
                        updateChecker.downloadAndOpen()
                    }
                    .buttonStyle(.link)
                    .disabled(updateChecker.isDownloading)
                }
            case .failed:
                Text("Couldn't check for updates. Check your connection and try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pushGlyphs() {
        engine.setGlyphs(
            listening: settings.listeningGlyph,
            processing: settings.processingGlyph,
            done: settings.doneGlyph
        )
    }

    private func pushStyle() {
        engine.setGlyphStyle(
            size: CGFloat(settings.glyphPointSize),
            symbolColor: settings.symbolColor.color,
            pillColor: settings.pillColor.color,
            pillPadding: CGFloat(settings.pillPadding)
        )
    }

    // Selecting a preset stamps all three stage glyphs; Advanced can then override.
    private var overlayPresetBinding: Binding<OverlayPreset> {
        Binding(
            get: { settings.overlayPreset },
            set: { preset in
                settings.overlayPreset = preset
                settings.listeningGlyph = preset.listening
                settings.processingGlyph = preset.processing
                settings.doneGlyph = preset.done
                pushGlyphs()
            }
        )
    }

    // Bridge the persisted RGBAColors to ColorPicker's Color, pushing live updates.
    private var symbolColorBinding: Binding<Color> {
        Binding(
            get: { settings.symbolColor.color },
            set: { settings.symbolColor = RGBAColor($0); pushStyle() }
        )
    }

    private var pillColorBinding: Binding<Color> {
        Binding(
            get: { settings.pillColor.color },
            set: { settings.pillColor = RGBAColor($0); pushStyle() }
        )
    }
}

/// A labeled slider with a live point-value readout, used for glyph and pill size.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Text("\(Int(value.rounded())) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

/// One editable stage row: preview + emoji/SF-Symbol toggle + entry + suggestions.
private struct GlyphRow: View {
    let title: String
    @Binding var glyph: Glyph
    let symbolColor: Color
    let emojiSuggestions: [String]
    let symbolSuggestions: [String]

    // Indent the entry line so it sits under the title, clear of the preview.
    private let entryIndent: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GlyphView(glyph: glyph, size: 22, symbolColor: symbolColor)
                    .frame(width: entryIndent - 10, height: 24)
                Text(title)
                    .fontWeight(.medium)
                Spacer(minLength: 12)
                Picker("", selection: kindBinding) {
                    Text("Emoji").tag(Glyph.Kind.emoji)
                    Text("SF Symbol").tag(Glyph.Kind.symbol)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 8) {
                // Empty title + labelsHidden so the Form doesn't attach a label
                // that bumps the field onto its own row; the hint lives in the
                // prompt instead, keeping the field in line with the chips.
                TextField("", text: valueBinding, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: glyph.kind == .emoji ? 84 : 210)

                Spacer(minLength: 8)

                // Tappable quick-picks, right-aligned. Identical layout for emoji
                // and SF Symbols: a row of the glyphs themselves. SF Symbols hover
                // to reveal their name since it isn't spelled out.
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        glyph = Glyph(kind: glyph.kind, value: s)
                    } label: {
                        GlyphView(glyph: Glyph(kind: glyph.kind, value: s), size: 20, symbolColor: .primary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(glyph.kind == .symbol ? s : "")
                }
            }
            .padding(.leading, entryIndent)
        }
        .padding(.vertical, 4)
    }

    private var placeholder: String { glyph.kind == .emoji ? "Emoji" : "SF Symbol name" }

    private var suggestions: [String] {
        glyph.kind == .emoji ? emojiSuggestions : symbolSuggestions
    }

    private var kindBinding: Binding<Glyph.Kind> {
        Binding(
            get: { glyph.kind },
            set: { newKind in
                guard newKind != glyph.kind else { return }
                // Seed a valid value for the new kind rather than reinterpreting
                // an emoji as a symbol name (or vice versa).
                let seed = newKind == .emoji
                    ? (emojiSuggestions.first ?? "👂")
                    : (symbolSuggestions.first ?? "ear.fill")
                glyph = Glyph(kind: newKind, value: seed)
            }
        )
    }

    private var valueBinding: Binding<String> {
        Binding(
            get: { glyph.value },
            set: { glyph = Glyph(kind: glyph.kind, value: $0) }
        )
    }
}

/// Curated starting points for each stage.
enum GlyphSuggestions {
    static let listeningEmoji = ["👂", "🎙️", "👀", "🦻", "🗣️"]
    static let processingEmoji = ["🤔", "⏳", "🧠", "💭", "⚙️"]
    static let doneEmoji = ["👍", "✅", "✨", "🎉", "👌"]

    static let listeningSymbols = ["microphone.and.signal.meter.fill", "waveform", "mic.fill", "ear.fill", "dot.radiowaves.left.and.right"]
    static let processingSymbols = ["progress.indicator", "brain", "hourglass", "ellipsis", "sparkles", "wand.and.stars"]
    static let doneSymbols = ["checkmark", "checkmark.circle.fill", "checkmark.seal.fill", "hand.thumbsup.fill"]
}
