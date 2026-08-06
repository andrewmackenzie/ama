import SwiftUI

/// Sidebar sections of the main window.
enum SidebarSection: String, CaseIterable, Identifiable {
    case home = "Dictation"
    case history = "History"
    case models = "Models"
    case settings = "Settings"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: return "mic.fill"
        case .history: return "clock.arrow.circlepath"
        case .models: return "cube.box"
        case .settings: return "gearshape"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: DictationEngine
    @State private var selection: SidebarSection = .home

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: routeOnFirstAppearance)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home: HomeView()
        case .history: HistoryView()
        case .models: ModelsView()
        case .settings: SettingsView()
        case .permissions: PermissionsView()
        case .about: AboutView()
        }
    }

    /// Send first-time users to Permissions if anything critical is missing.
    private func routeOnFirstAppearance() {
        if !settings.hasCompletedOnboarding {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                selection = .permissions
            }
        }
    }
}
