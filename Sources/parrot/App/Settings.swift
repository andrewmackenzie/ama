import Foundation
import SwiftUI

/// User preferences, persisted to `UserDefaults`. Single source of truth for
/// the GUI; the CLI `run` command can still override individual values via
/// flags at launch.
@MainActor
final class Settings: ObservableObject {
    private let defaults: UserDefaults

    nonisolated static let suiteName = "com.digimata.parrot"

    private enum Key {
        static let modelID = "modelID"
        static let hotkey = "hotkey"
        static let showOverlay = "showOverlay"
        static let launchAtLogin = "launchAtLogin"
        static let keepHistory = "keepHistory"
        static let historyLimit = "historyLimit"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    init(defaults: UserDefaults = UserDefaults(suiteName: Settings.suiteName) ?? .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.modelID: ModelRegistry.recommended()?.id ?? "whisper-base.en",
            Key.hotkey: Hotkey.fn.rawValue,
            Key.showOverlay: true,
            Key.launchAtLogin: false,
            Key.keepHistory: true,
            Key.historyLimit: 200,
            Key.hasCompletedOnboarding: false,
        ])
    }

    var modelID: String {
        get { defaults.string(forKey: Key.modelID) ?? "whisper-base.en" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.modelID) }
    }

    var hotkey: Hotkey {
        get { Hotkey(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .fn }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.hotkey) }
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

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }
}

/// Shared location for app data (models, history) under Application Support.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("parrot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var historyFile: URL {
        supportDirectory.appendingPathComponent("history.json")
    }
}
