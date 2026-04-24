# PTT Whisper Recognizer — Design Spec

**Date:** 2026-04-24
**Branch:** eb-branch
**Status:** Spec — implementation plan to follow
**Builds on:** [2026-04-23 PTT reliability (C-scope)](2026-04-23-ptt-reliability-design.md)
**Wishlist entry:** `docs/superpowers/wishlist.md` §0b (D-scope)

## Goal

Replace the iPhone on-device `SFSpeechRecognizer` with local Whisper running on the paired Mac as the default PTT recognizer. Keep iPhone on-device SFSpeech as an automatic fallback when the Mac is unavailable. Ship the smallest slice that delivers the quality win: no Settings picker, no per-source diagnostics, no vocab editor in this iteration.

## Non-Goals (v1)

- Settings picker for recognizer source (iPhone / Mac Whisper / Mac Apple Speech).
- Settings model-size picker (tiny / base / small / medium / large).
- Per-source diagnostics UI.
- Vocab editor UI.
- Cloud Whisper / OpenAI / Deepgram.
- Mid-session recognizer cross-over (if WS drops mid-press, session ends with a toast — no attempt to salvage via iPhone on-device).
- Mac Apple Speech (server-class, no `requiresOnDeviceRecognition`) as a second option — deferred until picker ships.

## Fixed Decisions

| Fork | Decision |
|------|----------|
| Scope | Recognizer swap only, no picker, auto-fallback |
| Transport | Raw PCM, 100 ms frames, 16 kHz mono int16, over existing Bonjour WebSocket |
| Runtime | WhisperKit Swift package (Argmax) on Mac |
| Partials | Final-only on PTT stop — no streaming partials |
| Fallback | WS-connected state at PTT-start picks path; mid-session drop surfaces an error toast |
| Model | `openai_whisper-base` (~150 MB), auto-downloaded by WhisperKit on first Mac launch |
| PTT semantics | Toggle (tap-to-start, tap-to-stop). Unchanged from C-scope. |

## Architecture

```
iPhone PTT toggle start
  → HardwareButtonHandler.onPTTStart
    → SpeechService.startRecording
      ├── WS up AND whisperStatus==.ready?
      │     yes → RemoteSpeechSession (new)
      │            → WhisperAudioSender (new)
      │              → WebSocketClient (existing)
      │                                    → Mac WebSocketServer (existing)
      │                                      → WhisperDictationService (new)
      │                                        ↳ buffer PCM per sessionId
      │                                        ↳ on isFinal=true → WhisperKit.transcribe
      │                                        ↳ emits TranscriptResultMessage
      │                                    ← TranscriptResultMessage
      │            → SpeechService stopCompletion fires
      │            → QuipApp sends SendTextMessage
      └── no  → existing local SFSpeech path (unchanged)
```

### Invariants

- Every PTT session gets a UUID minted iPhone-side at start. Every `AudioChunkMessage` and `TranscriptResultMessage` carries it. Callbacks whose session id doesn't match the current `activeSessionToken` are dropped — same pattern as commit `8c63cd1`.
- Local SFSpeech and remote Whisper paths are mutually exclusive per press. No parallel recognition.
- `SpeechService.transcribedText` and `stopRecording(completion:)` public API unchanged. UI code (`QuipApp`) sees a single façade and doesn't care which recognizer ran.

## Components

### New (Shared)

`Shared/MessageProtocol.swift` — three new cases:

- `AudioChunkMessage`
  - `sessionId: UUID` — identifies the PTT press.
  - `seq: Int` — monotonic per session; diagnostics + future out-of-order handling.
  - `pcm: Data` — int16 mono 16 kHz LE, nominally 100 ms (3200 bytes). Final frame may be shorter.
  - `isFinal: Bool` — `true` on the last frame of a session; triggers Mac-side transcription.
- `TranscriptResultMessage`
  - `sessionId: UUID`
  - `text: String` — final transcript, empty on error.
  - `error: String?` — human-readable, nil on success.
- `WhisperStatusMessage`
  - `state: WhisperStatus` — enum `preparing | downloading(Double) | ready | failed(String)`. Broadcast by Mac on state changes.

### New (iPhone, `QuipiOS/Services/`)

- **`RemoteSpeechSession.swift`** — session orchestrator.
  - Owns `sessionId`, holds a `WhisperAudioSender`, tracks whether the final chunk has been sent.
  - Exposes `start()`, `stop(completion:)` mirroring `SpeechService`'s existing stop-completion contract.
  - Registers with `WebSocketClient` for `TranscriptResultMessage` routed by its `sessionId`; passes text to the completion.
  - Handles 3 s safety timeout (same as today) if no result arrives.

- **`WhisperAudioSender.swift`** — PCM chunker.
  - Taps `AudioWorker`'s existing engine tap (or installs a sibling tap if simpler) — do not duplicate mic setup.
  - Converts incoming `AVAudioPCMBuffer` (device native format) to 16 kHz mono int16 via `AVAudioConverter`. Accumulates into a 100 ms ring. On full, emits `AudioChunkMessage(isFinal: false)`.
  - On `stop()`, flushes the pending partial frame with `isFinal: true` even if shorter than 100 ms.

### Modified (iPhone)

- **`SpeechService.swift`** — `startRecording` branches at the top:
  - If `webSocket.isConnected && webSocket.whisperStatus == .ready` → create `RemoteSpeechSession`, store it, wire its `onFinal` into the existing `pendingStopCompletion` plumbing.
  - Else → existing `worker.start` path, byte-for-byte unchanged.
  - `stopRecording(completion:)` routes to whichever session type is active. Existing 3 s safety timeout covers both paths.
  - The existing `activeSessionToken: UUID` guard extends to the remote session: the session's UUID is also the `activeSessionToken`.

- **`WebSocketClient.swift`**
  - Decode `TranscriptResultMessage`, route to registered `RemoteSpeechSession` by `sessionId`.
  - Decode `WhisperStatusMessage`, update published `whisperStatus` property (new).
  - Extend `maximumMessageSize` check is unnecessary — per-frame audio (3200 bytes) is nowhere near the 16 MiB cap.

### New (Mac, `QuipMac/Services/`)

- **`WhisperDictationService.swift`**
  - Holds a `WhisperKit` instance (lazy-init on first `ready` broadcast).
  - Buffers incoming frames: `[UUID: AudioSessionBuffer]` where `AudioSessionBuffer` stores `[Float]` samples (converted from int16 on decode) plus the sequence log.
  - On `isFinal=true`: calls `whisperKit.transcribe(audioArray: samples)`, awaits result, sends `TranscriptResultMessage`. Cleans up buffer.
  - Stale sessions: if no chunk for a `sessionId` in 30 s, buffer is discarded. Matches the iPhone-side stuck-press watchdog window.
  - Model lifecycle: on Mac app launch, kicks off `WhisperKit()` init on a background task. Broadcasts `WhisperStatusMessage(.downloading(progress))` via the server if the init pulls the model. On success → `.ready`. On failure → `.failed(message)` with retry on next launch only.

### Modified (Mac)

- **`WebSocketServer.swift`** — decode `AudioChunkMessage`, hand to `WhisperDictationService`. Route new outbound messages through existing send queue.
- **`QuipMacApp.swift`** — instantiate `WhisperDictationService` at startup; broadcast current `WhisperStatusMessage` on every new iPhone connection so a reconnecting phone learns state.
- **`Package.swift` / project SPM config** — add `argmaxinc/WhisperKit` dependency pinned to a recent minor (pick at implementation time; record in plan).

## Data Flow — Happy Path

```
t=0     iPhone: vol-down tap.
        HardwareButtonHandler.onPTTStart → SpeechService.startRecording.
        WS up, whisperStatus==.ready → RemoteSpeechSession(UUID) created.
        WhisperAudioSender.start — taps AudioWorker engine, begins chunking.

t=100ms AudioChunkMessage(seq=0, isFinal=false, ~3200 bytes) → WS → Mac.
        Mac: WhisperDictationService buffers samples under sessionId.

… frames every 100 ms.

t=8000  iPhone: vol-down tap (toggle stop).
        HardwareButtonHandler.onPTTStop → SpeechService.stopRecording(completion:).
        WhisperAudioSender flushes pending partial frame with isFinal=true.
        SpeechService awaits TranscriptResultMessage (3 s safety timeout).

t=8001  Mac: isFinal=true received.
        WhisperKit.transcribe(audioArray: accumulatedFloats). ~300–600 ms on M2, base model, 8 s audio.

t=8500  Mac sends TranscriptResultMessage(sessionId, text, nil).

t=8510  iPhone: WebSocketClient routes to RemoteSpeechSession.
        SpeechService.pendingStopCompletion fires with final text.
        QuipApp sends SendTextMessage.
```

## Error Handling

| Failure | Detection | Behavior |
|---------|-----------|----------|
| WS not connected at PTT-start | `WebSocketClient.isConnected == false` | Silent fallback to local SFSpeech |
| Whisper model not ready | `whisperStatus != .ready` | Silent fallback to local SFSpeech |
| Model download fails | `WhisperKit` init throws | Broadcast `WhisperStatusMessage(.failed(…))`; iPhone falls back indefinitely; Mac retries on next launch only |
| WS drops mid-session | Existing keepalive / send error | Stop completion fires with empty text; `ErrorMessage` toast "Mic dropped — reconnect" |
| Whisper inference throws | Caught in `WhisperDictationService` | `TranscriptResultMessage(text:"", error: message)`; iPhone shows toast |
| 3 s Mac reply timeout | Existing safety timeout in `SpeechService` | Stop completion fires empty; no toast (matches shipped behavior on local path) |
| PCM encoder throws | Caught at `WhisperAudioSender` | Session aborted; toast; no mid-session fallback attempt |
| Mac app predates protocol | Mac ignores unknown message type | iPhone's 3 s safety timeout fires → empty completion |
| Per-chunk loss | Not detected (best-effort) | Whisper tolerates short drops; accept degraded result |

### Explicit non-handled failures (v1)

- Mid-session recognizer cross-over.
- Per-chunk retransmission.
- Out-of-order chunk handling (`seq` field retained for diagnostics + future work).

## Testing

### iPhone unit (`QuipiOSTests/`)

- `RemoteSpeechSessionTests` — fake `WebSocketClient`; assert (a) chunks emitted in seq order with consistent sessionId, (b) final marker sent on stop, (c) stop completion fires on result, (d) stop completion fires on 3 s safety timeout, (e) stale sessionId results ignored.
- `WhisperAudioSenderTests` — feed a known 16 kHz mono PCM buffer in the device native format; assert frame size, int16 endianness, resample correctness, tail-flush with isFinal=true.
- `SpeechServicePathSelectionTests` — `startRecording` picks remote when `isConnected && whisperStatus==.ready`; local otherwise. Covers four combinations.

### Mac unit (`QuipMacTests/`)

- `WhisperDictationServiceTests` — fake `WhisperKit` adapter (protocol-wrapped); assert (a) per-session buffering isolation, (b) stale session discard at 30 s, (c) final triggers transcribe, (d) `TranscriptResultMessage` emitted with correct sessionId, (e) inference throw path emits error field.
- `MessageProtocolTests` — round-trip encode/decode `AudioChunkMessage`, `TranscriptResultMessage`, `WhisperStatusMessage`. Same pattern as the existing 40 round-trip tests.

### Integration (manual acceptance, documented in PR description)

1. **Happy path.** 5 s dictation, WS up, base model ready. Final transcript matches spoken words. Known technical vocab words ("SwiftUI", "WebSocket", "Xcode", "monospace") survive where they currently garble.
2. **Fallback at start.** Disable Mac. Start PTT on iPhone. Local SFSpeech path runs; transcript arrives as today.
3. **Mid-session drop.** Start PTT, kill Mac mid-press. Toast appears. `isRecording` clears. No ghost recording on next press.
4. **First-run model download.** Fresh Mac install. First press after launch goes to local SFSpeech. Progress visible in logs. After download completes, next press uses Whisper.
5. **Stuck session on Mac.** Send chunks, never send isFinal. 30 s later, Mac-side buffer is gone. (Log check, not UI check.)

No UI test additions — no UI changed in v1.

## Rollout / Migration

- Code ships on `eb-branch`. No flag; behavior auto-switches on build.
- Mac app update required — both sides must ship together. Version gate is implicit (unknown message type = graceful fallback).
- iPhone ships unchanged to the user if Mac not updated: `whisperStatus` never arrives as `.ready`, so local path always wins.

## Future Work (tracked on wishlist §0b, not in this spec)

- Settings picker: iPhone on-device / Mac Whisper local / Mac Apple Speech.
- Model-size picker in Settings: tiny / base / small / medium / large — user requested "most performant options available."
- Per-source diagnostics panel (last N transcripts, confidence, duration).
- Vocab editor — analog to current bundled `dictation-vocab.txt`, but live-editable. WhisperKit supports `promptTokens` for vocab biasing.
- Cross-platform parity: QuipLinux / QuipAndroid currently have no PTT.

## Files Touched (preliminary list for plan)

**New**
- `Shared/` — 3 new message type files or inline in `MessageProtocol.swift`.
- `QuipiOS/Services/RemoteSpeechSession.swift`
- `QuipiOS/Services/WhisperAudioSender.swift`
- `QuipiOSTests/RemoteSpeechSessionTests.swift`
- `QuipiOSTests/WhisperAudioSenderTests.swift`
- `QuipiOSTests/SpeechServicePathSelectionTests.swift`
- `QuipMac/Services/WhisperDictationService.swift`
- `QuipMacTests/WhisperDictationServiceTests.swift`

**Modified**
- `Shared/MessageProtocol.swift`
- `QuipiOS/Services/SpeechService.swift`
- `QuipiOS/Services/WebSocketClient.swift`
- `QuipMac/Services/WebSocketServer.swift`
- `QuipMac/QuipMacApp.swift`
- SPM / project config — add WhisperKit dependency.

## Risk Register

- **WhisperKit model download on first run.** 150 MB over HuggingFace. User needs internet on Mac once. Acceptable — documented in acceptance test #4.
- **Whisper inference latency.** Base model on M2, 8 s audio → ~300–600 ms. Toggle-UI users don't see partials anyway; this lands within the 3 s safety timeout with margin.
- **WebSocket head-of-line blocking.** Image uploads (up to 16 MiB) could delay audio frames if a user uploads a photo mid-dictation. Mitigation deferred — real prod traffic will tell us if it matters; Opus/codec path remains a pure upgrade later.
- **WhisperKit API churn.** Young project. Pin to a specific minor. If API changes under us, the wrapper is ~50 lines — cheap to port.
- **Mac app rebuild cost.** Per project memory, each Mac rebuild can require re-granting Accessibility + Screen Recording TCC. Implementation plan must batch the Mac-side work.
