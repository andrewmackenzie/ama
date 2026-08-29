# Task: move "Check for Updates" into Settings, with a visible result

**Status:** not started. Delete this file (and the "Active work" section of `CLAUDE.md`) when it ships.

> Normative spec for all five Mac apps: `~/.claude/capstan-app-distribution.md`
> § "In-app update checking" (requirements U1–U25). This task file is the Ama-specific work order;
> that section is the standard Wadlow, Warren VPN, and Safari Profile Switcher will be built to.

## Decision: no Sparkle, now or later

Andrew decided this explicitly on 2026-08-29. The existing appcast at
`https://www.capstannetworks.com/ama/ama.xml` stays the single source of truth for "what is the
current version," and `UpdateChecker` stays a ~110-line homegrown checker. Do not add the Sparkle
dependency, and do not adopt Sparkle's modal-alert convention. The whole update story is:

1. A **button in Settings** that checks the XML and says, right there in Settings, whether an
   update exists.
2. If one does, a **link** that downloads the `.pkg` to `~/Downloads` and opens it in Installer.
3. A **background check once or twice a day** that does the same thing unattended — updating the
   Settings text *and* lighting the green title-bar pill.

That's it. Nothing else.

## The problem

`Ama ▸ Check for Updates…` is a dead end. The menu action is:

```swift
@objc private func checkForUpdates() {
    Task { await updateChecker.check() }
}
```

`check()` is documented as *"Silent — never shows a dialog."* The title-bar pill is the only surface
for the result. So:

- **When you are up to date, clicking it does nothing at all.** No dialog, no "you're current." The
  pill was already hidden and stays hidden. The app looks broken.
- **There is no in-flight feedback.** `isChecking` is `@Published` but `UpdatePillView` never reads
  it, so the title bar stays blank during the fetch.
- The trailing `…` promises a dialog that never comes.
- Even on success it only *lights the pill* — you still have to find and click the pill to install.

## What to build

Remove the menu item. Put the control in **Settings**, where clicking it produces a line of text
that says what happened. Keep the pill as the ambient "there's an update" signal.

### 1. `UpdateChecker.swift` — record the outcome of a check

Add an outcome type and a published property. `available` alone can't drive the text line, because
`nil` means both "up to date" and "never checked".

```swift
/// Outcome of the most recent check — background or manual. `available` can't
/// express this on its own: nil means both "up to date" and "never checked".
enum CheckOutcome: Equatable {
    case upToDate(currentVersion: String)
    case updateAvailable(AvailableUpdate)
    case failed
}

@Published private(set) var lastOutcome: CheckOutcome?
```

Set `lastOutcome` at the end of `check()` in all three branches — found / up-to-date / threw.

Setting it **inside `check()`** (not in the button's action) is what makes the daily background
check refresh the Settings text for free: the timer and the button call the same method, and
`@Published` pushes to whatever is on screen.

**Do not change how `available` behaves on a network failure.** The existing `catch` deliberately
leaves `available` as-is so a flaky connection doesn't make a real pending update disappear. The
failure case sets `lastOutcome = .failed` and touches nothing else.

You'll want a `currentShortVersion` alongside the existing `currentBuild`, reading
`CFBundleShortVersionString`, so the up-to-date line can name the version.

**Change the interval to twice a day:** `interval` is currently `86_400` (24h). Make it `43_200`.
The existing `start()` behavior — check shortly after launch, then on the timer — is right; leave
that shape alone.

### 2. `SettingsView.swift` — a "Software Update" section

Add a `Section("Software Update")` (put it next to `Section("General")`) containing:

- A **"Check for Updates"** button. Disabled while `isChecking`.
- A result line beneath it, `.font(.caption).foregroundStyle(.secondary)`, driven by `lastOutcome`:
  - `nil` → show the current version, e.g. *"Ama 0.1.50."*
  - `.upToDate(v)` → *"Ama \(v) is the latest version."*
  - `.updateAvailable(u)` → *"Ama \(u.shortVersion) is available."* followed by a
    **"Download and install"** link — `Button(…) { updateChecker.downloadAndOpen() }` with
    `.buttonStyle(.link)`, matching the "Reset to defaults" link already in this file. Show
    "Downloading…" and disable it while `isDownloading`.
  - `.failed` → *"Couldn't check for updates. Check your connection and try again."*
- While `isChecking`, show *"Checking…"* with a small `ProgressView`.

Reach the checker with `@EnvironmentObject var updateChecker: UpdateChecker` — see wiring below.

`downloadAndOpen()` already does exactly what's wanted (downloads the `.pkg` to `~/Downloads`,
`NSWorkspace.open` hands it to Installer, falls back to opening the URL in a browser). Don't
reimplement it.

### 3. `AppDelegate.swift` — wiring

**a. Inject the checker into the Settings window.** This is the step that's easy to miss:
`updateChecker` is currently a plain `private let` handed directly to `UpdatePillView`. It is *not*
in the environment. Add `.environmentObject(updateChecker)` to the preferences root view
(alongside the existing `engine` / `settings` / `history`, ~line 176). Add it to the main window
root too (~line 92) if anything there ends up needing it.

Because both windows then observe **the same `UpdateChecker` instance**, "the background check also
lights the pill" falls out for free — `available` is `@Published`. Do not create a second
`UpdateChecker`.

**b. Delete the menu item and its action.** Remove the `@objc private func checkForUpdates()` and
the `updateItem` lines in the menu builder.

Watch the separators — the app menu is currently
`About / --- / Check for Updates / --- / Settings / …`. Removing just the item leaves two adjacent
separators and a visible double rule. Remove one separator with it.

## Acceptance

- No "Check for Updates" in the `Ama` menu; no double separator where it was.
- Settings ▸ Software Update shows the current version on open, before any check.
- Clicking Check for Updates when current → *"Ama 0.1.50 is the latest version."* Never silence.
- With `AMA_FAKE_UPDATE=1`: the section offers the download link, **and** the green title-bar pill
  on the main window is lit at the same time. Clicking the link lands `Ama.pkg` in `~/Downloads`
  and opens Installer.
- A background check that finds an update updates the Settings line and the pill together, with
  Settings already open and untouched.
- Offline → the failure line appears, and a previously-detected update is still shown (not cleared).
- The empty-state pill still renders `Color.clear` inside its fixed 168×28 frame. **Do not touch
  that frame** — collapsing it to zero re-triggers the infinite AppKit re-layout loop that pins the
  CPU. See `CLAUDE.md`.

## Testing

`make app && AMA_FAKE_UPDATE=1 open build/Ama.app` covers the update-available path without cutting
a release. For the real path, `make install` and compare against the live feed at
`https://www.capstannetworks.com/ama/ama.xml`.

To exercise the timer without waiting 12 hours, temporarily drop `interval` to ~60s — but put it
back to `43_200` before committing.
