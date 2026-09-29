# Upstream review: digimata/parrot, 2026-09-29

Upstream is active (pushed 2026-09-29), ~120 commits past our fork point `62f8d98`, with
tags v0.1.0–v0.2.1 and new `develop`/`stats` branches. Fetched here as `upstream`.

## Verdict: never merge. Hand-port three ideas.

Upstream doubled down on everything Ama walked away from: WhisperKit, an embedded Sparkle
framework with signed updates, DMG distribution, a menu-bar-only app, their own
settings/onboarding windows, and the perroquet.xyz site. A merge or rebase would be one
giant conflict against decisions already made (SpeechAnalyzer, homegrown UpdateChecker,
.pkg, Dock app). Their input code also lives in
`Sources/ParrotCore/Input/{Delivery,FocusSnapshot,Spacing}.swift`, which doesn't map to our
tree, so `git cherry-pick` won't apply — port by hand.

## 1. Delivery hardening — upstream `863125e` (highest value, do first)

Our `Sources/parrot/Input/TextInjector.swift` is still the naive 58-line original and has
every bug that commit fixes:

- **Nil CGEventSource**: synthesized events inherit whatever modifiers the user holds, so a
  held Control can turn the transcript into keyboard shortcuts. Fix: a private
  `CGEventSource` with explicit flags on every event.
- **Unicode payload on both key-down and key-up** (`TextInjector.swift:51,55`): some apps
  insert every chunk twice. Fix: payload on key-down only.
- **Silent drops**: terminals and Electron apps ignore `CGEventKeyboardSetUnicodeString`;
  dictation there produces nothing, no error.
- **No secure-field check**: a click during transcription can land the transcript in a
  password field.
- **No pre-delivery focus re-check** at the injector level (our AX focus capture/restore
  handles routing, not the "is this still safe" decision).

Upstream's design, worth adopting wholesale:

- **Paste by default.** Snapshot every representation of every pasteboard item; write the
  transcript marked `org.nspasteboard.TransientType` + `ConcealedType` so clipboard managers
  skip it; post ⌘V (keycode 9, explicit flags); restore the snapshot after 250 ms. A second
  paste inside the window keeps the first snapshot; a copy made by anything else during the
  window is kept rather than overwritten. Keep type-unicode behind a flag.
- **FocusSnapshot at recording start** (frontmost app, focused element, secure/protected
  flags), compared with a fresh snapshot before delivery, as a pure tested decision:
  secure field at either end → discard the transcript and log why; different app/element →
  clipboard instead, surfaced through the overlay.

This composes with our existing exact-window focus routing rather than replacing it.

## 2. Trailing space — upstream `4234de8` + `82245f1`

Consecutive dictations run together ("works well.The only thing"); transcripts never end
with a space and we append nothing. Lessons already learned upstream:

- Paste the trailing space **with the text**. A separate Space keypress after the paste
  raced ChatGPT's asynchronous paste, and delaying it made the cursor visibly jump in
  Slack. Slack trims a pasted trailing space, so dictations there still run together —
  accepted trade-off.
- Leading space only when the app reports a word directly before the cursor. Terminals
  like Ghostty report the cursor at position 0 regardless, so position 0 counts as
  field-start only when the field is empty.
- No spaces for Chinese, Japanese, Thai.

## 3. Maybe: first-run permissions window — upstream `9dfe1d0`, `dd19045`

Explains both grants before macOS prompts; asks for the microphone before Accessibility.
Onboarding polish, only relevant if Ama grows beyond personal use.

## Skip

- All Whisper-specific work: silence trim + 0.3 s padding, mel-on-CPU, model manager,
  language detection/settings. Different engine.
- AUHAL capture path and its rate-change handling: their own commit (`9956e56`) notes the
  AVAudioEngine path resamples through rate changes fine; our fresh-engine-per-start
  doesn't have the problem AUHAL introduced.
- Everything Sparkle, DMG, site, and stats-branch CI.
