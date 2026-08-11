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

            Section("Overlay symbols") {
                Text("Pick an emoji or SF Symbol shown for each stage of the recording overlay. For emoji, type or paste one, or press ⌃⌘Space for the macOS emoji picker.")
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

                Picker("Size", selection: $settings.glyphSize) {
                    ForEach(GlyphSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .onChange(of: settings.glyphSize) { _, _ in pushStyle() }

                ColorPicker(selection: symbolColorBinding, supportsOpacity: true) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SF Symbol color")
                        Text("Emoji keep their own colors.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Preview in overlay") { engine.previewGlyphs() }
                        .disabled(!settings.showOverlay)
                    Spacer()
                    Button("Reset to defaults") {
                        settings.listeningGlyph = .defaultListening
                        settings.processingGlyph = .defaultProcessing
                        settings.doneGlyph = .defaultDone
                        settings.glyphSize = .medium
                        settings.symbolColor = .defaultSymbol
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
                    Text("Beta. Effectively removes filler words (um, uh, false starts) and fixes punctuation; can also format spoken lists and emails. Runs Apple's on-device model after transcription, so nothing leaves your Mac, but it uses noticeably more processing and adds a moment before text appears. When the Neural Engine is busy it can take longer.")
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
        .navigationTitle("Settings")
    }

    private func pushGlyphs() {
        engine.setGlyphs(
            listening: settings.listeningGlyph,
            processing: settings.processingGlyph,
            done: settings.doneGlyph
        )
    }

    private func pushStyle() {
        engine.setGlyphStyle(size: settings.glyphSize.points, symbolColor: settings.symbolColor.color)
    }

    // Bridge the persisted RGBAColor to ColorPicker's Color, pushing live updates.
    private var symbolColorBinding: Binding<Color> {
        Binding(
            get: { settings.symbolColor.color },
            set: { settings.symbolColor = RGBAColor($0); pushStyle() }
        )
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
                if glyph.kind == .emoji {
                    TextField("Emoji", text: valueBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)

                    ForEach(emojiSuggestions, id: \.self) { e in
                        Button(e) { glyph = Glyph(kind: .emoji, value: e) }
                            .buttonStyle(.plain)
                            .font(.system(size: 20))
                    }
                    Spacer(minLength: 0)
                } else {
                    TextField("SF Symbol name", text: valueBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Menu {
                        ForEach(symbolSuggestions, id: \.self) { s in
                            Button { glyph = Glyph(kind: .symbol, value: s) } label: {
                                Label(s, systemImage: s)
                            }
                        }
                    } label: {
                        Label("Suggestions", systemImage: "sparkles")
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .padding(.leading, entryIndent)
        }
        .padding(.vertical, 4)
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
