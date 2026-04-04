# Latency Filler Audio — Design

**Date:** 2026-04-04
**Platform:** QuipiOS (iOS first)
**Status:** Approved, ready for implementation planning

## Problem

There is dead air between the moment the user releases PTT and the moment Claude's voice begins playing through the phone's speaker. The delay is caused by the combined latency of STT, network round-trip, model inference, TTS synthesis, and first-chunk playback. On fast responses it's short; on responses that involve tool use or thinking, it can stretch to several seconds. Silence makes the wait feel longer than it is and breaks the illusion of a responsive conversation.

## Goal

Mask the perceived delay by playing short filler audio — both non-verbal ambient sounds and spoken "hold on, let me check" style phrases — from the phone during the gap. The filler must feel like it's coming from the same speaker that's about to reply, start instantly on PTT release, and get out of the way cleanly when the real response begins.

## Non-Goals

- **Not context-aware.** No matching phrases to specific tool calls ("checking the files..." when a Read runs). That would require server-side hints over the WebSocket and is a future enhancement.
- **Not personality-tunable.** One pool of phrases, one voice, no user configuration.
- **iOS only for the first ship.** Android port is a separate future task.
- **No analytics or metrics** on filler effectiveness in v1.

## Architecture

Entirely phone-side. No server changes. The filler engine sits between two existing events in the QuipiOS app:

1. **PTT release** — the user let go of the push-to-talk button.
2. **First real audio chunk arrives** — the first byte of Claude's synthesized response reaches the phone over the WebSocket.

When the engine sees event 1, it begins playing filler. When it sees event 2, it stops (with smart interruption rules).

### Why phone-side, not server-side

The filler's entire purpose is masking latency between PTT release and first audio. If the filler itself had to travel over the WebSocket, it would inherit the same latency we're trying to hide — whenever the network is the bottleneck (which is often), server-generated filler would arrive late too. Phone-side playback from local files is the only way to be truly instant.

The tradeoff is that the phone doesn't know *why* there's a delay (thinking vs. tool use vs. network). That's acceptable for v1. Later, the server can send lightweight status hints over the WebSocket and the phone can pick matching phrases from its local pool — best of both worlds, without rebuilding the architecture.

### Two audio tracks

The filler runs two simultaneous tracks:

1. **Ambient loop** — short non-verbal clips (hmms, breaths, soft keyboard typing) that start the instant PTT releases. Loops or concatenates randomly until either Claude starts talking or the spoken-phrase threshold fires. Mix of Kokoro-generated human sounds ("mm", "hmm", "uh") in Claude's voice and stock keyboard typing samples underneath.

2. **Spoken filler** — Kokoro-synthesized phrases in Claude's voice ("hold on, let me check...", "one sec..."). Fires ~2s after PTT release if Claude still hasn't started, and recurs every ~3-4s while dead air continues.

## Components

Four small units, each with one clear responsibility.

### 1. `FillerAssetLibrary`

Owns the pool of local audio files. Two pools:
- `ambientClips` — short hmms/breaths/typing, ~10-15 files
- `spokenPhrases` — the 25 Kokoro-synthesized phrases

**API:**
- `randomAmbient() -> URL`
- `randomPhrase(category: .initial | .continuation | .error) -> URL`

**Behavior:** anti-repetition — tracks last-played index per pool and rerolls if it picks the same one twice in a row.

**Knows nothing about** playback, timing, or the rest of the app.

### 2. `FillerPlayer`

Owns two `AVAudioPlayer` instances — one for the ambient track, one for the spoken track.

**API:**
- `startAmbient()` — begins looping ambient clips
- `stopAmbient()` — stops the ambient track
- `playPhrase(url: URL)` — plays a single phrase on the spoken track; automatically ducks the ambient track to ~30% volume for the duration, then restores when the phrase finishes
- `stopAll(mode: StopMode)` — stops both tracks with the given stop mode
- `StopMode = .hardCut | .fadeOut`

**Behavior:** handles the smart-cut logic — hard-cuts ambient, fades spoken over ~150ms. Handles ducking of ambient during spoken phrases automatically.

**Knows nothing about** when to do anything. It just does what it's told.

### 3. `FillerController` (the brain)

Subscribes to PTT release and first-real-audio-chunk events from the existing audio pipeline. Runs the timing state machine.

**State:** `currentlyFilling: Bool`, timer handles for the phrase trigger and the 20s error cap.

**API (events in):**
- `onPTTReleased()` — start filler cycle
- `onFirstRealAudioChunk()` — stop filler cycle
- `onPTTPressed()` — reset (user is about to talk again)
- `onAudioSessionInterrupted()` — stop everything, cancel timers

**Behavior:**
- On PTT release: `startAmbient()`, arm 2s timer.
- On 2s timer fire: `playPhrase(.initial)`, arm 3.5s recurrence timer.
- On recurrence timer fire: `playPhrase(.continuation)`, arm next recurrence.
- On 20s hard cap: `playPhrase(.error)`, reset state.
- On first real audio chunk: `stopAll(.fadeOut)` for spoken if mid-phrase, `.hardCut` for ambient.

### 4. `FillerPhraseGenerator` (offline tool, not shipped in app)

A small script (Swift or shell) that hits the Kokoro daemon once, generates the 25 spoken phrases and the Kokoro-voiced ambient clips, and saves them into the QuipiOS app bundle resources. Run manually when we want to refresh the pool. Lives in the repo, not the app.

## Data Flow & Timing

### Fast path (response arrives quickly)

```
t=0ms    PTT release → FillerController.onPTTReleased()
t=0ms    FillerPlayer.startAmbient() → hmm + typing begins
t=0ms    2000ms phrase timer armed
t=400ms  First real audio chunk → FillerController.onFirstRealAudioChunk()
t=400ms  stopAll(.hardCut) on ambient (no spoken playing yet)
t=400ms  Real Claude audio plays
```

### Slow path (thinking / tool use)

```
t=0ms     PTT release → start ambient
t=2000ms  Phrase timer fires → "hold on, let me check..."
          Ambient continues at lower volume underneath
t=3200ms  Phrase finishes. Recurrence timer armed for 3500ms.
t=6700ms  Recurrence fires → "still checking..."
t=8100ms  First real audio chunk → stopAll
          Ambient: hard cut
          Spoken: finish current word (~150-300ms) then fade 150ms
t=8250ms  Real Claude audio plays
```

### Interruption rules (the smart cut)

- **Ambient track:** hard cut, zero fade. It's just noise.
- **Spoken phrase mid-word:** let the current word finish (~150-300ms), then fade out over 150ms.
- **Spoken phrase between words:** fade immediately.
- **Timer pending but nothing playing:** cancel timer, no audio interruption needed.

## Phrase Pool

### 25 spoken phrases, by category

**Quick acknowledgments (`.initial`, short, ~0.5-0.8s):**
1. "Hmm..."
2. "Let's see..."
3. "Okay..."
4. "Right..."
5. "One sec..."

**Short holds (`.initial`, ~1-1.5s):**
6. "Hold on a sec."
7. "Let me check."
8. "Give me a moment."
9. "Let me think."
10. "Bear with me."
11. "Working on it."
12. "Looking into it."

**Longer holds (`.initial`, ~1.5-2.5s):**
13. "Hold on, let me check on that."
14. "Give me just a second here."
15. "Let me take a look at that."
16. "Alright, let me figure this out."
17. "Hmm, let me think about that for a second."

**Continuations (`.continuation`, fired on recurrences):**
18. "Still checking..."
19. "Almost there..."
20. "Just a moment more."
21. "Working on it..."
22. "Still looking."

**Error / give-up (`.error`, fired on 20s hard cap):**
23. "Hmm, something's not quite right. Try again?"
24. "I'm having trouble here, give it another shot."
25. "Something's off — try me again."

**Selection weights for `.initial`:** weighted toward the longer phrases (13-17), since we're already 2s in and a longer phrase buys more time.

### Ambient clips (10-15 files)

- Kokoro-voiced: "mm", "mmhm", "uh", "ah", soft breath in, soft breath out, thoughtful "hmmm", lip-smack click
- Stock typing loops: 3-4 quiet keyboard samples, 1-2 seconds each, for the underneath layer

## Asset Storage

Audio files ship in the app bundle (Xcode resource folder). Regenerated by running `FillerPhraseGenerator` manually when we want to refresh the pool. Estimated bundle size impact: ~2-4 MB.

**Why bundled instead of downloaded-on-first-launch:**
- Zero first-run delay
- Works offline
- Atomic with app version — no split-brain between app code expecting new phrases and old phrases still cached

## Error Handling & Edge Cases

- **Missing asset file** (shouldn't happen but defensive): log, skip that clip, try another from the pool. Never crash, never block real audio.
- **`AVAudioPlayer` init failure:** log, disable filler for this session. Real audio still plays normally. Filler is always best-effort — it never blocks the real response path.
- **Audio session interruption** (incoming call, Siri): `stopAll(.hardCut)`, cancel timers, defer to the existing audio session handler.
- **PTT pressed again while filler is playing:** `stopAll(.hardCut)`, reset state, next PTT release triggers a fresh filler cycle.
- **20s hard cap with no response:** play an error-category phrase, reset state. Does not retry on its own.

## Testing Approach

### Unit tests

- **`FillerAssetLibrary`:** anti-repetition (never returns same URL twice in a row), both pools return valid URLs, category filtering works.
- **`FillerController`:** inject a fake `FillerPlayer` and a controllable clock. Verify: fast path cancels timer before phrase fires; slow path fires phrase at 2s; recurrences fire at correct intervals; 20s error phrase fires; PTT-press-during-filler resets state; first-audio-chunk event stops everything.

### Integration tests

- **`FillerPlayer`:** real `AVAudioPlayer`. Verify hard cut kills audio within ~20ms, verify fade completes in ~150ms.

### Manual on-device testing

The only way to judge whether it actually *feels* right. Required checks before merge:
1. Ambient starts instantly on PTT release (no perceptible gap)
2. Fast-response cut does not feel jarring
3. Spoken phrases feel natural, not robotic
4. Recurrence timing feels right, not too aggressive or too sparse
5. Interruption when real audio arrives feels clean, not abrupt
6. Repeat PTT during filler resets cleanly

## Open Questions / Future Work

- Context-aware phrase selection via server status hints over WebSocket
- Android port (QuipAndroid)
- User-configurable filler style or voice
- Telemetry on filler effectiveness (how often it fires, how long it plays)
