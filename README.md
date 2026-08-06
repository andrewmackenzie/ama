# Parrot

A native macOS dictation app. Push-to-talk, on-device transcription, text inserted at the cursor.

Hold a key, speak, release — the transcript types itself in wherever your cursor is. Everything runs
locally on the Apple Neural Engine; audio never leaves the machine.

> Forked from [digimata/parrot](https://github.com/digimata/parrot) and reshaped from a menu-bar
> daemon into a regular Mac app: a real window with settings, model management, history, and
> permissions onboarding. A Dock app, not a menu-bar app.

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription is CoreML/ANE-only.

## Build & install

```sh
make app        # build Parrot.app (build/Parrot.app), ad-hoc signed and usable immediately
make run        # launch it
make install    # copy Parrot.app to /Applications
```

First launch opens the **Permissions** screen. Grant **Accessibility** (for the global hotkey + typing
at the cursor) and **Microphone**, and set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**
so Fn is a clean push-to-talk key. macOS may ask you to quit and reopen Parrot after granting
Accessibility.

## How to use

1. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread,
   anywhere a cursor blinks.
2. **Hold the push-to-talk key (default Fn), speak, release.** A small pill appears at the bottom of the
   screen while the mic is hot.
3. **The transcript types itself in at the cursor** when you release, usually within a few hundred ms.

Close the window and Parrot keeps running in the Dock so the hotkey still works. Quit with ⌘Q.

The window has:

- **Dictation** — live status and your most recent transcripts.
- **History** — every transcript, searchable and copyable (toggle off in Settings).
- **Models** — pick a Whisper model; downloads on-device with progress.
- **Settings** — push-to-talk key, recording overlay, launch-at-login, history.
- **Permissions** — mic / accessibility / Fn-key status with one-tap fixes.

## Distribution

Signed with a Capstan Networks Developer ID, notarized, and shipped as a `.pkg` with a
Sparkle appcast — the same pipeline as wadlow and Warren VPN. Build and publish are two
deliberate steps:

```sh
make pkg        # build → Developer ID sign → pkgbuild → notarize → staple → appcast
                # produces build/dist/Parrot.pkg + build/dist/parrot.xml
make pkg ARGS=--no-notarize   # fast iteration, skip the notary round-trip
make release    # publish the built pkg + appcast to GitHub Releases (v<version>)
```

The website (`capstannetworks-com`) pulls those two assets and serves them at
`https://www.capstannetworks.com/parrot/`. MDM fleets install/update via Installomator:
`installomator/parrot.sh` (label) or `scripts/installomator/update-parrot.sh`
(self-contained `valuesfromarguments` updater). Full details in
[docs/installomator.md](docs/installomator.md); the cross-project process reference lives at
`~/.claude/capstan-app-distribution.md`.

## CLI (advanced)

The same binary still works as a terminal daemon and toolbox — handy for scripting or a headless setup:

```sh
.build/release/parrot run                      # run the daemon in the foreground (^C to quit)
.build/release/parrot doctor                    # check permissions + fn key setting
.build/release/parrot models list               # list available models
.build/release/parrot models download <id>      # pre-download a model
.build/release/parrot install --launch-at-login # register a LaunchAgent (headless daemon)
.build/release/parrot run --model whisper-large-v3-turbo --no-overlay
```

Running `parrot` with no subcommand launches the GUI; any subcommand routes to the CLI.

## Stack

- **Swift** — single SPM executable target, bundled into `Parrot.app` by the `Makefile`
- **AppKit + SwiftUI** — regular Dock app, `NSApplicationDelegate` lifecycle hosting SwiftUI views
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSPanel** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for original design notes.

## Build from source

```sh
swift build -c release   # compiles the executable
make app                 # wraps it into Parrot.app
```
