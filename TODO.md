# Quip — Improvement Backlog

## UX / Features

- [x] ~~Android: Show Vosk model download progress (currently just "Speech model not ready" with no indicator during ~45MB download)~~ — Also added Android SpeechRecognizer (Google) as primary engine; Vosk is now a fallback with download progress tracking
- [ ] Configurable terminal output limit (hardcoded to 200 lines; at minimum show "truncated" indicator)
- [x] ~~Faster terminal state detection (2s polling interval is noticeable; consider kqueue or shorter interval)~~ — Hybrid kqueue DispatchSource + 0.5s polling; process exit events trigger instant re-detection
- [x] ~~Haptic feedback on PTT press/release for tactile confirmation~~ — Medium impact on start, double light tap on stop (iOS + Android)
- [ ] Speech language selection (both platforms hardcode locale)
- [ ] Dark/light theme or system-following appearance
- [ ] Keyboard input fallback for typing prompts when voice isn't practical

## Reliability / Robustness

- [x] ~~Android: Refactor recording flow to StateFlow-based state machine (nested Handler.postDelayed chains in MainActivity are fragile)~~ — Sealed class RecordingState (Idle/Recording/WaitingForResult) with coroutine-based stop flow in MainViewModel
- [x] ~~Android: Cancel Vosk model download on app destroy (thread keeps running if app killed during download)~~ — Download thread stored and interrupted on destroy, with InterruptedException checks in download loop
- [x] ~~Android: Replace NSD resolver LinkedList+synchronized+volatile with Kotlin Channel/coroutines~~ — Channel(UNLIMITED) with suspendCoroutine bridge for serial NSD resolution
- [ ] iOS: Tune volume button phantom-event suppression (0.5s hardcoded window may need per-device adjustment)
- [ ] Recent connections: Clarify pinning/trimming logic (code says "max 10" but implements "max 8 unpinned + unlimited pinned")

## Code Quality / Architecture

- [ ] Normalize speech recording timing across platforms (iOS: 0.8s delay, Android: 800ms+1000ms nested)
- [x] ~~Extract Android connection UI into separate Compose components (MainActivity.kt is 419 LOC mixing UI and logic)~~ — MainViewModel holds all state and business logic; MainActivity reduced to ~120 LOC Activity shell
- [ ] Add standalone protocol spec for MessageProtocol (currently only exists as Swift; helps independent Android/Linux work)
- [ ] iOS: Simplify orientation lock to use requestGeometryUpdate only (remove manual UIDevice.setValue workarounds)

## Testing

- [ ] Add unit tests for message encoding/decoding on both platforms
- [ ] Stress-test rapid PTT toggling to surface race conditions in debouncing/recording lifecycle

## Nice-to-Haves

- [ ] Whisper-based STT option for Android (better transcription quality than Vosk)
- [ ] Android: Persistent notification showing connection status when backgrounded
