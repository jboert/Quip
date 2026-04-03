# Quip Message Protocol

JSON over WebSocket. Every message has a `type` field. Field names use camelCase.

## Transport

- Server (Mac/Linux) listens on a WebSocket port (default 8765)
- Clients (iOS/Android) connect via `ws://` (local) or `wss://` (Cloudflare tunnel)
- Server broadcasts `layout_update` every 2 seconds to all connected clients

## Desktop → Mobile

### layout_update

Periodic broadcast with current window layout.

```json
{
  "type": "layout_update",
  "monitor": "Display 1",
  "windows": [
    {
      "id": "Terminal.12345",
      "name": "zsh — ~/Projects/quip",
      "app": "Terminal.app",
      "enabled": true,
      "frame": { "x": 0.0, "y": 0.0, "width": 0.5, "height": 1.0 },
      "state": "neutral",
      "color": "#FF6B6B"
    }
  ]
}
```

**WindowFrame** coordinates are normalized 0.0–1.0 relative to the display bounds.

**Window state** values:
- `"neutral"` — idle
- `"waiting_for_input"` — terminal has a prompt, waiting for user input
- `"stt_active"` — speech-to-text is recording on a client

### state_change

Sent immediately when a window's terminal state changes.

```json
{
  "type": "state_change",
  "windowId": "Terminal.12345",
  "state": "waiting_for_input"
}
```

### terminal_content

Response to `request_content`. Contains the last ~200 lines of terminal output and an optional base64-encoded PNG screenshot.

```json
{
  "type": "terminal_content",
  "windowId": "Terminal.12345",
  "content": "$ ls -la\ntotal 48\n...",
  "screenshot": "iVBORw0KGgoAAAANSUhEUgAA..."
}
```

`screenshot` is `null` when capture is unavailable.

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

Actions:
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

### stt_started / stt_ended

Notify the server that speech-to-text recording started or stopped. The server sets the window state to `"stt_active"` / `"neutral"` and broadcasts a `state_change`.

```json
{ "type": "stt_started", "windowId": "Terminal.12345" }
{ "type": "stt_ended",   "windowId": "Terminal.12345" }
```

### request_content

Request terminal output and screenshot for a window. Server responds with `terminal_content`.

```json
{
  "type": "request_content",
  "windowId": "Terminal.12345"
}
```

## Message Routing

Server reads the `type` field from the JSON envelope first, then deserializes into the appropriate struct. Unknown types are logged and ignored.

## Implementations

| Platform | Language | Location |
|---|---|---|
| iOS / Mac | Swift | `Shared/MessageProtocol.swift` |
| Android | Kotlin | `QuipAndroid/.../models/Protocol.kt` |
| Linux | Rust | `QuipLinux/src/protocol/` |
