import AppKit
import ApplicationServices

/// A snapshot of *exactly* where keyboard focus was when dictation started: the
/// app, its focused window, and the focused UI element inside it. Captured on
/// key-press so we can route the transcript back to that precise window on
/// release — even if you switched to another window (or another app) mid-dictation.
///
/// This matters when several windows of the same app are open (e.g. multiple
/// Terminal windows each running a Claude Code session): plain
/// `NSRunningApplication.activate()` only guarantees *some* window of the app
/// comes forward, not the one you were in. Raising the captured `AXUIElement`
/// window pins it to the exact one.
///
/// Requires the Accessibility permission ama already needs for the hotkey tap
/// and keystroke injection, so no extra prompt.
struct FocusTarget {
    let app: NSRunningApplication?
    /// The focused UI element (usually a text field/area) at capture time.
    let element: AXUIElement?
    /// The window containing that element.
    let window: AXUIElement?

    @MainActor
    static func capture() -> FocusTarget {
        let app = NSWorkspace.shared.frontmostApplication
        let element = systemFocusedElement()
        let window = element.flatMap(containingWindow)
        return FocusTarget(app: app, element: element, window: window)
    }

    /// True if the captured element still holds keyboard focus right now, so we
    /// can inject immediately without any window raise (the common "stayed put"
    /// case). Avoids an unnecessary activate + delay.
    @MainActor
    func isStillFocused() -> Bool {
        guard let app, app.isActive, let element else { return false }
        guard let current = FocusTarget.systemFocusedElement() else { return false }
        return CFEqual(current, element)
    }

    /// Bring the exact captured window back to the front and restore focus to it,
    /// then to the focused element, then bring the app frontmost so keystrokes
    /// route here.
    @MainActor
    func restore() {
        if let window {
            // Make this specific window the app's main/focused one and raise it
            // above the app's other windows (e.g. the right Terminal window).
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
        }
        if let element {
            // Best-effort: many apps re-focus the field; terminals ignore it but
            // the window raise + app frontmost already put the tty in focus.
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
        }
        guard let app else { return }
        // Bring the app frontmost via the Accessibility API. macOS 14+ cooperative
        // activation ignores `NSRunningApplication.activate()` from a background
        // app (ama isn't frontmost, so it can't hand focus to another app). Setting
        // kAXFrontmost on the app's AX element is privileged and actually switches.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, true as CFTypeRef)
        // Belt and suspenders for apps that honor the normal path.
        app.activate()
    }

    // MARK: - AX helpers

    private static func systemFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return copyElement(system, kAXFocusedUIElementAttribute)
    }

    private static func containingWindow(_ element: AXUIElement) -> AXUIElement? {
        copyElement(element, kAXWindowAttribute)
            ?? copyElement(element, kAXTopLevelUIElementAttribute)
    }

    /// Read an attribute that is itself an `AXUIElement`, with a type check so a
    /// non-element value can't crash the force-cast.
    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
