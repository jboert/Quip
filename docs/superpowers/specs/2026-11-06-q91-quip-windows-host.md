# Q-91: Quip for Windows: design spec (phase 1)

Status: design, not built. PRD with user stories: `tasks/prd-quip-windows-host.md`
(gitignored; this spec is the tracked copy of everything a builder needs).

## 1. What and why

The owner wants to drive a Windows PC from the iPhone the way they drive the
Mac: see its windows, arrange them, and dictate into PowerShell. There is no
Windows host today. `QuipMac/` is Swift, `QuipLinux/` is Rust + GTK4 (and is
another contributor's lane).

Phase 1 is a Windows tray app, `QuipWindows/`, that the **unmodified** 1.6.0
iPhone app pairs with by PIN and that:

1. lists the PC's windows and displays (`layout_update`),
2. arranges them side by side or stacked (`arrange_windows`),
3. types text into a chosen window, optionally followed by Return
   (`send_text`), plus Return / Ctrl+C / Esc / Tab / arrows (`quick_action`),
4. enables, focuses, minimizes and closes windows from the phone.

Target: 64-bit Windows 10/11 on Intel x64. Shells: PowerShell
(`powershell.exe`, `pwsh.exe`) and `cmd.exe`, in Windows Terminal and in the
classic console window.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| Language | Rust | Reuses QuipLinux's protocol / WebSocket / auth / mDNS code; one toolchain cross-compiles from the Mac. |
| Reuse | Copy files from `QuipLinux/`, never edit or share them | `QuipLinux/` is another contributor's lane. A shared crate would mean editing it. |
| Protocol reference | `Shared/MessageProtocol.swift` + `QuipMac`, not QuipLinux | QuipLinux was last changed 2026-05-01 (1.3.3). The phone is 1.6.0. Where they differ, the Mac wins. |
| Win32 bindings | `windows` crate (Microsoft) | Official, covers User32, DWM, UI Automation, Registry. |
| UI | Tray icon + menu + one small window (QR) | GTK4 on Windows needs an MSYS2 runtime bundle. Nothing else needs a window. |
| Build | Cross-compile on the Mac: `x86_64-pc-windows-gnu`, `mingw-w64`, static CRT | No Windows build machine. One `.exe`, no DLLs next to it. |
| Device kind | `deviceKind: "windows"` | The phone maps unknown kinds to `BackendKind.unknown`, used only for storage today (`BackendConnectionManager.swift:325`). No phone change needed. Adding `case windows` to `BackendKind` is a later, phone-side nicety. |
| PIN | 8 digits | Same as the Mac (`PINManager.pinDigits = 8`). The phone sends whatever the user typed; any length compares. |

## 3. Wire contract (phase 1)

Transport: WebSocket, text frames, JSON, port **8765**, all interfaces.
Max message size: `WSLimits.maxMessageBytes` in `Shared/Constants.swift`
(16 MiB). Unknown message types are logged at debug level and ignored. A
message that fails to decode is logged and ignored. Neither closes the socket.

### 3.1 Handshake

```
phone → host  {"type":"auth","pin":"12345678"}
host  → phone {"type":"auth_result","success":true}
host  → phone {"type":"device_identity","deviceID":"<uuid v4>","deviceKind":"windows",
               "displayName":"<PC hostname>","localURLs":["ws://192.168.1.20:8765"]}
host  → phone {"type":"layout_update", ...}            (first snapshot)
```

- Wrong PIN: `{"type":"auth_result","success":false,"error":"Incorrect PIN"}`,
  sent after the throttle delay. Throttle copied from
  `QuipLinux/src/services/auth_throttle.rs`; match the Mac's numbers
  (10 failures, 15 min lockout, growing per-attempt delay).
- Before auth, every message except `auth` is dropped and nothing is sent.
- `deviceID` is generated once and stored in settings. It is also the mDNS
  TXT `did` value.
- `localURLs`: one `ws://<ipv4>:8765` per non-loopback, up IPv4 interface,
  excluding `100.64.0.0/10` (Tailscale) and link-local `169.254.0.0/16`.
- `displayName`: the PC's hostname. It is never written to tracked files.

### 3.2 Host → phone

| Message | When | Notes |
|---|---|---|
| `layout_update` | After auth; then whenever the broadcast set or any frame changes (poll every 1 s) | See 3.4. Send an identical snapshot no more than once. |
| `frontmost_changed` | When the foreground window changes | `windowId` is the tracked id, or `null` when the foreground window is not in the broadcast set. Feeds the phone's recency stack (Q-88). |
| `heartbeat` | Every 15 s per authenticated client | `{"type":"heartbeat","seq":N,"ts":<unix s>}`. The phone replies `heartbeat_ack`. Two missed acks in a row: log it only. Do not disconnect in phase 1. |
| `send_text_ack` | After a `send_text` that carried `messageId` lands | `injectMs`, `totalMs`, `path:"sendText"`. Not sent on failure. |
| `error` | When an action fails in a way the user should see | Copy the Mac `ErrorMessage` shape. Use for "window is gone" and "Windows refused to focus the window". |
| `state_change` | Not used in phase 1 | Every window stays `state:"neutral"`. Waiting-state detection is phase 2. |

### 3.3 Phone → host (handled in phase 1)

| Message | Handling |
|---|---|
| `auth` | 3.1 |
| `heartbeat_ack` | Record round trip. Nothing else. |
| `select_window` | Bring the window to the foreground (5.3). |
| `send_text` | 5.4. Dedupe on `messageId` (keep the last 256 ids). `raiseWindow` is ignored: Windows input always lands in the foreground window, so the target is always raised. |
| `quick_action` | Keys from table 5.5. Unknown actions → `error`. `promptFingerprint` is ignored (no content reading in phase 1). |
| `arrange_windows` | `layout` is `horizontal` or `vertical` (the only two values; the phone's grid arranges on the phone and sends nothing). 5.2. |
| `minimize_window` | `ShowWindow(SW_MINIMIZE)`. |
| `close_window` | `PostMessage(WM_CLOSE)`. Never `TerminateProcess`. |
| `phone_log` | Append each line to `phone.log` (8). |
| `preferences_snapshot` | Store the JSON blob as-is in `%APPDATA%\Quip\phone-prefs.json` and answer `preferences_request` with it. This keeps the phone's prefs backup working on a Windows-only setup. |
| everything else | Ignore (debug log). Includes `request_content`, `image_upload`, `spawn_window`, `duplicate_window`, prompts, push, VibeCut, QA mode, iTerm messages. |

`toggle_enabled` arrives as a `quick_action` action (the Mac handles it in the
quick-action switch, `QuipMacApp.swift:3875`). Handle it: flip the window's
`enabled`, persist by a stable key (5.1), rebroadcast.

### 3.4 `layout_update` content

Field names and meaning follow `LayoutUpdate` and `WindowState` in
`Shared/MessageProtocol.swift` and `DisplayState` in `Shared/DisplayGeometry.swift`.

```json
{
  "type": "layout_update",
  "monitor": "<primary display name>",
  "screenAspect": 1.7778,
  "spanAspect": 3.5556,
  "displays": [ { "id": "...", "name": "...", "isPrimary": true, "aspect": 1.7778,
                  "spanFrame": {"x":0,"y":0,"width":0.5,"height":1} } ],
  "windows": [ {
      "id": "w-1a2b3c", "name": "<window title>", "app": "Windows Terminal",
      "folder": null, "project": null, "enabled": true,
      "frame": {"x":0.0,"y":0.0,"width":0.5,"height":1.0},
      "state": "neutral", "color": "#2D7FF9", "isThinking": false,
      "cliKind": "shell", "displayID": "...", "isPinned": false, "isMinimized": false
  } ]
}
```

- **Broadcast set:** windows with `enabled == true`, plus terminals on a
  visible display. Terminals start enabled. Non-terminals start disabled and
  are not sent, so the phone grid shows terminals by default. This is the Mac
  default (`windowsForBroadcast`, mirror off). A "Show all apps" tray toggle
  (off by default) widens it to every listed window, matching `mirrorAllApps`.
- **`id`:** a string. HWND values are reused by Windows after a window closes,
  so the id is `w-` + hex of (HWND, process id, window creation order). It
  stays the same for the window's life and never moves to a new window.
- **`frame`:** normalized 0..1 against the window's own display (the display
  holding most of its area), from `DWMWA_EXTENDED_FRAME_BOUNDS` (visible
  bounds, no invisible resize border).
- **`displayID`:** a stable string for the monitor (the monitor device name
  from `GetMonitorInfoW`, e.g. `\\.\DISPLAY1`, hashed). `isPrimary` is the
  monitor with `MONITORINFOF_PRIMARY`.
- **`monitor`:** the primary display's name. The phone uses it as a same-host
  identity signal, so it must not change when focus moves to another monitor.
- **`spaces`, `spaceID`, `targetKind`, `claudeMode`:** omitted. Windows
  virtual desktops are phase 2.
- **`folder` / `project`:** `null` in phase 1. The phone falls back to `app`.
- **`color`:** stable per window id, from the same palette the Mac uses.
- **`isThinking`:** `false` in phase 1.

## 4. Module map

```
QuipWindows/
  Cargo.toml                 package quip-windows, bin "Quip"
  build.rs                   embeds icon + manifest (DPI awareness, asInvoker)
  assets/quip.ico, Quip.exe.manifest
  README.md                  install + troubleshooting (owner-facing)
  src/
    main.rs                  tray message loop on the main thread; tokio runtime on a worker
    app_state.rs             window table, enabled set, client registry
    protocol/                copied from QuipLinux, reconciled (3); fixtures in tests/
      messages.rs  types.rs  limits.rs
    services/
      ws_server.rs           copied, reconciled; heartbeat; dedupe
      auth_throttle.rs       copied
      pin_store.rs           8-digit PIN in settings.toml
      device_id.rs           copied
      mdns_advertiser.rs     copied; service type "_quip._tcp.", TXT did=<deviceID>
      message_router.rs      phone → backend calls
      settings.rs            %APPDATA%\Quip\settings.toml
      log_paths.rs           %LOCALAPPDATA%\Quip\Logs
      quip_log.rs            append-only writers, size cap
      secret_redactor.rs     copied
      layout.rs              horizontal / vertical tiling math (pure)
    platform/
      traits.rs              copied from QuipLinux (WindowBackend, InputBackend)
      fake.rs                in-memory backend for Mac-side tests
      win32/                 #[cfg(windows)]
        windows.rs           enumerate, classify, frames, displays, move, focus
        input.rs             SendInput text + keys
        foreground.rs        the focus workaround (5.3)
        tray.rs              tray icon, menu, QR window
        autostart.rs         HKCU Run key
  tests/                     protocol fixtures, ws auth flow against fake backend
```

`platform/traits.rs` keeps the server, router and layout math testable on the
Mac. Only `platform/win32/` needs the PC.

## 5. Windows behavior

### 5.1 Listing windows

`EnumWindows`, keep a window when all hold:

- `IsWindowVisible`, non-empty title (`GetWindowTextW`),
- no owner (`GetWindow(GW_OWNER)` is null) and not `WS_EX_TOOLWINDOW`,
- not cloaked (`DwmGetWindowAttribute(DWMWA_CLOAKED) == 0`), which removes
  hidden UWP frames and windows on other virtual desktops,
- not Quip's own windows, not the shell (`Progman`, `WorkerW`,
  `Shell_TrayWnd`).

Minimized windows (`IsIconic`) are kept and flagged `isMinimized`.

`app` is the product name from the exe's version resource, falling back to the
exe file name without `.exe`. Process path via `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`
+ `QueryFullProcessImageNameW`. A process that cannot be opened (elevated or
protected) keeps the window, with `app` from the class name.

**Terminal detection:**

| Window | Terminal? | `app` |
|---|---|---|
| process `WindowsTerminal.exe` (class `CASCADIA_HOSTING_WINDOW_CLASS`) | yes | `Windows Terminal` |
| class `ConsoleWindowClass` (classic console) | yes | from the shell: `PowerShell`, `PowerShell 7`, `Command Prompt` |

For a classic console window, `GetWindowThreadProcessId` returns the
`conhost.exe` owner on some Windows builds and the shell on others. Resolve
the shell by walking the process snapshot (`CreateToolhelp32Snapshot`) for a
child or parent named `powershell.exe`, `pwsh.exe` or `cmd.exe`. Unknown
shell: still a terminal, `app` = `Console`.

`cliKind` is `shell` for every terminal in phase 1.

**Enabled set persistence:** windows have no stable id across restarts, so the
enabled set is stored by key `exe path + window title` and re-applied on
launch. This is best-effort; a renamed window simply starts at its default.

### 5.2 Arranging

`arrange_windows` tiles the enabled windows on the **primary** display, in
broadcast order, over its work area (`MONITORINFO.rcWork`, which excludes the
taskbar):

- `horizontal`: N equal columns, full height.
- `vertical`: N equal rows, full width.

For each window: if minimized or maximized, `ShowWindow(SW_RESTORE)` first.
Then `SetWindowPos(hwnd, null, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE)`,
batched with `BeginDeferWindowPos` / `DeferWindowPos` / `EndDeferWindowPos`.

The invisible resize border: target rect R is the visible rect. Read the
window's `GetWindowRect` and `DWMWA_EXTENDED_FRAME_BOUNDS`, take the per-edge
difference, and grow R by it before `SetWindowPos`. Without this, Windows 10/11
leaves 7 px gaps between tiles.

A window that does not move (elevated window, UIPI) is skipped and logged to
`injection.log` with `op=arrange kind=unknown detail="elevated or refused"`.
The others still move. `layout.rs` (the math) is pure and unit-tested on the
Mac.

The process is per-monitor DPI aware v2 (manifest), so all coordinates are
physical pixels and no scaling math is needed.

### 5.3 Bringing a window to the foreground

Windows only lets the foreground process, or one it permits, call
`SetForegroundWindow`. Quip is a background tray process, so a bare call
usually just flashes the taskbar button. Sequence:

1. If minimized: `ShowWindow(SW_RESTORE)`.
2. `SetForegroundWindow(hwnd)`. If `GetForegroundWindow() == hwnd`, done.
3. Otherwise `AttachThreadInput(our thread, foreground window's thread, TRUE)`,
   then `BringWindowToTop`, `SetForegroundWindow`, `SetFocus`, then detach.
4. Otherwise send a synthetic Alt down/up (`SendInput` `VK_MENU`) and retry
   `SetForegroundWindow` once. This is the documented "last input event"
   allowance.
5. Wait up to 300 ms, polling every 20 ms, for `GetForegroundWindow() == hwnd`.

If the window is still not foreground: fail. Never type anyway.

### 5.4 Typing (`send_text`)

1. Look up `windowId`. Missing → `injection.log` `kind=windowClosed`,
   `error` to the phone, stop.
2. Foreground it (5.3). Failure → `injection.log` `kind=unknown
   detail="focus refused"`, `error`, stop.
3. Type the text with `SendInput`, one `KEYEVENTF_UNICODE` down/up pair per
   UTF-16 code unit (surrogate pairs as two units, which Windows reassembles,
   so emoji arrive intact). Batches of at most 64 inputs per `SendInput` call.
4. Before each batch, check the window is still foreground. If focus moved
   mid-text, stop typing, log `kind=unknown detail="focus lost after N chars"`,
   send `error`. What was already typed stays (the same as a human losing
   focus); nothing goes to the other window after the check fails.
5. **Newlines:** a `\n` inside the text is sent as Shift+Enter in Windows
   Terminal (PowerShell's PSReadLine inserts a new line without running) and
   in the classic console. `\r\n` is treated as `\n`. Only the final Return,
   when `pressReturn` is true, is a plain `VK_RETURN`.
6. `pressReturn`: a 30 ms pause, then `VK_RETURN` down/up.
7. Send `send_text_ack` when `messageId` was present.

Text is never written to any log. `injection.log` failure lines carry `msg`
through `SecretRedactor` like the Mac.

### 5.5 Keys (`quick_action`)

| action | keys |
|---|---|
| `press_return` | Enter |
| `press_ctrl_c` | Ctrl+C |
| `press_ctrl_d` | Ctrl+D |
| `press_escape` | Esc |
| `press_tab` | Tab |
| `press_shift_tab` | Shift+Tab |
| `press_up` / `press_down` / `press_right` | arrows |
| `press_backspace` | Backspace |
| `press_y` / `press_n` | `y` / `n` (typed, no Return) |
| `clear_input` | Esc (PSReadLine clears the line on Esc) |
| `clear_terminal` | types `cls` + Enter |
| `toggle_enabled` | no keys; 3.3 |
| anything else | `error` "Not supported on Windows yet" |

Every key action foregrounds the window first (5.3) with the same failure
rules.

## 6. Tray app

Main thread: a Win32 message loop that owns the tray icon
(`Shell_NotifyIconW`) and the QR window. Networking runs on a tokio runtime
on worker threads; the two sides talk over channels. All Win32 window,
focus and input calls run on one dedicated platform thread (not the tray
thread), so a slow `SendInput` never freezes the tray menu.

Menu:

```
Quip — 1 phone connected
PIN 1234 5678               (click copies)
LAN 192.168.1.20 · Tailscale 100.x.y.z
Show pairing QR…
New PIN
Show all apps               ✓/blank
Start with Windows          ✓/blank
Open logs folder
Quit Quip
```

- **Single instance:** a named mutex `Local\QuipWindows`; a second launch
  exits right away.
- **Start with Windows:** writes or deletes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value `Quip` =
  `"<path to Quip.exe>"`. Default off.
- **Pairing QR:** `quip://pair?url=<base64url, no padding>&pin=<pin>` per
  `Shared/PairingPayload.swift`, URL = the first LAN URL (Tailscale if no LAN).
- **New PIN:** regenerates; connected phones stay connected (they already
  authenticated) and must re-enter on the next connect, the same as the Mac.
- No console window: `#![windows_subsystem = "windows"]`.

## 7. Settings

`%APPDATA%\Quip\settings.toml`:

```toml
pin = "12345678"
device_id = "<uuid>"
port = 8765
show_all_apps = false
enabled_windows = [ { exe = "C:\\...\\WindowsTerminal.exe", title = "..." } ]
```

The file is created on first run. A corrupt file is renamed to
`settings.toml.bad` and a new one is made (new PIN and device id), with a
`websocket.log` line saying so.

## 8. Logs

`%LOCALAPPDATA%\Quip\Logs\`, append-only, same line formats as the Mac
(`CLAUDE.md` log section):

- `websocket.log`: listen, connect, auth ok/fail, oversized drop, disconnect.
- `injection.log`: failed injections only, Mac format:
  `DROPPED op=… window=… app=… kind=… msg="…" [detail="…"]`.
- `phone.log`: the phone's `phone_log` lines, receive time first.
- `latency.log`: successful `send_text` timings.

Each file is capped at 10 MB; on reaching it, the file is renamed to
`<name>.1` (one old copy kept). A write failure (disk full) is dropped
silently, never a crash (lesson of `99927a4`).

## 9. Build and install

On the Mac, once:

```bash
rustup target add x86_64-pc-windows-gnu
brew install mingw-w64
```

`tools/build-windows.sh` checks both, prints these two commands if either is
missing, then runs
`cargo build --release --target x86_64-pc-windows-gnu --manifest-path QuipWindows/Cargo.toml`
and copies the result to `QuipWindows/dist/Quip.exe` (gitignored). Static
linking via `.cargo/config.toml`:
`rustflags = ["-C", "target-feature=+crt-static"]` for the gnu target. Check:
`x86_64-w64-mingw32-objdump -p Quip.exe | grep "DLL Name"` lists only Windows
system DLLs (`KERNEL32`, `USER32`, `ws2_32`, …), no `libgcc`, `libwinpthread`.

The `.exe` is unsigned. On the PC (owner steps, in `QuipWindows/README.md`):

1. Copy `Quip.exe` to `%LOCALAPPDATA%\Programs\Quip\`.
2. Double-click it. SmartScreen says "Windows protected your PC": click
   More info → Run anyway (once).
3. Windows Defender Firewall asks about network access: allow on **Private**
   networks. If the home network is marked Public, change it to Private in
   Settings → Network, or the phone cannot connect.
4. Tray icon → Show pairing QR, scan from the phone (or add the backend by
   IP and PIN).
5. Tray icon → Start with Windows, if wanted.

Getting the `.exe` to the PC: any file copy (USB, cloud drive, a share).
Choosing a transfer method is the owner's call and is not part of the build.

## 10. Tests

On the Mac (`cargo test`, wired into `tools/check.sh` and
`changed-scopes.sh` as scope `QuipWindows`):

| Area | Tests |
|---|---|
| Protocol | For each message in 3.1-3.3: a fixture JSON (written from the Swift types) decodes, and our encoder produces the same keys and value types. `layout_update` with every optional field absent and present. |
| Auth | Fake backend + real `ws_server` on a random port: wrong PIN → `success:false`; right PIN → `auth_result`, `device_identity` (`deviceKind:"windows"`), `layout_update`, in that order; messages before auth get no reply; 10 failures lock out. |
| Router | `send_text` with `pressReturn` calls `send_text` on the fake with the right args; duplicate `messageId` is typed once; unknown `quick_action` → `error`; `toggle_enabled` flips and rebroadcasts. |
| Layout math | 1, 2, 3, 5 windows horizontal and vertical over a work area with a taskbar offset; border compensation adds the per-edge difference. |
| Broadcast set | terminals default on, non-terminals off, `show_all_apps` widens, a minimized enabled window stays. |
| Window id | A reused HWND with a new process id gets a new id. |
| QR | Payload round-trips through the same rules as `PairingPayload.swift`. |
| Logs | `injection.log` line format matches the Mac's parser rules (bare `op`/`window`, quoted `msg`/`detail`). |

Win32 code (`platform/win32/`) cannot run on the Mac. It must compile there
(`cargo check --target x86_64-pc-windows-gnu`, also in `check.sh`), and it is
checked on the PC by the acceptance list below. No Win32 story is "done" on Mac
tests alone.

## 11. Acceptance on the PC (owner)

1. Run `Quip.exe`: tray icon appears, no console window. A second launch does
   nothing.
2. Phone pairs with the QR. The PC shows as a second backend; the Mac backend
   keeps working.
3. Open two PowerShell windows (one Windows Terminal, one classic). Both show
   on the phone as terminals within 2 s. Close one: gone within 2 s.
4. Arrange (side by side) from the phone: the two windows split the primary
   display with no gap. Stacked: same, top/bottom.
5. Dictate "Get-Date" with Return into each: the command runs in that window
   and no other.
6. Type a two-line text without Return: both lines sit in the prompt,
   nothing runs.
7. Ctrl+C from the quick buttons stops `ping -t localhost`.
8. Start a window as Administrator, send text to it: nothing is typed
   anywhere, the phone shows an error, `injection.log` has a line.
9. Reboot with Start with Windows on: Quip is in the tray, the phone
   reconnects.

## 12. Not in phase 1

- Terminal content (`terminal_content`, `request_content`), waiting state,
  numbered-prompt and Yes/No answers, smart answers. Needs UI Automation
  `TextPattern` on Windows Terminal / conhost. **Phase 2, first.**
- Screenshots of windows. Phase 2 (`PrintWindow` / Windows Graphics Capture).
- Image upload and paste, push notifications (APNs), Kokoro TTS, Whisper,
  Claude previews, prompts library, VibeCut, QA mode.
- Spawning, duplicating windows; project directories.
- Windows virtual desktops (`spaces`).
- WSL-specific behavior (a WSL tab is just a Windows Terminal window).
- Code signing, MSI/installer, auto-update, ARM64.
- Any change to `QuipLinux/`, `QuipAndroid/`, `QuipMac/` or the iPhone app.
  If the phone turns out to need one, stop and raise it.

## 13. Risks

| Risk | Effect | Handling |
|---|---|---|
| Foreground lock refuses focus | Text not delivered | 5.3 sequence; never type into the wrong window; error to the phone. Owner check 5. |
| Windows Terminal: several tabs, one HWND | Phone sees one window per Terminal window, not per tab | Accepted in phase 1. Text goes to the active tab. Per-tab needs UI Automation (phase 2). |
| PSReadLine not loaded (old PowerShell, `cmd.exe`) | Shift+Enter may run each line | Owner check 6 shows it. If it does, refuse multi-line text to that window with an error and a log line. Do not join lines with `;`: that changes what runs. |
| Firewall profile Public | Phone cannot connect | README step 3; `websocket.log` shows no connections; troubleshooting section. |
| mingw cross-compile gaps in a crate | Build breaks | `cargo check --target x86_64-pc-windows-gnu` in `check.sh` from US-001 on, so breakage shows on the first story that adds a crate. |
| Phone needs a Mac-only message to be usable | Backend paired but empty | Confirmed from code: the phone needs only `auth_result`, `device_identity`, `layout_update`. Check 2 proves it. |

## 14. Build order

US-001 scaffold + toolchain → US-002 protocol + fixtures → US-003 server +
auth (fake backend) → US-005 window listing → US-008 tray (first `.exe` the
owner can run: pairs and lists) → US-006 arrange → US-007 typing + keys →
US-004 mDNS + QR → US-009 logs → US-010 README → US-011 owner acceptance.

The first owner hand-off is after US-008: pair and see windows. Typing comes
next, so the risky focus code gets its own check.
