import AppKit
import Foundation
import SwiftUI

/// A color persisted as "r,g,b,a" sRGB components (0…1) so it round-trips
/// through `UserDefaults`. Used for the SF Symbol tint (emoji keep their own
/// colors). Carries an alpha channel so the overlay symbol can be translucent.
struct RGBAColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var storage: String { "\(red),\(green),\(blue),\(alpha)" }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init?(storage: String) {
        let p = storage.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        self.init(red: p[0], green: p[1], blue: p[2], alpha: p[3])
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                  blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
    }

    // A mid blue that reads on both light and dark wallpapers by default.
    static let defaultSymbol = RGBAColor(red: 0.36, green: 0.55, blue: 1.0, alpha: 1.0)
    // The pill behind the glyph: black at 75% opacity, reads on any wallpaper.
    static let defaultPill = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.75)
}

/// Overlay glyph size, applied to both emoji and SF Symbols. Retained for the
/// default (M) and the slider's bounds; the size itself is now a continuous
/// point value stored in `Settings.glyphPointSize`.
enum GlyphSize {
    static let small: CGFloat = 32
    static let medium: CGFloat = 44
    static let large: CGFloat = 58
    static let minPoints: CGFloat = 24
    static let maxPoints: CGFloat = 76
}

/// One overlay symbol: either an emoji or a named SF Symbol. Persisted as a
/// prefixed string ("emoji:👂" / "symbol:ear.fill") so it round-trips through
/// `UserDefaults` as a single value.
struct Glyph: Equatable {
    enum Kind: String { case emoji, symbol }
    var kind: Kind
    var value: String

    var storage: String { "\(kind.rawValue):\(value)" }

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    init?(storage: String) {
        guard let sep = storage.firstIndex(of: ":") else { return nil }
        let k = String(storage[storage.startIndex..<sep])
        let v = String(storage[storage.index(after: sep)...])
        guard let kind = Kind(rawValue: k), !v.isEmpty else { return nil }
        self.kind = kind
        self.value = v
    }

    static let defaultListening = Glyph(kind: .symbol, value: "microphone.and.signal.meter.fill")
    static let defaultProcessing = Glyph(kind: .symbol, value: "progress.indicator")
    static let defaultDone = Glyph(kind: .symbol, value: "checkmark.circle.fill")
}

/// The two starting points offered at the top of Overlay settings. Picking one
/// stamps all three stage glyphs at once; Advanced then lets you override any of
/// them individually.
enum OverlayPreset: String, CaseIterable, Identifiable {
    case symbol, emoji
    var id: String { rawValue }
    var label: String { self == .emoji ? "Emoji" : "SF Symbols" }

    var listening: Glyph { self == .emoji ? Glyph(kind: .emoji, value: "👂") : .defaultListening }
    var processing: Glyph { self == .emoji ? Glyph(kind: .emoji, value: "🤔") : .defaultProcessing }
    var done: Glyph { self == .emoji ? Glyph(kind: .emoji, value: "👍") : .defaultDone }
}

/// User preferences, persisted to `UserDefaults`. Single source of truth for
/// the GUI; the CLI `run` command can still override individual values via
/// flags at launch.
@MainActor
final class Settings: ObservableObject {
    private let defaults: UserDefaults

    nonisolated static let suiteName = "com.capstannetworks.ama"

    private enum Key {
        static let hotkey = "hotkey"
        static let doubleTapLock = "doubleTapLock"
        static let showOverlay = "showOverlay"
        static let launchAtLogin = "launchAtLogin"
        static let keepHistory = "keepHistory"
        static let historyLimit = "historyLimit"
        static let cleanupEnabled = "cleanupEnabled"
        static let writingStyle = "writingStyle"
        static let cleanupSystemPrompt = "cleanupSystemPrompt"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let overlayPreset = "overlayPreset"
        static let listeningGlyph = "listeningGlyph"
        static let processingGlyph = "processingGlyph"
        static let doneGlyph = "doneGlyph"
        static let glyphPointSize = "glyphPointSize"
        static let symbolColor = "symbolColor"
        static let pillColor = "pillColor"
        static let pillPadding = "pillPadding"
    }

    init(defaults: UserDefaults = UserDefaults(suiteName: Settings.suiteName) ?? .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hotkey: Hotkey.fn.rawValue,
            Key.doubleTapLock: true,
            Key.showOverlay: true,
            Key.launchAtLogin: false,
            Key.keepHistory: true,
            Key.historyLimit: 200,
            Key.cleanupEnabled: false,
            Key.writingStyle: TextCleaner.defaultProfile,
            Key.cleanupSystemPrompt: TextCleaner.defaultSystemPrompt,
            Key.hasCompletedOnboarding: false,
            Key.overlayPreset: OverlayPreset.symbol.rawValue,
            Key.listeningGlyph: Glyph.defaultListening.storage,
            Key.processingGlyph: Glyph.defaultProcessing.storage,
            Key.doneGlyph: Glyph.defaultDone.storage,
            Key.glyphPointSize: Double(GlyphSize.medium),
            Key.symbolColor: RGBAColor.defaultSymbol.storage,
            Key.pillColor: RGBAColor.defaultPill.storage,
            Key.pillPadding: Double(28),
        ])
    }

    var hotkey: Hotkey {
        get { Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .fn }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.hotkey) }
    }

    var doubleTapLock: Bool {
        get { defaults.bool(forKey: Key.doubleTapLock) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.doubleTapLock) }
    }

    var showOverlay: Bool {
        get { defaults.bool(forKey: Key.showOverlay) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.showOverlay) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var keepHistory: Bool {
        get { defaults.bool(forKey: Key.keepHistory) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.keepHistory) }
    }

    var historyLimit: Int {
        get { defaults.integer(forKey: Key.historyLimit) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.historyLimit) }
    }

    var cleanupEnabled: Bool {
        get { defaults.bool(forKey: Key.cleanupEnabled) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.cleanupEnabled) }
    }

    var writingStyle: String {
        get { defaults.string(forKey: Key.writingStyle) ?? TextCleaner.defaultProfile }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.writingStyle) }
    }

    var cleanupSystemPrompt: String {
        get { defaults.string(forKey: Key.cleanupSystemPrompt) ?? TextCleaner.defaultSystemPrompt }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.cleanupSystemPrompt) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    var listeningGlyph: Glyph {
        get { Glyph(storage: defaults.string(forKey: Key.listeningGlyph) ?? "") ?? .defaultListening }
        set { objectWillChange.send(); defaults.set(newValue.storage, forKey: Key.listeningGlyph) }
    }

    var processingGlyph: Glyph {
        get { Glyph(storage: defaults.string(forKey: Key.processingGlyph) ?? "") ?? .defaultProcessing }
        set { objectWillChange.send(); defaults.set(newValue.storage, forKey: Key.processingGlyph) }
    }

    var doneGlyph: Glyph {
        get { Glyph(storage: defaults.string(forKey: Key.doneGlyph) ?? "") ?? .defaultDone }
        set { objectWillChange.send(); defaults.set(newValue.storage, forKey: Key.doneGlyph) }
    }

    var overlayPreset: OverlayPreset {
        get { OverlayPreset(rawValue: defaults.string(forKey: Key.overlayPreset) ?? "") ?? .symbol }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.overlayPreset) }
    }

    var glyphPointSize: Double {
        get { let v = defaults.double(forKey: Key.glyphPointSize); return v > 0 ? v : Double(GlyphSize.medium) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.glyphPointSize) }
    }

    var symbolColor: RGBAColor {
        get { RGBAColor(storage: defaults.string(forKey: Key.symbolColor) ?? "") ?? .defaultSymbol }
        set { objectWillChange.send(); defaults.set(newValue.storage, forKey: Key.symbolColor) }
    }

    var pillColor: RGBAColor {
        get { RGBAColor(storage: defaults.string(forKey: Key.pillColor) ?? "") ?? .defaultPill }
        set { objectWillChange.send(); defaults.set(newValue.storage, forKey: Key.pillColor) }
    }

    var pillPadding: Double {
        get { let v = defaults.double(forKey: Key.pillPadding); return v > 0 ? v : 28 }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.pillPadding) }
    }
}

/// Shared location for app data (models, history) under Application Support.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ama", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var historyFile: URL {
        supportDirectory.appendingPathComponent("history.json")
    }
}
