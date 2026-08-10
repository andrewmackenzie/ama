# Dictation "stuck processing" — intermittent stall (investigation handoff)

Status: **partially fixed, still reproduces intermittently.** This doc is a handoff for a
fresh context to finish diagnosing/fixing.

## Symptom

After releasing the Fn key, dictation sometimes hangs on the **processing** state (the overlay
shows the `progress.indicator` "processing" glyph) for a long time before the text appears.
Observed stall durations: **~2s, 15s, 27s, 213s** — highly variable. Often the **first dictation
after launch**, but not exclusively. Most dictations are fast (~0.1–0.2s). Once it "unsticks," the
transcribed text is correct.

The user's words: "sometimes slow to start dictation, sometimes processing for 30 seconds",
"first one takes a while to go from lifting the fn key to text on the screen", "It's stuck
processing right now."

## What is NOT the cause (ruled out with data)

- **Not the Whisper transcription.** Instrumented timing shows the actual
  `pipeline.transcribe(audioArray:)` call is fast: **0.17–1.93s** for 5–8s of audio.
- **Not audio capture.** `capture.start()` is **0.06–0.30s**.
- **Not "still recording."** Audio length captured is normal (4.5–7.8s), and the overlay
  correctly transitions recording→processing, so the Fn *release* is detected.
- **Not AI cleanup.** Reproduces with cleanup OFF.
- **Not the title-bar update pill** (that was a *separate* bug — a layout feedback loop pinning
  the main thread at ~100% CPU; **fixed** by giving the pill a stable frame; idle CPU is now 0%).
- **Not CPU.** During the stall, `sample` shows **every thread idle** — waiting on
  semaphores / `mach_msg` / `ReceiveNextEventCommon`. Zero compute. The ANEServicesThreads are
  present but waiting. Main thread is idle in the event loop.

## The actual measurement

Timing logs added around the pipeline (since removed — see "Debug tooling"):

```
◂ release dwell=7.09s, 7.0s audio
⏱ transcribeAndInject: 7.0s of audio captured
⏱ transcribe 1.93s (release→done 27.37s)     ← transcribe call = 1.93s, but total 27.37s
```

`release→done` = time from entering `transcribeAndInject` to the transcription Task finishing.
`transcribe` = time inside the Task from its first line to after `await transcriber.transcribe`.
The **gap = release→done − transcribe ≈ 25s**: the transcription **Task does not start / make
progress for ~25s**, even though the whole app is idle.

## Fix applied this session (helped a lot, but not complete)

The transcription was launched as a **main-actor `Task {}`** in
`DictationEngine.transcribeAndInject`. A main-actor Task was sitting unscheduled for tens of
seconds despite the main thread being idle. Changing it to **`Task.detached(priority:
.userInitiated)`** (only the final text-insert hops back to `MainActor.run`) dropped observed
times to **0.19s (warm)** and **2.28s (cold first launch)** in my testing.

**BUT the user still reproduces the long stall intermittently after `Task.detached`.** So the
detached change reduced frequency/severity but did not eliminate it. During a fresh stall the
sample still shows everything idle.

## Current leading hypothesis

Swift-concurrency / actor scheduling. `WhisperKitTranscriber` is an `actor`; `transcribe` and
`warmUp` are actor-isolated (serialized). Candidates to investigate:

1. **The detached task's `await transcriber.transcribe(samples)` suspends and its continuation
   isn't resumed for a long time** — e.g. the transcriber actor is waiting on a CoreML/ANE
   prediction continuation that only resumes on ANE availability. The ANE is a shared system
   resource; contention (or a prior in-flight ANE op — the launch **prime** also transcribes on
   the same actor) could queue the real transcribe.
2. **Cooperative thread-pool starvation.** If any async code blocks a cooperative pool thread
   (synchronous wait inside an async fn), new tasks can't be scheduled. Suspects: the on-launch
   update checks (`UpdateChecker.check()` and `ModelManager.checkForUpdates()` both do
   `URLSession` on launch) — should suspend, but verify they never block. WhisperKit internals
   may also block a pool thread.
3. **Actor serialization with the prime.** `warmUp()` runs a prime transcribe on the actor at
   launch. If warmUp/prime overlaps the first real transcribe (or an ANE op from it is still
   settling), the first real transcribe serializes behind it. Note the prime completes in
   ~0.17s per logs, so this seems unlikely alone — but worth confirming the actor is free.

The "everything idle during the stall" is the crucial clue: it points at a **suspended
continuation that isn't being resumed** (a hang/priority-inversion in the async graph), not a
busy loop.

## Relevant code

- `Sources/parrot/App/DictationEngine.swift` — `transcribeAndInject(_:)` (the `Task.detached`),
  `handlePress`/`handleRelease`, `startCapture`, `warmUpModel`, `log`.
- `Sources/parrot/Transcription/WhisperKitTranscriber.swift` — `actor`; `warmUp()` (loads model
  + primes with `PrimingAudio.samples`), `transcribe(_:)`.
- `Sources/parrot/Transcription/PrimingAudio.swift` — ~5s of synthesized speech (16 kHz mono
  Int16 PCM, base64) used to warm the ANE decoder at launch. Generated with `say` + `afconvert`.
- `Sources/parrot/App/ModelManager.swift` — `checkForUpdates()` (HF network on launch).
- `Sources/parrot/App/UpdateChecker.swift` — `check()` (appcast network on launch) + the pill.
- Overlay processing glyph is `progress.indicator` driven by `TimelineView(.animation)` while
  transcribing — `Sources/parrot/UI/RecordingOverlay.swift` (`OverlayEmoji`). Consider whether the
  transcribing-state `TimelineView(.animation)` interacts badly; try disabling it as a test.

## Suggested next steps

1. **Re-instrument** (see Debug tooling) and, during a live stall, capture the transcriber
   actor's stack specifically — is it inside a CoreML/ANE `predict`/continuation wait?
2. Add a timing log **inside `WhisperKitTranscriber.transcribe`** at entry, so you can tell
   whether the delay is *before* the actor method runs (scheduling) or *inside* it (ANE wait).
3. Temporarily **disable the on-launch update checks** (`UpdateChecker.start()` /
   `models.checkForUpdates()`) and see if the stall disappears — cheap way to rule out pool
   starvation from network.
4. Temporarily **remove the launch prime** and the transcribing-state `TimelineView(.animation)`
   independently to bisect.
5. Consider giving WhisperKit its own non-actor serial execution or confirming there's only ever
   one in-flight `transcribe` at a time; check WhisperKit version (2.9.x resolved) for known ANE
   concurrency issues.
6. Try `spindump <pid>` during a stall (richer than `sample` for blocked/waiting stacks and
   shows what each thread is blocked on / the dispatch/async wait chains).

## Debug tooling (removed from the tree; re-add as needed)

- Timing logs used `self.log(...)` in `DictationEngine` around: `handlePress` (▸ press),
  `handleRelease` (◂ release dwell + audio seconds), `transcribeAndInject` (audio seconds),
  and the transcribe (`⏱ transcribe X (release→done Y)`), plus `⏱ capture.start` and `⏱ prime`
  in `WhisperKitTranscriber`.
- To capture logs regardless of launch method (Finder/Dock don't capture stderr), `log()` was
  temporarily made to also append to `/tmp/ama-debug.log`.
- Live sampling while stuck: `sample <pid> 4 -file /tmp/stuck.txt`. Look for threads NOT in
  `semaphore/mach_msg/wait/ReceiveNextEvent`. In every stall so far, all were waiting.

## Build / run notes

- Dev build + Developer ID sign (keeps TCC grants): `make sign` then `open build/Ama.app`.
- Run the raw binary to capture stderr: `./build/Ama.app/Contents/MacOS/ama > /tmp/log 2>&1 &`.
- Fixes committed this session also include: real-speech priming, overlay dark-circle backing
  (`Color.black.opacity(0.75)`), Home status mic uses the Settings symbol color, and the Home
  status icon shows the chosen listening glyph while recording.
