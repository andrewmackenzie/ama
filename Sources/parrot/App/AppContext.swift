import AppKit

/// The app receiving the dictation, and how cleanup should adapt to it.
///
/// Ama dictates in the background (it never steals focus), so the frontmost
/// application at inject time is the target app.
struct AppContext {
    enum Category {
        case mail
        case chat
        case code
        case general

        /// Skip AI cleanup entirely here (code/terminal — cleanup would mangle it).
        var skipsCleanup: Bool { self == .code }

        /// Extra guidance appended to the cleanup prompt for this app type.
        var promptHint: String? {
            switch self {
            case .mail:
                return "The target app is an email client. If the message contains a greeting or sign-off, format it as an email; otherwise leave it as plain text."
            case .chat:
                return "The target app is a chat/messaging app. Keep the message casual and brief. Never add a greeting or sign-off, and do not use bullet lists unless the whole message is only a list."
            case .code, .general:
                return nil
            }
        }
    }

    let name: String
    let bundleID: String
    let category: Category

    /// A one-line context string for the cleanup prompt, or nil when there's
    /// nothing app-specific to say.
    var promptContext: String? {
        guard let hint = category.promptHint else { return nil }
        return "The user is dictating into \(name). \(hint)"
    }

    @MainActor
    static func frontmost() -> AppContext {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "an app"
        return AppContext(name: name, bundleID: bundleID, category: classify(bundleID))
    }

    private static func classify(_ bundleID: String) -> Category {
        let id = bundleID.lowercased()
        if mailIDs.contains(id) { return .mail }
        if chatIDs.contains(id) { return .chat }
        if codeIDs.contains(id) || id.hasPrefix("com.microsoft.vscode") { return .code }
        return .general
    }

    private static let mailIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.readdle.smartemail-mac",       // Spark
        "com.airmail.mac",                   // Airmail
        "com.google.chrome.app.gmail",       // Gmail web app
    ]

    private static let chatIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",         // Slack
        "com.apple.mobilesms",               // Messages
        "com.hnc.discord",                   // Discord
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "net.whatsapp.whatsapp",
        "ru.keepcoder.telegram",             // Telegram
        "org.telegram.desktop",
        "com.facebook.archon",               // Messenger
    ]

    private static let codeIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "com.apple.dt.xcode",
        "dev.zed.zed",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.todesktop.230313mzl4w4u92",     // Cursor
        "com.barebones.bbedit",              // BBEdit
    ]
}
