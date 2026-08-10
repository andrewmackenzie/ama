import SwiftUI

/// The main window is now just the Dictation screen. Settings, Models, and
/// Permissions live in a separate Settings window (Ama ▸ Settings…, ⌘,).
struct RootView: View {
    var body: some View {
        HomeView()
    }
}
