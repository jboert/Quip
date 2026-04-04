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

## Authentication

After connecting, clients must authenticate before the server will process any other messages. The server holds connections in a "pending auth" state until a valid PIN is received.

### auth

Client sends PIN to authenticate with the server.

```json
{
  "type": "auth",
  "pin": "123456"
}
```

### auth_result

Server responds with the authentication result.

```json
{
  "type": "auth_result",
  "success": true,
  "error": null
}
```

On failure:

```json
{
  "type": "auth_result",
  "success": false,
  "error": "Invalid PIN"
}
```

`error` is `null` when `success` is `true`.

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
- **iOS:** `QuipiOS/Services/WebSocketClient.swift` → `CloudflareCertificatePinningDelegate.pinnedSPKIHashes`
- **Android:** `QuipAndroid/.../services/WebSocketClient.kt` → `CertificatePinner` configuration

Pin the **intermediate** and **root** CA hashes (not the leaf).

## Implementations

| Platform | Language | Location |
|---|---|---|
| iOS / Mac | Swift | `Shared/MessageProtocol.swift` |
| Android | Kotlin | `QuipAndroid/.../models/Protocol.kt` |
| Linux | Rust | `QuipLinux/src/protocol/` |
