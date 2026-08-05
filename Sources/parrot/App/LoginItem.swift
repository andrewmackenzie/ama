import Foundation
import ServiceManagement

/// Registers the app as a launch-at-login item via `SMAppService`.
///
/// This is the modern mechanism for a bundled `.app` (it replaces the CLI's
/// LaunchAgent plist, which stays available for terminal users). It is reliable
/// once the app is Developer-ID signed; ad-hoc dev builds may surface a
/// System Settings → Login Items prompt on first registration.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Apply the desired state. Returns false if the OS refused (e.g. the app
    /// isn't running from a real bundle, as when launched via `swift run`).
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            FileHandle.standardError.write(Data("login item update failed: \(error)\n".utf8))
            return false
        }
    }
}
