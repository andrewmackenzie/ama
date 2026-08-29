# Ama — project instructions

Ultra-minimalist macOS dictation. Push-to-talk, on-device transcription, text injected at the
cursor. Ships as a Developer ID-signed, notarized `.pkg` to `/Applications/Ama.app`.

## Active work

**→ [docs/tasks/update-check-in-settings.md](docs/tasks/update-check-in-settings.md)** — move
"Check for Updates" out of the app menu and into Settings, with a visible result line. Read that
file before touching `UpdateChecker.swift`, `AppDelegate.swift`, or `SettingsView.swift`.

Delete this section and the task file once it ships.

## The product is Ama; the SPM module is still `parrot`

This repo is a fork of [digimata/parrot](https://github.com/digimata/parrot). The product was
renamed to Ama, but the SPM target, the built binary, and the source tree are all still `parrot`
(`Sources/parrot/…`, `.build/release/parrot`). The Makefile copies that binary into the bundle as
`ama` to match `CFBundleExecutable`.

Do not "fix" this inconsistency. Renaming the SPM target changes the binary path that the Makefile,
`build-pkg.sh`, and the signing pipeline all hardcode.

`.plan/plan.md` is inherited from upstream and is **stale** — it describes the original parrot
build-out (WhisperKit, CLI-only, menu-bar app), not this app. Do not treat it as the plan of record.

## Versioning is derived from git, never hand-edited

`SHORT_VERSION` is `0.1.<commit count>` and `BUILD_VERSION` is the raw commit count
(`git rev-list --count HEAD`), computed in the Makefile. `packaging/Info.plist` holds
`__SHORT_VERSION__` / `__BUILD__` placeholders that `make app` substitutes.

So **every commit bumps the version**. Never edit a version string by hand.

## Updates are homegrown. There is no Sparkle.

`Sources/parrot/App/UpdateChecker.swift` is the entire update system: a ~110-line checker that
fetches an appcast, compares its build number to the running app's `CFBundleVersion`, and — if
newer — downloads the `.pkg` to `~/Downloads` and hands it to Installer.

`Package.swift` has exactly one dependency (`swift-argument-parser`). The shipped app bundle has no
`Contents/Frameworks`. There is nothing to embed Sparkle in.

**The word "sparkle" appears all over this repo and means nothing.** The feed at
`https://www.capstannetworks.com/ama/ama.xml` uses the `sparkle:` XML namespace, and the Makefile
comments call it a "Sparkle appcast", but that is a *shape*, not a dependency — it is deliberately
Sparkle-flavored so two homegrown consumers can share one feed:

1. `UpdateChecker` in the app (parses it with `local-name()` XPath, so the namespace prefix is
   irrelevant), and
2. **Installomator**, for MDM-driven fleet updates (`docs/installomator.md`).

If you are about to conclude "this app uses Sparkle" from a grep hit, you are wrong. And do not
propose adopting Sparkle as a cleanup — the two-consumer feed is the point.

### Update-system landmines

- **The pill's 168×28 frame is load-bearing.** `UpdatePillView` renders `Color.clear` inside a
  *fixed* frame when there's no update. Letting it collapse to 0×0 creates a size conflict with the
  fixed-frame titlebar hosting view and sends AppKit into an infinite re-layout loop that pins the
  CPU. This was a real, shipped bug. Do not "simplify" the empty state.
- **`AMA_FAKE_UPDATE=1`** lights the pill without a real release. Use it to test update UI.
- **A stale-looking pill usually just means the running process predates the installed build.**
  Relaunching clears it. Check `CFBundleVersion` of `/Applications/Ama.app` against the feed's
  `sparkle:version` before chasing a bug.
- Network failures in `check()` deliberately leave `available` unchanged rather than clearing it,
  so a flaky connection doesn't make a real update vanish from the UI.

## Build

```sh
make app        # build build/Ama.app (ad-hoc signed, runs immediately)
make run        # launch it
make install    # Developer ID-signed copy into /Applications (needed for TCC grants to stick)
make pkg        # notarized .pkg + appcast into build/dist/  (ARGS=--no-notarize to iterate fast)
make release    # publish an already-built pkg + appcast
```

Ad-hoc signing is fine for logic work, but **microphone and accessibility grants only stick to a
stably-signed bundle** — use `make install` when testing anything that touches the hotkey, audio
capture, or text injection.

## Style

Match the surrounding code. It favors short files, doc comments that explain *why* (especially
where a workaround exists), and no ceremony. Several comments in this codebase are load-bearing
warnings about bugs that already happened once — preserve them when you edit nearby.
