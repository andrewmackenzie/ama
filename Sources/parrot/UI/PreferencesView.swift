import SwiftUI

extension Notification.Name {
    /// Posted (object: optional tab string like "permissions") to open the
    /// Settings window, optionally on a specific tab.
    static let amaOpenPreferences = Notification.Name("amaOpenPreferences")
}

enum PrefTab: Hashable {
    case settings, permissions
}

/// Drives which tab the Settings window shows. Held by the AppDelegate so it can
/// deep-link (e.g. open straight to Permissions on first run).
@MainActor
final class PreferencesRouter: ObservableObject {
    @Published var tab: PrefTab = .settings
}

/// The standalone Settings window: a sidebar of Settings / Models / Permissions
/// with the selected pane on the right — the same shape the main window used to
/// have, and reliable selection behavior.
struct PreferencesView: View {
    @ObservedObject var router: PreferencesRouter

    var body: some View {
        NavigationSplitView {
            List(selection: $router.tab) {
                Label("Settings", systemImage: "gearshape").tag(PrefTab.settings)
                Label("Permissions", systemImage: "lock.shield").tag(PrefTab.permissions)
            }
            .navigationSplitViewColumnWidth(min: 172, ideal: 188, max: 220)
        } detail: {
            Group {
                switch router.tab {
                case .settings: SettingsView()
                case .permissions: PermissionsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
