# Debugging "overlay missing over full-screen apps"

Kit for the intermittent bug where dictating into a full-screen Space showed no recording
overlay, even though dictation itself worked. Resurrect this if it comes back.

## What we know

- The overlay is one long-lived `.screenSaver`-level (`level.rawValue == 1000`) `NSPanel`, created
  once in `RecordingOverlay.ensureWindow()` and reused for the app's lifetime.
- **Symptom capture:** with the external probe (below) running, the level-1000 Ama window stayed
  `onscreen=false` for the *entire* failing dictation — the panel never made it onto the active
  Space. When it works, it flips `onscreen=true`.
- **Not the collection behavior / level / activation policy.** A standalone Swift HUD (see
  `hudtest*.swift` idea below) with the *exact* flags — `[.canJoinAllSpaces, .stationary,
  .ignoresCycle, .fullScreenAuxiliary]`, `.screenSaver`, `.nonactivatingPanel` — reliably joins a
  full-screen Space (`isOnActiveSpace == true`) as both `.accessory` and `.regular`, fresh or
  reused across hide/show cycles. So the window setup is fine in isolation.
- **`NSScreen.main.visibleFrame` is NOT a full-screen indicator from a background app.** Even when
  another app is truly full-screen, Ama (on the desktop Space) reads `visibleFrame == (0,58,1470,865)`
  — desktop insets (Dock + menu bar). Don't use it to detect full-screen. Positioning still lands
  on-screen because `visible.minY + 20` is a small bottom offset that's valid in full-screen too.
- **The fix (commit a407d55):** `show()`/`finish()` used to skip `positionAtBottomCenter` +
  `orderFrontRegardless()` whenever `needsAppear` was false, and that flag trusted `window.isVisible`
  — which reports a stale `true` after a Space switch while the panel sits off-screen on the old
  Space. Now both always call `presentOnActiveSpace()` (re-assert collectionBehavior + reposition +
  orderFront); `isVisible`/state only decide the grow-in animation.

## Instrumentation to re-add (into `RecordingOverlay.presentOnActiveSpace`)

Drop this in place of the clean body; it appends before/after `isOnActiveSpace` to a log file and
Console. Strip it again once diagnosed.

```swift
private func presentOnActiveSpace(_ window: NSPanel) {
    let before = "onActive=\(window.isOnActiveSpace) visible=\(window.isVisible) level=\(window.level.rawValue)"
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    positionAtBottomCenter(window)
    window.orderFrontRegardless()
    let sf = NSScreen.main.map { "screen=\($0.frame) vis=\($0.visibleFrame)" } ?? "screen=nil"
    let msg = "[overlay] present BEFORE{\(before)} AFTER{onActive=\(window.isOnActiveSpace) visible=\(window.isVisible)} frame=\(window.frame) \(sf)"
    NSLog("%@", msg)
    if let data = (msg + "\n").data(using: .utf8) {
        let url = URL(fileURLWithPath: "/tmp/ama-overlay.log")
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() }
        else { try? data.write(to: url) }
    }
}
```

Build + install with the `.command`/sudo hand-off (the app in `/Applications` is root-owned from the
`.pkg`):

```sh
make install    # builds + Developer ID-signs build/Ama.app, fails only at the root-owned copy
# then, in a real Terminal so sudo can Touch-ID:
sudo rm -rf /Applications/Ama.app && sudo cp -R "$PWD/build/Ama.app" /Applications/ && open /Applications/Ama.app
```

Then dictate in a **true** full-screen Space and read `/tmp/ama-overlay.log`. Failure signature:
`AFTER{onActive=false ...}`.

## External probe — watch the panel from another process (no rebuild needed)

`kCGWindowIsOnscreen` on Ama's level-1000 window tells you whether the panel is on the *currently
visible* Space. Run this while dictating in full-screen; `overlayOnscreen=false` throughout a
dictation == the failure.

```swift
// swift /tmp/live.swift  — samples ~30s at 0.15s
import AppKit
import CoreGraphics
import Foundation
func overlay() -> (Bool, String) {
    guard let l = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String:Any]] else { return (false,"nolist") }
    for w in l where (w[kCGWindowOwnerName as String] as? String) == "Ama" && (w[kCGWindowLayer as String] as? Int) == 1000 {
        let on = w[kCGWindowIsOnscreen as String] as? Bool ?? false
        let b = w[kCGWindowBounds as String] as? [String:Any] ?? [:]
        return (on, "\(b["X"] ?? "?"),\(b["Y"] ?? "?")")
    }
    return (false, "nowin")
}
func fmt(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: d) }
for _ in 0..<200 {
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let (on, pos) = overlay()
    print("\(fmt(Date())) front=\(front) overlayOnscreen=\(on) pos=\(pos)"); fflush(stdout)
    Thread.sleep(forTimeInterval: 0.15)
}
```

A change-only variant that also logs the frontmost app + a cross-process full-screen guess
(front app's top layer-0 window covering the whole display) is handy for catching a *natural*
failure over minutes — see git history of this file if you need it.
