# Adopting the best of Talkify into ama

Comparison and adoption plan. Talkify is [tornikegomareli/Talkify](https://github.com/tornikegomareli/Talkify),
MIT-licensed (so we may reuse code with attribution). ama is this repo.

## Decision (2026-08-17)

**Going all-in on Apple Speech.** ama will drop WhisperKit and move to Apple's
`SpeechAnalyzer` / `SpeechTranscriber`, raising the OS floor to **macOS 26
(Tahoe) on Apple Silicon**. This buys streaming live text, instant start, no
model-download UX, and no ANE contention (our known stall source), at the cost
of pre-Tahoe and Intel users. The dual-engine option below is retained only as
historical context; the plan now assumes a single Apple-Speech engine.

**First build step: the overlay fullscreen fix (Tier 0.1).** Done — see
`Sources/parrot/UI/RecordingOverlay.swift` (panel level `mainMenu + 3` +
`constrainFrameRect` override).

## TL;DR

Talkify is prettier and has more surface features; ama had a more portable and
smarter text pipeline. With the all-in Apple Speech decision, ama converges
toward Talkify's engine and gains streaming; we still keep ama's differentiators
(AI cleanup pass, history, git-versioned notarize/Sparkle pipeline, headless CLI,
unicode injector).

## The one decision that matters: the speech engine

| | ama (today) | Talkify |
|---|---|---|
| Engine | WhisperKit (Whisper models) | Apple `SpeechAnalyzer` / `SpeechTranscriber` |
| OS floor | **macOS 14** | **macOS 26 (Tahoe)**, Apple Silicon only |
| Model | Downloads GB-scale Whisper models, warm-up cost, ANE contention (our known stall source) | Apple-managed assets via `AssetInventory`, per-language warm sessions |
| Latency | Batch: transcribes **after** you stop talking | **Streaming**: volatile + finalized text *while* you speak (`.volatileResults, .fastResults`) |
| Multi-language | Single model | Per-key language, reserved locales, second-language key |
| Quality control | AI cleanup pass (filler removal) on top | Raw Apple output |

Talkify's engine (`Dictation/SpeechRecognitionService.swift`) is the source of
most of its "feels instant" magic: live text streaming into the HUD, no model
download UX, no ANE fight. But it costs you every pre-Tahoe and Intel user.

**Chosen path (all-in):** replace `WhisperKitTranscriber` with an
`AppleSpeechTranscriber` modeled on Talkify's `SpeechRecognitionService.swift`,
kept behind our existing `Transcriber` protocol
(`Sources/parrot/Transcription/Transcriber.swift`) so the pipeline seams stay.
Raise `Package.swift` platform to `.macOS(.v26)`, delete WhisperKit model
management (`Models/`, `App/ModelManager.swift`, `UI/ModelsView.swift`), and
retarget the AI cleanup pass to run on the streamed final text. The streaming
draft also unlocks the Compact-captions HUD visual.

## Where each app is stronger

**Talkify wins:** the notch HUD and its voice visuals, the settings UI, sounds,
read-aloud, drop-file transcription, usage insights, streaming text, a clean
reducer-based session state machine.

**ama keeps (its remaining differentiators after the engine swap):** the AI
cleanup pass (`App/TextCleaner.swift`), transcript history, git-derived
auto-versioning + notarize + Sparkle pipeline, the headless CLI, and a proven
`CGEventKeyboardSetUnicodeString` injector (`Input/TextInjector.swift`).
(macOS 14 + Intel support and WhisperKit are dropped by the all-in decision.)

## Adoption plan, in tiers

### Tier 0 — quick wins (hours, no rearchitecting)

1. **Fix the overlay over fullscreen** (the bug that started this). **DONE.**
   `UI/RecordingOverlay.swift` now uses an `OverlayPanel` subclass at level
   `NSWindow.Level.mainMenu + 3` with a `constrainFrameRect` override, mirroring
   Talkify's `CoreHUD/HUDPanel.swift`. `.statusBar` (25) wasn't high enough to
   draw over a full-screen Space. Fixes fullscreen Terminal.
2. **Session sounds.** Talkify's `CoreHUD/HUDSounds.swift` plays begin/end/paste
   cues, volume-controlled, toggleable. Small, high-delight.
3. **Dead-mic watchdog.** `DictationHUDController` flags "no levels for 600ms
   while listening" as a dead mic vs. silence. Cheap reliability win.

### Tier 1 — the HUD overhaul (the big visual upgrade)

Replace the bottom-center glyph with Talkify's top-center **notch HUD**, kept as
a new overlay *preset* so the current glyph stays available.

- Window/placement: `CoreHUD/HUDPanel.swift`, `HUDPlacement.swift` (picks the
  display by focused target → pointer → main), `NSScreen+DisplayID.swift`. The
  notch surface renders on external monitors too (simulated notch) — see
  `docs/adr/0001`.
- Voice visuals catalog (`Dictation/HUD/Visuals/`): Waveform (Metal shader),
  Edge Glow with palettes, Compact captions (needs streaming text), Siri wave,
  Siri orb, particle cloud, plain level meter (Reduce-Motion fallback).
- Metal particle renderer rationale: `docs/adr/0002` (fail-soft, pauses when
  idle). Port the SwiftUI-shader visuals first; the Metal cloud is optional.

Effort: this is the largest chunk. Sequence it as (a) window + placement, (b)
one SwiftUI visual (Edge Glow), (c) wire mic level, (d) add the rest.

### Tier 2 — settings UI polish

Talkify's settings (`Settings/`) are a sidebar + live-preview-card layout with a
themed component kit (`Settings/Components/`: `SettingsCard`, `SettingsRow`,
`KeyRecorderView`, `KeyboardMapView`, preview stages). Adopt:

- The sidebar section model (`SettingsSections.swift`) and live preview cards so
  overlay/glyph changes render instantly (we already have presets to show).
- `KeyRecorderView` for a proper hotkey picker (ama currently watches a fixed Fn
  key in `Input/HotkeyMonitor.swift`).
- `@Observable` UserDefaults-backed `AppSettings` pattern (`App/AppSettings.swift`)
  is cleaner than scattered stores if we're refactoring anyway.

### Tier 3 — new side-features (each self-contained)

- **Read Aloud** (`ReadAloud/`): speak the focused app's selected text via
  `AVSpeechSynthesizer`, toggled by a shortcut. Reads selection over the a11y
  API. Small, no engine dependency.
- **Drop Transcription** (`DropTranscription/`): drag an audio/video file onto
  the HUD, transcribe to clipboard/file. `FileTranscriptionService` deliberately
  builds its own analyzer per job so it never stalls live dictation. With the
  all-in Apple Speech engine this ports almost directly.
- **Insights** (`Insights/`): local-only usage metrics (words, speaking time,
  sessions/day) in an `actor UsageStore` writing `usage.json`. Pairs well with
  our existing history.

### Tier 4 — the streaming engine migration (core, macOS 26)

**This is now a core migration, not an add-on.** Replace `WhisperKitTranscriber`
with `AppleSpeechTranscriber: Transcriber`, modeled on
`SpeechRecognitionService.swift`. Steps: raise the `Package.swift` floor to
macOS 26; port the actor (prepared per-language sessions, `AssetInventory`
reservation, `.volatileResults + .fastResults` streaming); feed streamed text to
the HUD live and the final string to `TextInjector` + `TextCleaner`; delete
WhisperKit deps and the model-download UI. Gains: instant start, streaming draft,
multi-language, no downloads, no ANE contention. Sequence this before the HUD's
Compact-captions visual, which depends on live text.

## Architecture worth stealing regardless

- **`DictationSessionMachine`** — a pure reducer (actions → state → effects,
  no clocks/services) makes the gesture rules (tap-to-latch, cancel-while-
  starting, no-speech) unit-testable. ama's `DictationEngine` mixes state and
  side effects; extracting a reducer would harden double-tap-lock.
- **Per-language warm sessions + reservation eviction** in the speech actor —
  only relevant if we take Tier 4.
- **MV + local reducers** pattern (`docs/adr/0005`, `0006`).

## Licensing / hygiene

Talkify is MIT. Copying files or substantial code needs the copyright line
retained and a mention in our `THIRD-PARTY-LICENSES.txt`. Porting ideas/APIs
(Apple frameworks) needs nothing.

## Suggested first PRs off this branch

1. Overlay fullscreen fix + session sounds (Tier 0). Ships value immediately.
2. Notch-HUD preset with the Edge Glow visual (Tier 1, sliced).
3. Read Aloud (Tier 3, isolated, low risk).

Everything else follows once the HUD window plumbing exists.
