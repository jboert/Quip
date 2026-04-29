# Quip Project Instructions

## Log file locations

All Mac diagnostic logs live under `~/Library/Logs/Quip/`. They survive reboots and are indexed by `Console.app` (filter on "Quip"). The three append-only files are:

- `~/Library/Logs/Quip/websocket.log` — WS handshake / message arrival, oversized-drop notices, auth events
- `~/Library/Logs/Quip/push.log` — APNs push pipeline (the "I didn't get a notification" debugging path)
- `~/Library/Logs/Quip/kokoro.log` — Kokoro TTS daemon lifecycle and synth events

On Linux, the equivalents live under `$XDG_STATE_HOME/quip/` (default `~/.local/state/quip/`).

Path resolution lives in `QuipMac/Services/LogPaths.swift` and `QuipLinux/src/services/log_paths.rs` — change one place if you ever need to relocate.

## Debugging "photo upload spins forever"

When the phone's photo-upload thumbnail spinner never clears, the root cause is almost never obvious and almost always at least one of these — run through the whole list before declaring a fix:

1. **The 16 MiB cap is enforced at TWO layers** — `QuipMac/Services/WebSocketServer.swift` enforces both `NWProtocolWebSocket.Options.maximumMessageSize` (protocol-level) AND an explicit `data.count > N` check inside `receiveMessage` (app-level). Both pull from `WSLimits.maxMessageBytes` (`Shared/Constants.swift`) — change there once and all peers stay in sync. The app-level drop is silent (logs to `~/Library/Logs/Quip/websocket.log`, sends nothing back to the client). Look for `[WebSocketServer] Dropping oversized message`.
2. **iOS `maximumMessageSize`** — `QuipiOS/Services/WebSocketClient.swift` sets `task.maximumMessageSize = WSLimits.maxMessageBytes` on every new task. Driven by the same shared constant; if you change the limit, all three peers (Mac protocol-level, Mac app-level, iOS) move together.
3. **Race between image_upload and press_return** — `sendPendingImageIfNeeded` encodes on a background queue; callers must use its `afterSend:` callback to defer press_return / send_text, otherwise press_return reaches Mac first and the user sees a "break in the prompt" with no image pasted.
4. **Stale iOS bundle** — `devicectl install app` replaces the .app on disk but does NOT kill the running process. The user must force-quit from the app switcher and relaunch to pick up new Swift code.
5. **Dead WebSocket despite "Connected" UI** — iOS keepalive pings every 10s but can miss a one-sided disconnect (especially after a Mac restart). `netstat -an | grep 8765` on the Mac shows the truth; tell the user to tap X → reconnect or fully relaunch.
6. **Mac app predates image_upload** — commit `a4114b8` added the Mac handler. `stat -f "%Sm" /Applications/Quip.app` vs that commit date is worth a 5-second check.
7. **TCC grants lost on Mac rebuild** — Accessibility (for keystroke injection) and Screen Recording (for the `screencapture` fallback that powers the screenshot view). Even with the stable-signing recipe, macOS sometimes re-prompts after a rebuild because cdhash-level policies. Avoid rebuilding Mac when the change is iOS-only.

Diagnostic: `PendingImageState.debugStage` captures pipeline breadcrumbs (`encoding-start`, `encoded NB`, `sending b64=NB`, `sent, awaiting ack`). If a 10s watchdog fires, the error message includes the last stage — that tells you whether the problem is on the phone, in transit, or on the Mac.

