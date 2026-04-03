# Quip — Improvement Backlog

## UX / Features

- [x] ~~Android: Show Vosk model download progress (currently just "Speech model not ready" with no indicator during ~45MB download)~~ — Also added Android SpeechRecognizer (Google) as primary engine; Vosk is now a fallback with download progress tracking
- [ ] Configurable terminal output limit (hardcoded to 200 lines; at minimum show "truncated" indicator)
- [x] ~~Faster terminal state detection (2s polling interval is noticeable; consider kqueue or shorter interval)~~ — Hybrid kqueue DispatchSource + 0.5s polling; process exit events trigger instant re-detection
- [x] ~~Haptic feedback on PTT press/release for tactile confirmation~~ — Medium impact on start, double light tap on stop (iOS + Android)
- [ ] Speech language selection (both platforms hardcode locale)
- [ ] Dark/light theme or system-following appearance
- [x] ~~Keyboard input fallback for typing prompts when voice isn't practical~~ — Keyboard icon in bottom bar (iOS + Android) opens inline text field; submit sends SendTextMessage to selected window with pressReturn

## Reliability / Robustness

- [x] ~~Android: Refactor recording flow to StateFlow-based state machine (nested Handler.postDelayed chains in MainActivity are fragile)~~ — Sealed class RecordingState (Idle/Recording/WaitingForResult) with coroutine-based stop flow in MainViewModel
- [x] ~~Android: Cancel Vosk model download on app destroy (thread keeps running if app killed during download)~~ — Download thread stored and interrupted on destroy, with InterruptedException checks in download loop
- [x] ~~Android: Replace NSD resolver LinkedList+synchronized+volatile with Kotlin Channel/coroutines~~ — Channel(UNLIMITED) with suspendCoroutine bridge for serial NSD resolution
- [x] ~~iOS: Tune volume button phantom-event suppression (0.5s hardcoded window may need per-device adjustment)~~ — Context-aware named constants: 0.3s for self-triggered KVO echoes (volume restore), 0.4s for PTT transitions (audio session reconfig)
- [x] ~~Recent connections: Clarify pinning/trimming logic (code says "max 10" but implements "max 8 unpinned + unlimited pinned")~~ — Both platforms now use consistent max 10 total: all pinned kept + newest unpinned to fill remaining slots

## Code Quality / Architecture

- [x] ~~Normalize speech recording timing across platforms (iOS: 0.8s delay, Android: 800ms+1000ms nested)~~ — Both platforms now use 2.5s post-release recording window (up from 0.8s) for conversational flow; Android result timeout normalized to 1.5s
- [x] ~~Extract Android connection UI into separate Compose components (MainActivity.kt is 419 LOC mixing UI and logic)~~ — MainViewModel holds all state and business logic; MainActivity reduced to ~120 LOC Activity shell
- [x] ~~Add standalone protocol spec for MessageProtocol (currently only exists as Swift; helps independent Android/Linux work)~~ — docs/protocol.md with all message types, fields, actions, and JSON examples
- [x] ~~iOS: Simplify orientation lock to use requestGeometryUpdate only (remove manual UIDevice.setValue workarounds)~~ — Removed UIDevice.setValue private API call; on-connect flow now uses requestGeometryUpdate + attemptRotationToDeviceOrientation only

## Testing

- [x] ~~Add unit tests for message encoding/decoding on both platforms~~ — Android: ProtocolTest.kt with Gson round-trip, edge case, and envelope tests; iOS: MessageProtocolTests.swift with XCTest encode/decode/round-trip coverage
- [x] ~~Stress-test rapid PTT toggling to surface race conditions in debouncing/recording lifecycle~~ — Android: PTTStressTest.kt + RecordingStateMachineTest.kt covering double-start/stop guards, debounce suppression, concurrent send, window ID preservation; iOS: PTTStressTests.swift covering state transitions, debounce, and HardwareButtonHandler consistency

## Nice-to-Haves

- [x] ~~Whisper-based STT option for Android (better transcription quality than Vosk)~~ — WhisperEngine with AudioRecord PCM capture, whisper.cpp JNI bridge, model auto-download (ggml-tiny.en), periodic partial transcription; SpeechService priority: Whisper > Android > Vosk
- [x] ~~Android: Persistent notification showing connection status when backgrounded~~ — ConnectionService foreground service with notification channel, auto-start on connect, auto-stop on disconnect, notification permission for Android 13+
