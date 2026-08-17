import AppKit
import SwiftUI

/// Launches the GUI. Called from `main.swift` when the app is started without a
/// CLI subcommand (i.e. double-clicked, or run bare).
func launchGUI() {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        // NSApplication.delegate is weak; retain for the process lifetime.
        _ = Unmanaged.passRetained(delegate)
        app.delegate = delegate
        app.run()
    }
}

/// Owns the app lifecycle for the GUI: a regular Dock app with a single main
/// window. Closing the window leaves the app running (and still dictating);
/// clicking the Dock icon reopens it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let history = History()
    private var engine: DictationEngine!
    private var window: NSWindow!
    private var aboutWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private let preferencesRouter = PreferencesRouter()
    private let updateChecker = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        history.setLimit(settings.historyLimit)

        engine = DictationEngine(
            hotkey: settings.hotkey,
            showOverlay: settings.showOverlay,
            history: settings.keepHistory ? history : nil,
            doubleTapLock: settings.doubleTapLock,
            cleanup: settings.cleanupEnabled,
            writingStyle: settings.writingStyle,
            cleanupSystemPrompt: settings.cleanupSystemPrompt,
            listeningGlyph: settings.listeningGlyph,
            processingGlyph: settings.processingGlyph,
            doneGlyph: settings.doneGlyph,
            glyphSize: CGFloat(settings.glyphPointSize),
            symbolColor: settings.symbolColor.color,
            pillColor: settings.pillColor.color,
            pillPadding: CGFloat(settings.pillPadding),
            overlayStyle: settings.overlayStyle
        )
        engine.start()

        buildMenu()
        buildWindow()

        // Let anywhere in the app (e.g. the Dictation permission banner) open the
        // Settings window on a specific tab.
        NotificationCenter.default.addObserver(
            forName: .amaOpenPreferences, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                let tab: PrefTab? = (note.object as? String) == "permissions" ? .permissions : nil
                self?.openPreferences(tab: tab)
            }
        }

        // First run with missing permissions: send them straight to Permissions.
        if !settings.hasCompletedOnboarding, !DoctorReport.allOK(DoctorReport.run()) {
            openPreferences(tab: .permissions)
        }

        updateChecker.start()

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the Dock so the hotkey still dictates.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: - Window

    private func buildWindow() {
        let root = RootView()
            .environmentObject(engine)
            .environmentObject(settings)
            .environmentObject(history)

        // Use an NSHostingView as the window's contentView (rather than a
        // hosting *controller*) so SwiftUI's ideal content size never drives the
        // window size — a tall view like About's license text scrolls in place
        // instead of stretching the window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ama"
        window.minSize = NSSize(width: 640, height: 440)
        // Don't let macOS restore a stale window frame from a previous launch.
        window.isRestorable = false
        let hostingView = NSHostingView(rootView: root)
        // Fill the window without imposing SwiftUI's intrinsic size on it, so the
        // window keeps its own dimensions and content scrolls within.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 780, height: 540))
        window.center()
        window.isReleasedWhenClosed = false

        // Green "Update available" pill at the trailing edge of the title bar.
        let pill = NSTitlebarAccessoryViewController()
        pill.layoutAttribute = .right
        let pillHost = NSHostingView(rootView: UpdatePillView(appChecker: updateChecker))
        pillHost.frame = NSRect(x: 0, y: 0, width: 168, height: 28)
        pill.view = pillHost
        window.addTitlebarAccessoryViewController(pill)

        self.window = window
        showWindow()
    }

    private func showWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the custom About window (Ama menu → About Ama). A dedicated,
    /// fixed-size, non-resizable window so the license text scrolls in place.
    @objc private func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "About Ama"
            let hostingView = NSHostingView(rootView: AboutView())
            hostingView.sizingOptions = []
            w.contentView = hostingView
            w.isReleasedWhenClosed = false
            w.center()
            aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menu action (Ama ▸ Check for Updates…). Silent — result shows as the
    /// title-bar pill, not a dialog.
    @objc private func checkForUpdates() {
        Task { await updateChecker.check() }
    }

    /// Menu action (Ama ▸ Settings…, ⌘,).
    @objc private func showPreferences() {
        openPreferences(tab: nil)
    }

    /// Show the Settings window (Settings / Models / Permissions), optionally on
    /// a specific tab.
    private func openPreferences(tab: PrefTab?) {
        if let tab { preferencesRouter.tab = tab }
        if preferencesWindow == nil {
            let root = PreferencesView(router: preferencesRouter)
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(history)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Settings"
            w.minSize = NSSize(width: 620, height: 460)
            w.isRestorable = false
            let hv = NSHostingView(rootView: root)
            hv.sizingOptions = []
            w.contentView = hv
            w.setContentSize(NSSize(width: 720, height: 560))
            w.center()
            w.isReleasedWhenClosed = false
            preferencesWindow = w
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let aboutItem = appMenu.addItem(withTitle: "About Ama", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let updateItem = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(.separator())
        let prefItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        prefItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ama", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ama", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Standard Edit menu so cut/copy/paste + shortcuts work in text fields.
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
