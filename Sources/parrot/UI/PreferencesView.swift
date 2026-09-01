import SwiftUI

extension Notification.Name {
    /// Posted (object: optional tab string like "permissions") to open the
    /// Settings window, optionally on a specific tab.
    static let amaOpenPreferences = Notification.Name("amaOpenPreferences")
}

/// Historically the Settings window had separate Settings and Permissions tabs.
/// They're now one continuous surface (permissions live at the top of
/// `SettingsView`), so this is a single case kept only so the deep-link plumbing
/// in AppDelegate — which can request the window open "on permissions" — still
/// compiles. There is nothing to switch between.
enum PrefTab: Hashable {
    case settings, permissions
}

/// Held by the AppDelegate so it can deep-link the Settings window open (e.g.
/// straight from the Dictation permission banner on first run). With a single
/// pane the value no longer selects anything, but the router stays so callers
/// keep working.
@MainActor
final class PreferencesRouter: ObservableObject {
    @Published var tab: PrefTab = .settings
}

/// The standalone Settings window: one continuous settings surface with the
/// permission checks at the top, followed by the app's preferences.
struct PreferencesView: View {
    @ObservedObject var router: PreferencesRouter

    var body: some View {
        SettingsView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
