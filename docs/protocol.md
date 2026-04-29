# Quip Message Protocol

JSON over WebSocket. Every message has a `type` field. Field names use camelCase.

The authoritative schema lives in `Shared/MessageProtocol.swift` (Apple), `QuipLinux/src/protocol/messages.rs` (Linux), and `QuipAndroid/.../models/Protocol.kt` (Android). When this doc and the code disagree, the code wins — and please open a doc PR.

## Transport

- Server (Mac/Linux) listens on a WebSocket port (default 8765)
- Clients (iOS/Android) connect via `ws://` (local) or `wss://` (Cloudflare tunnel)
- Server broadcasts `layout_update` every 2 seconds to all connected clients
- Maximum message size is 16 MiB (`WSLimits.maxMessageBytes`); larger messages are dropped at both the protocol layer and a defensive app-layer check

## Authentication

After connecting, clients must authenticate before the server will process any other messages. The server holds connections in a "pending auth" state until a valid PIN is received. Auth messages bypass rate limiting; everything else is rate-limited (10 msg/sec/client) and rejected if not authenticated.

### auth

Client → Server. Send the 6-digit PIN displayed in the desktop app's Settings.

```json
{
  "type": "auth",
  "pin": "123456"
}
```

### auth_result

Server → Client. Sent once on connection ready (with `success: false, error: "auth_required"` when auth is enabled, or `success: true, error: null` when not), and again after each `auth` attempt.

```json
{
  "type": "auth_result",
  "success": true,
  "error": null
}
```

On failure, `success` is `false` and `error` carries one of: `"auth_required"`, `"Server PIN not configured"`, `"Malformed auth message"`, `"Incorrect PIN"`.

## Desktop → Mobile

### layout_update

Periodic broadcast (~2s) with current window layout.

```json
{
  "type": "layout_update",
  "monitor": "Display 1",
  "screenAspect": 1.777,
  "windows": [
    {
      "id": "Terminal.12345",
      "name": "zsh — ~/Projects/quip",
      "app": "Terminal.app",
      "folder": "quip",
      "enabled": true,
      "frame": { "x": 0.0, "y": 0.0, "width": 0.5, "height": 1.0 },
      "state": "neutral",
      "color": "#FF6B6B",
      "isThinking": false,
      "claudeMode": "normal"
    }
  ]
}
```

`screenAspect`, `folder`, `isThinking`, and `claudeMode` are optional for backward-compat with older desktop builds; clients must tolerate their absence. `frame` coordinates are normalized 0.0–1.0 relative to the display bounds.

**Window state** values:
- `"neutral"` — idle
- `"waiting_for_input"` — terminal has a prompt, waiting for user input
- `"stt_active"` — speech-to-text is recording on a client

**Claude mode** values: `"normal"`, `"plan"`, `"autoAccept"`, or absent if the window isn't a Claude Code session or detection hasn't run yet. Cycle order is `normal → autoAccept → plan` (one Shift+Tab press per step).

### state_change

Sent immediately when a window's terminal state changes — clients use this to update UI without waiting for the next periodic `layout_update`.

```json
{
  "type": "state_change",
  "windowId": "Terminal.12345",
  "state": "waiting_for_input"
}
```

### terminal_content

Response to `request_content`. Contains the last ~200 lines of terminal output, an optional base64-encoded PNG screenshot, and an optional list of URLs extracted from `content` server-side (so phones can render a tap-to-open tray alongside the screenshot, which is otherwise pixels).

```json
{
  "type": "terminal_content",
  "windowId": "Terminal.12345",
  "content": "$ ls -la\ntotal 48\n...",
  "screenshot": "iVBORw0KGgoAAAANSUhEUgAA...",
  "urls": ["https://example.com/foo"]
}
```

`screenshot` is `null` when capture is unavailable (e.g., Screen Recording permission not granted). `urls` is optional for backward compat with pre-tray Mac builds.

### output_delta

Streaming chunk of new terminal output for a window — used to drive the in-app terminal mirror without polling. Each delta carries a contiguous slice of new text. `isFinal: true` marks the end of a coalescing batch.

```json
{
  "type": "output_delta",
  "windowId": "Terminal.12345",
  "windowName": "zsh — ~/Projects/quip",
  "text": "Building target QuipMac...\n",
  "isFinal": false
}
```

### tts_audio

Pre-synthesized speech from the desktop's TTS engine, streamed sentence-by-sentence. Each message carries one sentence's worth of WAV audio. `sessionId` identifies a response batch — clients play chunks with the same `sessionId` in `sequence` order and cancel the queue when a new `sessionId` arrives. `isFinal` marks the last chunk in a session.

```json
{
  "type": "tts_audio",
  "windowId": "Terminal.12345",
  "windowName": "zsh — ~/Projects/quip",
  "sessionId": "B6F4-...",
  "sequence": 0,
  "isFinal": false,
  "audioBase64": "UklGR...",
  "format": "wav"
}
```

### error

Generic out-of-band error so clients can surface feedback when the desktop drops a message (unknown window, throttled, decode failure, etc.) instead of the user staring at silence.

```json
{
  "type": "error",
  "reason": "Unknown windowId: Terminal.99999"
}
```

### project_directories

Snapshot of the desktop's configured project directories, sent so the phone can offer a "spawn new window in…" picker.

```json
{
  "type": "project_directories",
  "directories": ["/Users/jb/Projects/quip", "/Users/jb/Projects/site"]
}
```

### iterm_window_list

Response to `scan_iterm_windows`. Each row mirrors `WindowManager.ITermWindowDescriptor`. `isAlreadyTracked` lets the UI dim rows already in Quip's window list so the user doesn't double-attach. `isMiniaturized` lets the UI tag minimized iTerm windows.

```json
{
  "type": "iterm_window_list",
  "windows": [
    {
      "windowNumber": 17,
      "title": "zsh — ~/work",
      "sessionId": "DEADBEEF-...",
      "cwd": "/Users/jb/work",
      "isAlreadyTracked": false,
      "isMiniaturized": false
    }
  ]
}
```

`sessionId` is iTerm's session "unique id" and persists across iTerm restarts for undetached sessions — pair it with `windowNumber` (which is reassigned across iTerm relaunches) when re-attaching.

### mac_permissions

Snapshot of macOS TCC grants the desktop needs. Sent on startup, on each successful client auth, and every 5s while a client is connected. Local Network is intentionally omitted — if you can read this message at all, Local Network is working.

```json
{
  "type": "mac_permissions",
  "accessibility": true,
  "appleEvents": true,
  "screenRecording": false
}
```

`appleEvents` reflects the Automation grant for iTerm specifically (probed via `AEDeterminePermissionToAutomateTarget`). When iTerm isn't running, the desktop returns `true` rather than false-alarming.

### whisper_status

Lifecycle of the desktop-side Whisper transcription model — clients use it to decide whether the remote PTT path is viable before the user starts holding down the talk button.

```json
{ "type": "whisper_status", "state": { "tag": "preparing" } }
{ "type": "whisper_status", "state": { "tag": "downloading", "progress": 0.42 } }
{ "type": "whisper_status", "state": { "tag": "ready" } }
{ "type": "whisper_status", "state": { "tag": "failed", "message": "..." } }
```

`progress` is `0.0`–`1.0`. The four tags are mutually exclusive.

### transcript_result

Final Whisper transcription for a completed PTT session. `text` is empty when `error` is set; otherwise `error` is null.

```json
{
  "type": "transcript_result",
  "sessionId": "F4A6...",
  "text": "refactor the auth middleware",
  "error": null
}
```

### image_upload_ack

Sent after the desktop wrote an uploaded image to disk and pasted its path into the target terminal.

```json
{
  "type": "image_upload_ack",
  "imageId": "8A21-...",
  "savedPath": "/Users/jb/Library/Caches/Quip/uploads/8A21-photo.jpg"
}
```

### image_upload_error

Sent on any failure during `image_upload` processing — decode error, unknown window, sandbox-escape attempt, disk write failure, etc. `imageId` matches the original upload so the client can clear the right pending spinner.

```json
{
  "type": "image_upload_error",
  "imageId": "8A21-...",
  "reason": "Invalid base64"
}
```

### preferences_restore

Response to `preferences_request` — returns the most recent snapshot the desktop has stored for this `deviceID`. The phone applies these into `UserDefaults` during a brief sync-suppression window so it doesn't echo the restore back. If no backup exists, the desktop still responds with an empty `preferences` object so the client can finish its restore handshake.

```json
{
  "type": "preferences_restore",
  "preferences": {
    "ttsEnabled": true,
    "contentZoomLevel": 2,
    "pushQuietHoursStart": 22,
    "pushQuietHoursEnd": 7
  }
}
```

See `PreferencesSnapshot` in `Shared/MessageProtocol.swift` for the full field list — every field is optional so older clients decode cleanly.

## Mobile → Desktop

### select_window

Focus a window on the desktop.

```json
{
  "type": "select_window",
  "windowId": "Terminal.12345"
}
```

### send_text

Type text into a window. `pressReturn` defaults to `true`.

```json
{
  "type": "send_text",
  "windowId": "Terminal.12345",
  "text": "ls -la",
  "pressReturn": true
}
```

### quick_action

Trigger a predefined terminal action.

```json
{
  "type": "quick_action",
  "windowId": "Terminal.12345",
  "action": "press_ctrl_c"
}
```

| Action | Effect |
|---|---|
| `press_return` | Press Enter |
| `press_ctrl_c` | Send Ctrl+C (SIGINT) |
| `press_ctrl_d` | Send Ctrl+D (EOF) |
| `press_escape` | Press Escape |
| `press_tab` | Press Tab |
| `press_y` | Type "y" + Enter |
| `press_n` | Type "n" + Enter |
| `clear_terminal` | Send "/clear" command |
| `restart_claude` | Ctrl+C then type "claude" + Enter |
| `toggle_enabled` | Toggle window management on/off |

### request_content

Ask for terminal output and screenshot for a window. Server responds with `terminal_content`.

```json
{
  "type": "request_content",
  "windowId": "Terminal.12345"
}
```

### duplicate_window

Spawn a new iTerm2 window in the same working directory as the source window, running the configured command.

```json
{
  "type": "duplicate_window",
  "sourceWindowId": "Terminal.12345"
}
```

### close_window

Destructive — close a specific iTerm2 window, killing any running command in that session.

```json
{
  "type": "close_window",
  "windowId": "Terminal.12345"
}
```

### spawn_window

Spawn a new iTerm2 window in the given directory, running the configured spawn command.

```json
{
  "type": "spawn_window",
  "directory": "/Users/jb/Projects/quip"
}
```

### arrange_windows

Evenly arrange all enabled windows on the main display. The desktop uses the same `LayoutCalculator` path that the menu-bar "Arrange Windows" button triggers. Any value other than the two below is rejected.

```json
{
  "type": "arrange_windows",
  "layout": "horizontal"
}
```

| `layout` | Effect |
|---|---|
| `"horizontal"` | Side-by-side (split vertically) |
| `"vertical"` | Stacked top-to-bottom |

### scan_iterm_windows

Ask the desktop to enumerate every iTerm2 window it can see, so the phone can show a "pick one to attach" list. Empty body beyond `type`. Desktop responds with `iterm_window_list`.

```json
{ "type": "scan_iterm_windows" }
```

### attach_iterm_window

User picked a row from the scan list — promote it to a tracked Quip window. Pair `windowNumber` (current iTerm window id) with `sessionId` (stable across iTerm restarts) so the desktop can recover identity if iTerm relaunches between scan and attach.

```json
{
  "type": "attach_iterm_window",
  "windowNumber": 17,
  "sessionId": "DEADBEEF-..."
}
```

### stt_started / stt_ended

Notify the desktop that on-device speech-to-text recording started or stopped. The desktop sets the window state to `"stt_active"` / `"neutral"` and broadcasts a `state_change`. Used for the on-device recognizer path; the remote-Whisper path uses `audio_chunk` instead.

```json
{ "type": "stt_started", "windowId": "Terminal.12345" }
{ "type": "stt_ended",   "windowId": "Terminal.12345" }
```

### audio_chunk

Streamed PTT audio for the remote-Whisper path. `pcmBase64` is standard base64 of int16 little-endian mono 16 kHz PCM — nominally 100 ms per frame (3,200 bytes decoded), shorter on the final frame. `isFinal: true` signals end-of-utterance and triggers Whisper transcription on the desktop, which replies with `transcript_result`.

```json
{
  "type": "audio_chunk",
  "sessionId": "F4A6-...",
  "seq": 0,
  "pcmBase64": "AAAAAQACAA...",
  "isFinal": false
}
```

### image_upload

Carries a single image to be attached to a terminal. `data` is the image bytes base64-encoded as a string (standard base64, no URL-safe variant). Post-encoding message size must fit under `WSLimits.maxMessageBytes` (16 MiB); the phone enforces a tighter ~10 MB cap on the sender side.

```json
{
  "type": "image_upload",
  "imageId": "8A21-...",
  "windowId": "Terminal.12345",
  "filename": "photo.jpg",
  "mimeType": "image/jpeg",
  "data": "/9j/4AAQSkZJRgABA..."
}
```

The desktop writes the image to a sandboxed uploads directory (`~/Library/Caches/Quip/uploads/` on Mac, equivalent on Linux), pastes the path into the target terminal, then replies with `image_upload_ack` (success) or `image_upload_error` (failure). Both `imageId` and `filename` are sanitized before being used as filename components — a hostile phone cannot escape the uploads root via path traversal.

### register_push_device

Hand over the APNs device token so the desktop can push to this device. `environment` must match the `aps-environment` entitlement the iOS app was signed with — a dev-env token won't work against production APNs (or vice-versa).

```json
{
  "type": "register_push_device",
  "deviceToken": "AABBCCDD...",
  "environment": "production"
}
```

`environment` is `"development"` or `"production"`.

### push_preferences

User notification preferences. Synced on every toggle change AND on every successful reconnect, so the desktop is always working with the current values. Stored per-device on the desktop, keyed by `deviceToken`, so two phones paired to the same desktop behave independently.

```json
{
  "type": "push_preferences",
  "deviceToken": "AABBCCDD...",
  "paused": false,
  "quietHoursStart": 22,
  "quietHoursEnd": 7,
  "sound": true,
  "foregroundBanner": false,
  "bannerEnabled": true,
  "timeZone": "America/Phoenix"
}
```

`quietHoursStart` / `quietHoursEnd` are integer hours of day (0–23) in the time zone identified by `timeZone` (IANA identifier, e.g., `"America/Phoenix"`). Either being `null` disables quiet hours. `bannerEnabled: false` keeps Live Activities updating via WebSocket but suppresses the APNs banner — "island-only" mode. `bannerEnabled` and `timeZone` are optional for backward compat with older clients.

### preferences_snapshot

Mirror of phone preferences so they survive a reinstall. Sent (debounced) every time a tracked preference changes. The desktop stores the snapshot in `UserDefaults` keyed by `deviceID`, so multiple phones each have their own backup.

```json
{
  "type": "preferences_snapshot",
  "deviceID": "11111111-2222-3333-4444-555555555555",
  "preferences": {
    "ttsEnabled": true,
    "contentZoomLevel": 2,
    "pushSound": true
  }
}
```

Every field in `preferences` is optional — only values the user has actually touched are persisted. Connection-specific keys (last URL, recent connections list) are intentionally excluded.

### preferences_request

Sent on each WebSocket auth so the phone can pull back its preferences after a reinstall. Desktop responds with `preferences_restore` (with empty `preferences` if no backup exists for this `deviceID`).

```json
{
  "type": "preferences_request",
  "deviceID": "11111111-2222-3333-4444-555555555555"
}
```

### open_mac_settings_pane

Tap-to-open shortcut: the desktop calls `NSWorkspace.shared.open(...)` with the matching `x-apple.systempreferences:` URL so the right pane pops up without the user navigating System Settings manually.

```json
{
  "type": "open_mac_settings_pane",
  "pane": "accessibility"
}
```

| `pane` | Setting |
|---|---|
| `"accessibility"` | Privacy & Security → Accessibility |
| `"automation"` | Privacy & Security → Automation |
| `"screenRecording"` | Privacy & Security → Screen Recording |

## Message Routing

The server reads the `type` field from the JSON envelope first, then deserializes into the appropriate struct. Unknown types are logged and ignored. Decode failures inside a known type send back an `error` message rather than silently dropping.

## Certificate Pinning (Cloudflare Tunnel)

When connecting via `wss://*.trycloudflare.com`, mobile clients pin the server's TLS certificate chain to prevent MITM attacks from compromised CAs. Direct LAN `ws://` connections are not affected.

**Pinning strategy:** SPKI (Subject Public Key Info) SHA-256 hashes of the intermediate and root CA certificates in the chain. Leaf certificates are NOT pinned since they rotate frequently.

### Updating Pins

When Cloudflare rotates their certificate chain, connections will fail. To get the new SPKI hashes:

```bash
# Dump the full chain and extract each certificate's SPKI hash
echo | openssl s_client -connect trycloudflare.com:443 -showcerts 2>/dev/null \
  | python3 -c "
import subprocess, re, sys
certs = re.findall(r'(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)', sys.stdin.read(), re.DOTALL)
for i, cert in enumerate(certs):
    with open(f'/tmp/cf_{i}.pem', 'w') as f: f.write(cert)
    subj = subprocess.run(['openssl', 'x509', '-noout', '-subject', '-in', f'/tmp/cf_{i}.pem'], capture_output=True, text=True)
    spki = subprocess.run(f'openssl x509 -noout -pubkey -in /tmp/cf_{i}.pem | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64', shell=True, capture_output=True, text=True)
    print(f'Certificate {i}: {subj.stdout.strip()}')
    print(f'  SPKI SHA-256: {spki.stdout.strip()}')
"
```

Update the pinned hashes in:
- **iOS:** `QuipiOS/Resources/CertPins.json` (`spkiHashes` array). The Swift code in `WebSocketClient.swift` reads this file at runtime — no Swift edit needed for a rotation.
- **Android:** `QuipAndroid/.../services/WebSocketClient.kt` → `CertificatePinner` configuration.

Pin the **intermediate** and **root** CA hashes (not the leaf).

### iOS override file

iOS users can ship a hot-fix without an app update by dropping a JSON file with the same shape as `CertPins.json` at `~/Documents/quip-cert-pins.json` inside the Quip app's Documents container (Files.app → "On My iPhone" → Quip → drag-and-drop, or push via MDM). The override completely replaces the bundled set on the next connection. To revert, delete the override file. Resolution order is documented in `CloudflareCertificatePinningDelegate` (Documents override → bundled `CertPins.json` → hardcoded fallback).

## Implementations

| Platform | Language | Location |
|---|---|---|
| iOS / Mac | Swift | `Shared/MessageProtocol.swift` |
| Android | Kotlin | `QuipAndroid/.../models/Protocol.kt` |
| Linux | Rust | `QuipLinux/src/protocol/` |

Shared cross-platform invariants (e.g., the 16 MiB message cap) live in `Shared/Constants.swift` and `QuipLinux/src/protocol/limits.rs` — change in one place, everyone stays consistent.
