# Quip Project Instructions

## Debugging "photo upload spins forever"

When the phone's photo-upload thumbnail spinner never clears, the root cause is almost never obvious and almost always at least one of these — run through the whole list before declaring a fix:

1. **Two separate size caps on Mac WebSocket** — `QuipMac/Services/WebSocketServer.swift` enforces BOTH `NWProtocolWebSocket.Options.maximumMessageSize` (protocol-level) AND an explicit `data.count > N` check inside `receiveMessage` (app-level). Both must be ≥ 16 MiB. The app-level drop is silent — `print`s to stderr but sends nothing back to the client. Look for `[WebSocketServer] Dropping oversized message` in `/tmp/quip-mac.log`.
2. **iOS `maximumMessageSize`** — `QuipiOS/Services/WebSocketClient.swift` must set `task.maximumMessageSize = 16 * 1024 * 1024` on every new task. Keep in sync with the Mac caps.
3. **Race between image_upload and press_return** — `sendPendingImageIfNeeded` encodes on a background queue; callers must use its `afterSend:` callback to defer press_return / send_text, otherwise press_return reaches Mac first and the user sees a "break in the prompt" with no image pasted.
4. **Stale iOS bundle** — `devicectl install app` replaces the .app on disk but does NOT kill the running process. The user must force-quit from the app switcher and relaunch to pick up new Swift code.
5. **Dead WebSocket despite "Connected" UI** — iOS keepalive pings every 10s but can miss a one-sided disconnect (especially after a Mac restart). `netstat -an | grep 8765` on the Mac shows the truth; tell the user to tap X → reconnect or fully relaunch.
6. **Mac app predates image_upload** — commit `a4114b8` added the Mac handler. `stat -f "%Sm" /Applications/Quip.app` vs that commit date is worth a 5-second check.
7. **TCC grants lost on Mac rebuild** — Accessibility (for keystroke injection) and Screen Recording (for the `screencapture` fallback that powers the screenshot view). Even with the stable-signing recipe, macOS sometimes re-prompts after a rebuild because cdhash-level policies. Avoid rebuilding Mac when the change is iOS-only.

Diagnostic: `PendingImageState.debugStage` captures pipeline breadcrumbs (`encoding-start`, `encoded NB`, `sending b64=NB`, `sent, awaiting ack`). If a 10s watchdog fires, the error message includes the last stage — that tells you whether the problem is on the phone, in transit, or on the Mac.

