# PTT Reliability — Timing & Hygiene Fixes

**Date:** 2026-04-23
**Scope:** `C` from brainstorming. Timing + button-hygiene fixes on the current on-device `SFSpeechRecognizer` path. **No** recognizer swap, **no** settings picker, **no** Whisper — those are a separate, larger follow-up (`D`) captured in `docs/superpowers/wishlist.md`.

## Problem

Push-to-talk on iPhone is unreliable. Observed failure modes (all confirmed by the user, live — the user's own dictated prompt demonstrating the bug showed missing punctuation, substitution errors, and run-together sentences):

1. **Start-clip** — first word after pressing volume-down is dropped.
2. **End-clip** — last word before releasing volume-down is dropped.
3. **Seam-drop** — at the ~1-minute `SFSpeechRecognizer` session ceiling, a word is lost when the current `AudioWorker` stitches `accumulatedText` to the next task's output with a blind `+ " " +` concat.
4. **Button stuck / phantom** — `isPTTActive` can remain `true` across `stopMonitoring`, background transitions, audio route changes. Phantom volume KVO can mis-fire.
5. **Poor technical vocab** — `requiresOnDeviceRecognition = true` has a weak dictionary and no punctuation. "Monospace" → "monotype", "ABC" → "ABNC", no periods/commas.

Root causes — 5 is fundamental to the on-device model and is deferred to `D`. 1–4 are fixable inside the current pipeline.

## Non-Goals

- **No recognizer swap.** Mac-Whisper, Mac-Apple-Speech, iPhone-server dictation are all deferred to `D`.
- **No settings picker for recognizer source.** Also `D`.
- **No protocol / wire-format changes.** iPhone↔Mac message types stay as-is.
- **No Mac changes.** This is iOS-only.
- **No SwiftUI view changes.** Existing overlays, indicators, Live Activity paths untouched.

## Architecture

Files touched (all in `QuipiOS/`):

- `Services/HardwareButtonHandler.swift` — button state hygiene (Iter 1).
- `Services/SpeechService.swift` + inner `AudioWorker` — recognizer lifecycle: pre-arm ring buffer, trailing flush, seam stitching, contextual vocab (Iters 2–5).
- `Tests/PTTStressTests.swift` — add cases for every new behavior.
- `Tests/Fixtures/` — new directory, small WAV clips with known transcripts for deterministic tests.
- `Resources/dictation-vocab.txt` — new, seed technical vocab list (Iter 5).

Unchanged: `Shared/PTTWindowTracker.swift`, all Mac code, protocol, all views.

### Core shift: `AudioWorker` becomes long-lived (delivered in Iter 3)

Today: `AudioWorker.start()` boots the `AVAudioEngine` on PTT press, installs tap, creates request + task. `stop()` tears all of it down. Result: every press has cold-start latency → first word lost.

Target state after Iter 3: engine + tap are armed once when window count > 0 (same trigger as `HardwareButtonHandler.startMonitoring`). Buffers continuously flow into a **500ms audio ring buffer**. On PTT press, a new `SFSpeechAudioBufferRecognitionRequest` is created; the ring buffer is replayed into it, then live buffers resume. On release, the tap keeps feeding for a **300ms trailing window** before `endAudio()` + `finish()`. Engine does **not** stop between presses.

Disarm conditions: `stopMonitoring` (no windows), `AVAudioSession.interruptionNotification .began`, app entering background. Rearm: on corresponding `.ended` / `didBecomeActive`. Ring buffer is wiped on disarm.

**Iter 1 and Iter 2 ship against the current cold-start engine model.** Iter 3 is the step that introduces `arm()` / `disarm()` and the ring buffer. Iter 2's trailing-flush in that phase still tears the engine down — it just does so 300ms late, after the flush window. When Iter 3 lands, `stop()` stops only the recognition task; the tap and engine remain running.

Battery impact: mic tap with no recognizer attached is a small fixed cost on M-class chips; no ML inference, no network. Acceptable pre-ship; revisit only if field reports show drain.

## Iterations

Each iteration is its own commit, its own PR-sized unit, independently verifiable on device. Ship order is the listed order; next iteration must not start until prior is green in `QuipiOSTests` and confirmed on hardware.

### Iteration 1 — Button hygiene

**User story:** *As a user, after I swipe Quip out of the app switcher or background it and reopen, PTT works on the very next volume-down press — not stuck, not dead.*

**Changes:**
- `HardwareButtonHandler.stopMonitoring()` sets `isPTTActive = false`.
- `HardwareButtonHandler.resumeAfterBackground()` sets `isPTTActive = false`.
- Observe `AVAudioSession.routeChangeNotification`. If route changes while `isPTTActive == true`, fire `onPTTStop`, reset `isPTTActive`, extend `suppressUntil` by `pttTransitionSuppression`.
- **Watchdog:** schedule a 5-second `DispatchWorkItem` when `isPTTActive` flips true. Cancel on normal stop. If it fires, treat as stuck: call `onPTTStop`, reset `isPTTActive`, log via `NSLog` with tag `[Quip][PTT] watchdog fired`.

**Edge cases:**
- Route change mid-recording (AirPods in/out): force-stop, deliver whatever transcript exists.
- Watchdog on legit long press: 5s is well above any real human press; jammed state is the correct interpretation.
- KVO suppression overlap with watchdog: watchdog wins.

### Iteration 2 — Trailing flush (end-clip fix)

**User story:** *When I release the volume button, the last word I was speaking makes it into the prompt.*

**Changes:**
- In `AudioWorker.stop()`: keep `isStopping = true` semantics, but do not immediately remove tap or call `finish()`. Instead:
  1. Call `recognitionRequest?.endAudio()`.
  2. Schedule a 300ms `queue.asyncAfter` block that: removes tap, stops engine, calls `recognitionTask?.finish()`, clears `recognitionTask` / `recognitionRequest`. (Iter 3 later changes this to leave tap + engine running and only stop the recognition task.)
  3. Arm a 2-second hard cap timer: if `isFinal` callback has not fired by then, call `recognitionTask?.cancel()`, deliver the current `accumulatedText + partial` to the callback with `isFinal = true`.
- Guard against double-stop: if `stop()` called while already flushing, no-op.

**Edge cases:**
- User starts new press during 300ms flush: `startRecording` queues and runs after flush completes. No overlap.
- App backgrounded during flush: wrap the flush in `UIApplication.beginBackgroundTask`, same pattern as existing TTS code.
- 2-second `finish()` timeout: accept whatever partial exists, log `[Quip][PTT] flush timeout`.

### Iteration 3 — Pre-arm ring buffer (start-clip fix)

**User story:** *The first word I speak right as I press the volume button shows up in the prompt.*

**Changes:**
- `AudioWorker.arm()` — idempotent. Configures `AVAudioSession` (no-op if already active), installs input-node tap, starts engine if not running. Begins writing PCM buffers into a `RingBuffer` (new simple struct holding an array of `(buffer: AVAudioPCMBuffer, timestamp: Date)`, capped at 500ms of audio).
- `AudioWorker.disarm()` — removes tap, stops engine, clears ring buffer.
- `HardwareButtonHandler.startMonitoring` → calls `arm()` via `SpeechService` (new passthrough).
- `HardwareButtonHandler.stopMonitoring` → calls `disarm()`.
- `AVAudioSession.interruptionNotification`: `.began` → `disarm()`, `.ended` with `.shouldResume` option → `arm()`.
- `AudioWorker.start()` → creates new request + task, replays ring-buffer entries whose timestamp is within 500ms of `Date()`, then continues appending live buffers from the (always-installed) tap.

**Edge cases:**
- Audio session grabbed by phone call / Siri: interruption observer handles it.
- Engine fails to start on arm: log, leave ring empty. Next `start()` falls back to cold-start behavior (same as today — start-clip reappears but pipeline works).
- Stale ring buffer after long idle: filter on timestamp at replay.

### Iteration 4 — Seam stitching (1-minute boundary fix)

**User story:** *If I hold PTT and talk for more than a minute, no word is eaten at the recognizer's internal restart point.*

**Changes:**
- In `beginRecognitionTask` when `isFinal` fires and `isStopping == false`:
  1. Do **not** null out `recognitionTask` / `recognitionRequest` synchronously.
  2. Spin up a new task + request; tap starts forwarding buffers to the new request (tap closure reads `self?.recognitionRequest` which now points at the new one — today's code already does this, keep it).
  3. Wait for the first partial from the new task.
  4. Compute overlap: take last 3 tokens of old task's final text, first 3 tokens of new task's first partial. If suffix-of-old equals prefix-of-new by case-insensitive exact match, strip the overlap from new before stitching. Else, concat with single space (today's fallback).
  5. Commit stitched text to `accumulatedText`, retire old task.
- Token split: simple whitespace split. Dedup is word-level, not char-level — cheap, good enough for English short overlaps.

**Edge cases:**
- New task errors out before first partial: discard, keep old final as answer, cold-restart next buffer-in.
- No overlap found: fall back to concat + space, log `[Quip][PTT] seam no-overlap`.
- User releases during seam: finish both tasks, take union, apply same dedup.

### Iteration 5 — Contextual vocab

**User story:** *Technical words I use often — SwiftUI, Xcode, monospace, WebSocket, Claude, etc. — transcribe correctly.*

**Changes:**
- New file: `QuipiOS/Resources/dictation-vocab.txt`, one term per line, ≤100 lines. Seed contents (initial list):
  ```
  SwiftUI
  Xcode
  WebSocket
  Claude
  Quip
  monospace
  iOS
  macOS
  TestFlight
  GitHub
  ```
  (Expanded at commit time — this list is illustrative.)
- `AudioWorker.beginRecognitionTask` loads the file once (cached), sets `request.contextualStrings = cached`.
- Missing/empty file: `contextualStrings` stays unset, identical to current behavior.

**Edge cases:**
- File missing: no crash, no contextualStrings set, log once.
- File >100 lines: cap at first 100, log.

## Error Handling — Cross-Cutting

- **Speech auth revoked mid-session:** existing guard `guard isAuthorized` in `startRecording` handles. Callback propagates `finished = true`.
- **iOS force-quit during PTT:** no state to persist. Clean start on relaunch.
- **WebSocket disconnect during recording:** orthogonal to PTT; speech recording completes locally, send-on-release path already handles reconnect.

## Testing

### Unit tests — `QuipiOS/Tests/PTTStressTests.swift`

Extend existing 11 cases with:

| Iter | Test method |
|------|-------------|
| 1 | `test_stopMonitoring_resets_isPTTActive` |
| 1 | `test_routeChange_during_press_forces_stop` |
| 1 | `test_stuck_press_watchdog_fires_at_5s` |
| 1 | `test_resumeAfterBackground_clears_pttActive` |
| 2 | `test_trailing_flush_captures_last_word` |
| 2 | `test_double_stop_is_idempotent` |
| 2 | `test_flush_timeout_at_2s_returns_partial` |
| 3 | `test_ring_buffer_replays_on_start` |
| 3 | `test_interruption_disarms_and_rearms` |
| 3 | `test_ring_buffer_drops_stale_buffers` |
| 4 | `test_seam_dedups_overlap` |
| 4 | `test_seam_no_overlap_falls_back_to_concat` |
| 4 | `test_release_during_seam_unions_both_tasks` |
| 5 | `test_contextualStrings_loaded_from_resource` |
| 5 | `test_missing_vocab_file_does_not_crash` |

### Fixtures — `QuipiOS/Tests/Fixtures/`

~15 small WAV clips committed to repo. Generated once (e.g., via macOS `say ... -o file.aiff` + `afconvert`) and checked in. Known-transcript, deterministic. Examples: `hello_world.wav`, `swiftui_xcode_monospace.wav`, `70_second_monologue.wav`, `silence_500ms.wav`.

### Manual acceptance — device only

No XCUITest — volume-button + speech recognizer don't simulate reliably in UI tests. Each iteration's PR includes a one-paragraph on-device acceptance script in the commit body:

- **Iter 1:** Background Quip (swipe up halfway, don't kill). Reopen. Press volume-down. Expected: recording starts within 200ms, overlay shows.
- **Iter 2:** Hold volume-down, say "hello world", release immediately after saying "world". Expected: prompt contains "hello world".
- **Iter 3:** Hold volume-down and begin speaking "hello" at the instant of press. Expected: prompt contains "hello".
- **Iter 4:** Hold PTT, monologue for 70 seconds (read a paragraph). Expected: no word missing at the ~60-second mark.
- **Iter 5:** Say "SwiftUI Xcode monospace WebSocket". Expected: all four transcribed exactly.

### CI / regression

Runs on existing `QuipiOSTests` target via `xcodebuild test`. No new infra. Each iteration's PR must show:
- All 51 existing tests green (40 `MessageProtocolTests` + 11 prior `PTTStressTests`).
- New cases green.
- Zero regression in `QuipMacTests` (40 `MessageProtocolTests`).

If an existing test regresses → revert, don't patch.

## Rollout

- One commit per iteration, one PR per commit.
- No feature flag — the changes are bug fixes on an existing feature, user-visible improvements at each step. Staged rollout via iteration-order instead of flags.
- No Mac rebuild required (per user's standing preference — Mac TCC grants are fragile).
- TestFlight is not required for each iteration; `devicectl install` → force-quit → relaunch is the normal dev cycle (per Quip project instructions). User force-quits after install.

## Follow-up (deferred to plan `D`)

Logged in `docs/superpowers/wishlist.md`, not in this spec:

- Recognizer swap: Mac-Whisper local (default, best privacy + vocab, M2 capable), iPhone-on-device (offline fallback), stream iPhone-mic audio to Mac over existing WebSocket.
- Settings picker for recognizer source, vocab file editor, per-source diagnostics.
- Full PTT state machine (`idle → arming → recording → flushing → idle`) if Iter 1–4 fixes prove insufficient in the field.
- Ring-buffer event log for post-mortem (only if failures turn out to be non-reproducible).
