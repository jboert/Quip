# TTS Read Back

Read Claude's terminal responses aloud on the phone using native text-to-speech.

## Overview

When Claude finishes responding in a terminal session, the desktop sends the new output to the phone. The phone strips code blocks, diffs, and formatting, then speaks the conversational prose through the native TTS engine. Auto-read is on by default with a toggle to disable it. Tap anywhere to silence.

## Protocol Changes

New message type from desktop to mobile:

```json
{
  "type": "output_delta",
  "windowId": "abc-123",
  "text": "New lines of output since the last delta",
  "isFinal": true
}
```

- Desktop tracks a high-water mark per window — an offset of the last byte sent to the client.
- Sends deltas as new output appears in the active/selected window.
- `isFinal: true` when the window state transitions to `waiting_for_input` (Claude finished responding). This is the phone's cue to trigger TTS if auto-read is on.
- Initially, the phone only speaks on `isFinal: true`. Intermediate deltas (`isFinal: false`) are discarded for now but the protocol supports streaming TTS later.

### Client Capability Flag

During connection/auth, the phone sends:

```json
{
  "capabilities": { "tts": true }
}
```

Desktop only sends `output_delta` messages to clients that advertise this capability. Avoids unnecessary traffic for clients that don't use TTS.

## Desktop Changes (Mac + Linux)

Minimal changes on both desktop platforms:

- Track output high-water mark per window — index/offset of the last byte sent to each client.
- On new terminal output detected, compute the delta and send `output_delta` with `isFinal: false`.
- On state change to `waiting_for_input`, send a final `output_delta` with `isFinal: true` and reset the marker.
- Only send deltas to clients with `"capabilities": { "tts": true }`.

No audio, no filtering, no summarization on the desktop side. Just "here's what's new."

## Phone-side Text Filtering

When the phone receives an `output_delta` with `isFinal: true`, it assembles the buffered deltas into the full response and filters before speaking.

### Strip

- Code blocks (fenced ``` and indented)
- Diff output (+/- lines, file headers)
- ANSI escape codes
- Tool use output / file paths / line numbers
- Markdown formatting syntax (headers, bullets, bold/italic markers — keep the underlying words)

### Keep

- Conversational prose and explanations
- Error summaries (the human-readable part)
- Questions Claude asks the user

### Edge Cases

- If filtering leaves nothing (e.g., response was purely a code block), skip TTS silently.
- Regex-based stripping is sufficient — Claude's output follows predictable markdown patterns.
- Err toward reading slightly too much rather than missing important context.

## TTS Engine and Playback

### Engine

- **iOS:** `AVSpeechSynthesizer` — built-in, no download, works offline.
- **Android:** `android.speech.tts.TextToSpeech` — same deal.
- Abstract behind a simple interface: `speak(text)`, `stop()`, `isSpeaking()`. This allows swapping in a higher-quality engine (e.g., Piper, Coqui) later without changing the rest of the system.

### Playback Behavior

- Audio plays through the phone speaker or connected earbuds/headphones.
- Tap anywhere on screen stops playback immediately.
- PTT recording and TTS are fully independent — both can run simultaneously.
- If a new `isFinal: true` delta arrives while TTS is still speaking the previous response, stop the old one and start the new one.

### Auto-Read Toggle

- Defaults to ON.
- Persisted in local settings (UserDefaults on iOS, SharedPreferences on Android).
- When OFF, deltas still arrive (cheap) but are not spoken.

## UI Changes (Mobile)

Minimal additions:

- **Speaker icon** in the top bar/toolbar — tap to toggle auto-read on/off. Filled icon = on, slashed icon = off.
- **While speaking**, the icon pulses subtly so the user knows TTS is active.
- **Tap-to-silence overlay** — a transparent gesture layer that activates only while `isSpeaking()` is true, so it doesn't interfere with normal interaction when TTS is idle.
- No new screens or settings pages.

## Architecture Summary

```
Desktop                          Phone
───────                          ─────
Terminal output changes
  → compute delta
  → send output_delta ──────→ receive delta
       (isFinal?)               │
                                ├─ isFinal: false → discard (for now)
                                ├─ isFinal: true  → filter text
                                │                    → strip code/diffs/ANSI
                                │                    → keep prose
                                │                    → speak via native TTS
                                │
                           tap anywhere → stop()
                           speaker icon → toggle auto-read
```
