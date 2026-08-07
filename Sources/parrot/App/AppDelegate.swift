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
    private let models = ModelManager()
    private var engine: DictationEngine!
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        history.setLimit(settings.historyLimit)

        let model = ModelRegistry.find(settings.modelID) ?? ModelRegistry.recommended()!
        engine = DictationEngine(
            model: model,
            hotkey: settings.hotkey,
            showOverlay: settings.showOverlay,
            history: settings.keepHistory ? history : nil
        )
        engine.start()

        buildMenu()
        buildWindow()

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
            .environmentObject(models)

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Ama"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 540))
        window.minSize = NSSize(width: 640, height: 440)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        showWindow()
    }

    private func showWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Ama", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
