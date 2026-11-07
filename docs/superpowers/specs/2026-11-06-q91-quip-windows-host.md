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
host  → phone {"type":"auth_result","success":false,"error":"auth_required"}   (on connect)
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
- The `auth_required` greeting is sent as soon as the WebSocket upgrade
  completes; the 1.6.0 phone sends its PIN only after it (or shows its PIN
  prompt when it has none saved). The Mac sends the same greeting.
- Before auth, every message except `auth` is dropped and nothing else is sent.
- Deadlines: the WebSocket upgrade must finish within 10 s of accept (the
  Mac's `PreHandshakeReapPolicy`); auth must succeed within 120 s, long enough
  to type a PIN on the phone's prompt. At most 16 sockets may wait for auth,
  at most 8 of them from one network (the /64 for IPv6, the address for
  IPv4) and at most 4 from one exact address, so one LAN peer holding
  sockets open for the 120 s cannot lock the phone out. More are closed at
  accept, with one exception: a sender holding no waiting socket is never
  refused because its network's 8 or all 16 are taken. It evicts the oldest
  waiting socket of the address holding the most (inside its own network
  when that is what is full; a tie goes to the address whose network holds
  the most), which is closed at once, even in a wrong PIN's delay, and whose
  PIN, if one arrives after, is not checked. A socket whose PIN is being
  checked, or whose wrong PIN is queued for a guess token (below), is never
  evicted; with only such sockets there, the newcomer is refused. So a peer
  on 4 IPv4 addresses, or on 2 or more addresses in the phone's /64, filling
  every slot with idle sockets still cannot keep the phone from sending its
  PIN; its own extra sockets are refused or replace one of its own. Keeping
  slots queued instead takes a stream of wrong PINs, which an IPv4 address
  cannot sustain past its 10-failure lockout. A socket's slot is freed as
  soon as its peer closes, including while a wrong PIN's delay runs; only a
  wrong PIN still queued for a guess token keeps its slot until it has one.
- Sender: the lockout and the per-sender cap use the exact peer address
  without its port, as on the Mac. An IPv4-mapped IPv6 address
  (`::ffff:192.0.2.1`) is its IPv4 address (`192.0.2.1`). So one device on a
  shared network (a home LAN /64, a tailnet) cannot lock out or crowd out
  another device on it.
- Network delay: a second count per network (an IPv6 address's /64; for IPv4
  the address itself) only slows wrong PINs, so rotating addresses inside one
  /64 gives fresh lockouts but no fast guesses. Up to 10 failures in the
  network add nothing (one address alone sees the Mac's numbers); past that a
  wrong PIN waits 200 ms per network failure, capped at 30 s (150 failures),
  or the address's own delay if longer. The delay is spent before the
  `Incorrect PIN` reply. It never slows a right PIN from an address that is
  not locked out. A success does not reset it (the owner pairing must not
  speed up a neighbour guessing); it is dropped after an hour with no
  failures.
- Guesses in their delay: the PIN is always checked first, and a right PIN
  from an address that is not locked out is accepted at once, whatever any
  other sender (in its network or not) is doing. A wrong one is answered
  only after its delay, so "no answer yet" means "wrong". Each wrong PIN
  therefore holds one of its network's 8 guess tokens until its delay ends,
  even if the socket closes first. A wrong PIN that finds all 8 taken is
  not refused: it waits for a token (then its own delay), and while it waits
  it keeps its socket's pre-auth slot, even after a close, so the waiting
  is bounded by the per-address 4 and per-network 8 socket caps. Its
  reply is `Incorrect PIN`, later; the log says
  `auth: <addr> wrong PIN queued: network <net> has 8 wrong PINs in their delay`.
  There is no token cap across networks (S5d had 16 in all, refused
  unchecked: a peer on two networks could then make the owner's right PIN
  fail with `Too many attempts`).
- IPv4 only, on purpose (review 2026-11-07): the host listens on `0.0.0.0`
  and opens no IPv6 socket; every URL it hands out (QR, `localURLs`,
  Bonjour, Tailscale `100.x`) is IPv4. On IPv6, a peer on the owner's /64
  could fill all 8 of that network's pre-auth slots with wrong PINs queued
  for a token (a queued slot is busy, so never evicted, and is kept after
  its socket closes) and refuse the owner as `NetworkFull`. Before adding an
  IPv6 listener, cap the queued wrong PINs per network below
  `max_unauthenticated_per_network` or reserve a slot for a sender holding
  none. The test `the_real_host_listens_on_ipv4_only` (`app.rs`) pins this.
- No hard lockout per /64 (asked for by a security review, rejected): it
  would let one device lock out every neighbour in its /64, a home LAN or a
  shared Wi-Fi, by guessing wrong 10 times, the denial of service that keying
  the lockout by exact address fixed. A /64 is slowed and capped instead.
- Threat math: the PIN is 8 digits, 10^8 values, so a random search needs
  5 x 10^7 guesses on average. One network gets a new PIN checked only as
  one of its 8 tokens frees (plus at most 8 queued once, its socket cap), and
  the delay reaches its 30 s cap after 150 failures, so it gets about
  8 / 30 s = 16 guesses a minute: 5 x 10^7 / 16 per minute is about 3.1 x 10^6
  minutes, about 6 years on average. Rotating addresses is needed at all
  because each exact address locks out for 15 min after 10 failures. The
  fast first 150 failures per network change nothing that matters (150 of
  5 x 10^7).
- Across networks the rates add up, with no shared cap (one would let the
  attacker refuse the owner, above). An IPv6 /64 is about 16 a minute; an
  IPv4 address is its own network, so its bound is its lockout: 10 failures
  per 15 min, about 40 an hour. A peer that takes a whole IPv4 /24 on the
  LAN (about 250 addresses) gets about 10^4 an hour, 5 x 10^7 / 10^4 = 5000 h,
  about 7 months on average; two /64s get about 32 a minute, about 3 years.
  Each lockout is logged (`auth: <addr> locked`), so such a search is loud.
- There is no lockout across all senders: it would let any LAN peer lock the
  owner out by guessing wrong 10 times.
- An authenticated phone may send 10 messages a second (the Mac's
  `allowMessage`); the rest of that second's messages are dropped and logged
  once, with the first dropped type. Only `auth` is exempt, as on the Mac. The
  phone's connect burst (`device_identity`, `preferences_snapshot`,
  `request_content`, `register_push_device`, `push_preferences`, `phone_log`)
  is 6 counted frames and fits; a phone that sends more than 10 in its first
  second loses the tail on the Mac too.
- `deviceID` is generated once and stored in settings. It is also the mDNS
  TXT `did` value.
- `localURLs`: one `ws://<ipv4>:8765` per non-loopback, up IPv4 interface,
  excluding `100.64.0.0/10` (Tailscale) and link-local `169.254.0.0/16`.
- `displayName`: the PC's hostname. It is never written to tracked files.

### 3.2 Host → phone

| Message | When | Notes |
|---|---|---|
| `layout_update` | After auth; then whenever the broadcast set or any frame changes (poll every 1 s) | See 3.4. Send an identical snapshot no more than once. |
| `frontmost_changed` | When the foreground window changes | `windowId` is the tracked id. When the foreground window is not in the broadcast set the key is **omitted** (`{"type":"frontmost_changed"}`), as Swift encodes it. Feeds the phone's recency stack (Q-88). |
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
| `set_pin` | `{windowId, pinned}` (`SetPinMessage`). As the Mac (`QuipMacApp.swift` `case "set_pin"`): set the window's pin if it differs, persist by the window key (5.1) as `pinned_windows` in `settings.toml` (oldest pin first), then publish a fresh `layout_update` (3.4 `isPinned`, order). An id the phone is not shown is ignored with a debug log line; nothing is sent back, as on the Mac. |
| `set_color` | `{windowId, color?}` (`SetColorMessage`). As `WindowManager.setColor`: `color` normalized by `WindowColor.normalized` (`#RRGGBB`, `#` optional) becomes the window's colour; absent or `null` clears the choice and the dealt colour comes back; a value that is not a hex colour is ignored (debug log, no change). Persisted by the window key as `window_colors`, then a fresh `layout_update`. Unknown id: ignored, as `set_pin`. |
| `request_content` | For a window the phone is shown: `terminal_content` to the asker only, with `content` exactly "Terminal text is not available on Windows yet." Without a reply the phone says "No reply from the Mac for this window" (found in simulator QA). Real terminal text is phase 2. |
| everything else | Ignore (debug log). Includes `image_upload`, `spawn_window`, `duplicate_window`, prompts, push, VibeCut, QA mode, iTerm messages. |

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

- **Broadcast set:** the Mac's `windowsForBroadcast` **mirror-desktop** rule:
  terminals on a visible display, plus windows the user enabled. A "Show all
  apps" tray toggle (off by default) widens it to the `mirrorAllApps` rule
  (every visible window, plus enabled ones). Ported as `broadcast.rs`, held to
  `vectors/broadcast_filter.json`.
  This is a deliberate difference from the Mac default. The Mac's mirror-off
  rule is `enabled || (simulator target && visible)`, and nothing starts
  enabled: the user enables windows in the Mac's own window list. Windows has
  no such list, so mirror-off would show an empty grid after pairing.
  `enabled` itself starts false for every window, as on the Mac, and is
  changed only by `toggle_enabled`.
- **`id`:** a string. HWND values are reused by Windows after a window closes,
  so the id is `w-` + hex of (HWND, process id, window creation order). It
  stays the same for the window's life and never moves to a new window.
- **`frame`:** normalized 0..1 against the window's own display, from
  `DWMWA_EXTENDED_FRAME_BOUNDS` (visible bounds, no invisible resize border).
  The window's display is the one **containing the window's centre** (edges
  max-exclusive), falling back to the primary display and then the first, as
  in `DisplayGeometry` and `ManagedWindow.toWindowState`. Held to
  `vectors/display_geometry.json`.
- **`displayID`:** a stable string for the monitor (the monitor device name
  from `GetMonitorInfoW`, e.g. `\\.\DISPLAY1`, hashed). `isPrimary` is the
  monitor with `MONITORINFOF_PRIMARY`.
- **`monitor`:** the primary display's name. The phone uses it as a same-host
  identity signal, so it must not change when focus moves to another monitor.
- **`spaces`, `spaceID`, `targetKind`, `claudeMode`:** not sent in phase 1
  (Windows virtual desktops are phase 2), but the Rust types carry them as
  optional fields so `wire/layout_update.full.json` round-trips.
- **Always written:** `isThinking`, `isPinned` and `isMinimized` decode as
  optional but the Swift encoder always writes them, so the Rust encoder must
  too (`wire/layout_update.min.json`).
- **`folder` / `project`:** `null` in phase 1. The phone falls back to `app`.
- **`color`:** dealt like the Mac (`Shared/WindowColor.swift`): the first
  palette colour not in use by another window, remembered per window id for
  the window's life. Palette, `normalized`, `hex`, first-unused and
  colours-to-avoid are held to `vectors/window_color.json`; the Mac's
  rotation once every colour is taken is private and has no vector.
- **`isThinking`:** `false` in phase 1.
- **`isPinned` and order:** `true` for a window the phone pinned (`set_pin`,
  3.3). Pinned windows come first in the `windows` list, in pin order (the
  first pin first, a new pin after the pins already there), and the rest keep
  the listing order: `Shared/WindowPinOrder.swift` `apply` + `placingNewPin`.
  The Mac orders its own list this way, so the wire list is already
  pin-ordered; Windows does the same, and `arrange_windows` tiles in that
  order. One difference: the Mac keeps an unpinned window where it was (its
  list has a drag order); Windows has none, so an unpinned window goes back to
  its listing place.
- **`color` chosen on the phone:** a `set_color` choice replaces the dealt
  colour for that window until it is cleared. The dealt colour is kept, so
  clearing gives the same one back. Pins and colours are saved by the 5.1 key
  (exe path + title) and applied to a window with that key the first time it
  is seen after a restart. As with `enabled`, a title that changed since the
  choice was made does not match after a restart. Unlike the Mac, a chosen
  colour does not count as "in use" when a new window is dealt one.

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

**The program in front of the shell.** Windows has no "foreground process
of a console" call, so classify must also look at the shell process's
**child processes** in the same snapshot (`classify::foreground_program`):
walk down from the console's shell; a child that is itself a shell (`pwsh`
started from `cmd`) becomes the shell, and any other child (`python`, `ssh`,
`node`, `wsl`, …; `conhost.exe` / `OpenConsole.exe` excepted) means a
program is running in the shell and the shell is reported `unknown`, so
multi-line text is refused (5.4). Each Windows Terminal tab is one console;
their results go through the same "all the same shell, else unknown" rule. A
pid cycle in the snapshot (pid reuse) ends the walk. The rule is
conservative: a background job started from the shell also reads as
`unknown`, which only costs multi-line sends.

**Minimized windows** report their restored rect
(`GetWindowPlacement().rcNormalPosition`), never the (-32000, -32000)
parking position, and stay in the broadcast set flagged `isMinimized`.

`cliKind` is `shell` for every terminal in phase 1.

**Enabled set persistence:** windows have no stable id across restarts, so the
enabled set is stored by key `exe path + window title` and re-applied on
launch. This is best-effort; a renamed window simply starts at its default.

### 5.2 Arranging

`arrange_windows` tiles the windows the phone currently shows (the
**broadcast set**, 3.4), not only the enabled ones, on the **primary**
display, in broadcast order, over its work area (`MONITORINFO.rcWork`, which excludes the
taskbar). Deliberate difference: the Mac passes the full display frame
(`cgFrame(for:)`) and relies on macOS keeping windows below the menu bar;
Windows lets a window sit under the taskbar, so the work area is used. The
tiling math itself is the Mac's `LayoutCalculator`, held to
`vectors/arrange.json` with the work area as the target rect. (Why the
broadcast set: under the mirror-desktop rule nothing starts enabled, so
"enabled windows only" arranged nothing. An empty broadcast set answers the
Mac's "No enabled windows to arrange".)

- `horizontal`: N equal columns, full height.
- `vertical`: N equal rows, full width.

For each window: if minimized or maximized, restore it first
(`ShowWindowAsync(SW_RESTORE)`, then wait up to 500 ms until it is neither
iconic nor zoomed), and only then read its rects. A minimized window has no
DWM bounds (5.1 lists it with its restored outer rect as both rects), so its
border is known only once it is restored.
Then `SetWindowPos(hwnd, null, x, y, w, h, SWP_NOZORDER | SWP_NOACTIVATE)`,
batched with `BeginDeferWindowPos` / `DeferWindowPos` / `EndDeferWindowPos`.
Windows' docs say to abandon the whole batch when one `DeferWindowPos`
fails, so on any batch failure each window is moved by its own
`SetWindowPos` and gets its own result.

The invisible resize border: target rect R is the visible rect. Read the
window's `GetWindowRect` and `DWMWA_EXTENDED_FRAME_BOUNDS`, take the per-edge
difference, and grow R by it before `SetWindowPos`. Without this, Windows 10/11
leaves 7 px gaps between tiles.

Verify: about 150 ms after the batch, read each moved window's rects again.
A window more than 1 px off its target on any edge gets one more
`SetWindowPos`, computed from its new rects (Windows rescales a window that
lands on a monitor with another DPI). A window still off after that (the app
keeps a minimum size) gets a `websocket.log` line and is not counted as
refused.

A window that does not move (elevated window, UIPI) is skipped and logged to
`injection.log` with `op=arrange kind=unknown detail="elevated or refused"`.
A window whose thread does not respond (`IsHungAppWindow`) is skipped the
same way with `detail="not responding"`: `SetWindowPos` would block the
input thread. The others still move. `layout.rs` (the math) is pure and
unit-tested on the Mac; the restore / measure / move / verify order lives in
`services/arrange.rs`, above `platform/`, so the fake tests it too.

The process is per-monitor DPI aware v2 (manifest), so all coordinates are
physical pixels and no scaling math is needed.

### 5.3 Bringing a window to the foreground

Windows only lets the foreground process, or one it permits, call
`SetForegroundWindow`. Quip is a background tray process, so a bare call
usually just flashes the taskbar button. Sequence:

1. If minimized: `ShowWindow(SW_RESTORE)`.
2. `SetForegroundWindow(hwnd)`. Poll `GetForegroundWindow() == hwnd` every
   20 ms for up to 100 ms; if it is, done.
3. Otherwise `AttachThreadInput(our thread, foreground window's thread, TRUE)`,
   then `BringWindowToTop`, `SetForegroundWindow`, `SetFocus`, then detach
   (always, also on an early return). Poll up to 150 ms. Skip this step when
   the foreground window does not respond (`IsHungAppWindow`): attaching to
   a hung thread can block.
4. Otherwise send a synthetic Alt down/up (`SendInput` `VK_MENU`) and retry
   `SetForegroundWindow` once. This is the documented "last input event"
   allowance. Poll up to 300 ms. The Alt tap reaches the window that was in
   front and can select its menu bar; accepted (M0 needed this step once).
5. The waits are M0's (`spike/src/win.rs` `bring_to_front`), so a refusal
   takes about 550 ms at most. "Foreground" means the handle **and** the pid
   that owned it when listed.

If the window is still not foreground: fail. Never type anyway.

M0 (CI) needed every step: most focus calls succeeded at step 2, and one
(a classic PowerShell window, first focus after launch) only at step 4.

### 5.4 Typing (`send_text`)

1. Look up `windowId`, among the windows the phone is shown (the broadcast
   set) only. Missing → `injection.log` `kind=windowClosed`, `error` to the
   phone, stop. Every platform call names the window by HWND **and** the
   pid that owned it when listed; the platform checks the pid still owns
   the handle before acting (Windows reuses HWNDs) and otherwise answers
   "gone" → `kind=windowClosed`, nothing typed.
2. Foreground it (5.3). Failure → `injection.log` `kind=unknown
   detail="focus refused"`, `error`, stop.
2a. Re-read the shell **now**, on the input thread (the 1 s poll can be
   stale: the user may just have started `python`), with the child-process
   rule of 5.1, and apply step 5 to that answer.
2b. Compare the window's process integrity level (`OpenProcessToken` +
   `GetTokenInformation(TokenIntegrityLevel)` on the pid that owns it) with
   Quip's own. Higher, or not readable: type nothing, log `kind=unknown
   detail="input blocked (elevated window?)"`, send `error`, no
   `send_text_ack`. This is the main guard against elevated windows: the
   `SendInput` docs say neither its return value nor `GetLastError` shows
   that UIPI blocked the input, so step 4's short count cannot be relied on
   alone. The shared injector asks for this check once, after focus and
   before the first input, so a backend cannot skip it.
3. Type the text with `SendInput`, one `KEYEVENTF_UNICODE` down/up pair per
   UTF-16 code unit (surrogate pairs as two units, which Windows reassembles,
   so emoji arrive intact). Batches of at most 64 inputs per `SendInput` call,
   with a 5 ms pause between batches, as in M0.
4. Before each batch **and before every key** (Shift+Enter, and the Return
   after the 30 ms pause), check the window (handle and pid) is still
   foreground. The shared injector makes this check, not the Win32 code, so
   a backend cannot skip it. If focus moved mid-text, stop typing, log
   `kind=unknown detail="focus lost after N chars"`, send `error`. What was
   already typed stays (the same as a human losing focus); nothing goes to
   the other window after the check fails. `SendInput` returns how many
   inputs it inserted; a short count stops typing at once, logs
   `kind=unknown detail="input blocked (elevated window?)"`, sends `error`,
   and no `send_text_ack` (a second guard; step 2b is the first).
5. **Newlines: same rules as the Mac's `MultiLineSendPolicy`** (US-008 there).
   Ported as `multiline_policy.rs` and driven by the same shared vectors (10.2):
   - One trailing line break is stripped and the text counts as single-line.
     It is never typed as an Enter.
   - Single-line text: typed, then Return only when `pressReturn`.
   - Multi-line text into a shell (every terminal in phase 1, since
     `cliKind` is `shell`): it must land on the command line **without
     running**, and Return is **never** pressed, even when the phone asked.
     `latency.log` gains ` multiline_guard=1 lines=N` (counts only, never text).
   - **Decided by M0** (CI run 42319562616, evidence
     `docs/superpowers/evidence/q91/m0-ci-42319562616.txt`): in PowerShell
     (Windows Terminal and classic console, PSReadLine 2.4.5) each inner line
     break is sent as **Shift+Enter**: nothing ran early and one Return ran
     every line. Clipboard paste is not used: in Windows Terminal one Return
     ran only one of two pasted lines. In `cmd.exe` both Shift+Enter and paste
     ran lines early, so multi-line text to `cmd.exe` (and to PowerShell
     without PSReadLine) is refused with an `error` and an `injection.log`
     line, `kind=unknown detail="multi-line not safe in this shell"`. The
     host therefore needs the shell, not just "terminal": `classify.rs`
     reports `powershell | pwsh | cmd | unknown`, and an `unknown` shell is
     treated like `cmd`.
6. `pressReturn` (when the policy allows it): a 30 ms pause, then `VK_RETURN`
   down/up.
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

Keys are virtual-key `SendInput` events, one call per chord: `VK_RETURN`,
`VK_ESCAPE`, `VK_TAB`, `VK_BACK`, and `VK_UP` / `VK_DOWN` / `VK_RIGHT` with
`KEYEVENTF_EXTENDEDKEY` (without it they are the numeric keypad's keys).
Ctrl+C and Ctrl+D are `VK_CONTROL` + `C` / `D`; Shift+Tab is `VK_SHIFT` +
`VK_TAB`. Modifiers go down first and up last, in reverse order. `y`, `n`
and `cls` are typed as text, like `send_text`.

Every key action foregrounds the window first (5.3) and checks its
integrity level (5.4 step 2b), with the same failure rules.

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
New PIN (disconnects phones)
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
- **New PIN:** regenerates and saves the PIN, then closes every connected
  socket, authenticated or not, so a phone that should not be there loses
  its session at once; every phone must pair again with the new PIN.
  **Deliberate difference from the Mac**, where connected phones stay
  connected (security review of 0966c3b: on Windows "New PIN" is the one
  tray action against a suspected intruder). The menu label says so.
- **Pairing QR window:** a small top-level window in Quip's own process (so
  the lister never lists it) with the QR, the URL and the PIN as text; Esc
  or the close button closes it, "Show pairing QR…" again reuses it, and a
  New PIN refreshes it.
- **Bonjour:** the real host advertises `_quip._tcp.` in `local.` as
  `Quip <PC name>` with TXT `did=<deviceID>` (the Mac's
  `BonjourAdvertiser`), on the LAN (RFC 1918) addresses of non-virtual
  adapters only, from start until Quit. A failure is logged and the host
  keeps running. `--fake-platform` never advertises. With no LAN address at
  start it does not advertise and today never retries; S12 adds a retry when
  a LAN address appears.
- No console window: `#![windows_subsystem = "windows"]`.

## 7. Settings

`%APPDATA%\Quip\settings.toml`:

```toml
pin = "12345678"
device_id = "<uuid>"
port = 8765
show_all_apps = false
enabled_windows = [ { exe = "C:\\...\\WindowsTerminal.exe", title = "..." } ]
disabled_windows = [ ]   # a toggle-off also survives a restart
```

The file is created on first run. A file that cannot be parsed, or holds
unusable values (empty PIN, bad UUID, port 0), is renamed to
`settings.toml.bad` and a new one is made (new PIN and device id), with a
`websocket.log` line saying so. A file that exists but cannot be read (a
sharing violation from antivirus or backup) is retried 3 times, 50 ms apart,
then Quip stops with an error: it never makes a new PIN or device id because
of a read error, since that would unpair every phone. A failed save is logged
as `[ERROR] settings NOT saved`.

## 8. Logs

`%LOCALAPPDATA%\Quip\Logs\`, append-only, same line formats as the Mac
(`CLAUDE.md` log section):

- `websocket.log`: listen, connect, auth ok/fail, oversized drop, disconnect.
- `injection.log`: failed injections only, Mac format:
  `DROPPED op=… window=… app=… kind=… msg="…" [detail="…"]`.
- `phone.log`: the phone's `phone_log` lines, receive time first.
- `latency.log`: `send_text` and `quick_action` timings (counts and ids
  only, never text; a failed send is a `success=0` line here as well as a
  `DROPPED` line in `injection.log`).
- `selftest-<time>.txt`: one new file per `--selftest` run (10.5), never
  overwritten.

`websocket.log` also carries the mDNS lines (6) and, as the first line of
each start, the build stamp (9). Debug-level lines (ignored message types)
go to no file; `--fake-platform` prints them to stderr.

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
The script holds the allowed names as a list (plus any `api-ms-win-*` API
set) and fails on any other name, so a new dependency is a reviewed one-line
change. It also checks the PE subsystem is `Windows GUI` and that the commit
stamp is in the exe, and never copies the exe anywhere but `dist/`.

Build stamp: `Quip.exe --version` prints `Quip for Windows <version>
(<12-char git sha>)`, with `-dirty` after the sha when the tree had
uncommitted changes. The same string is the tray icon's tooltip, the first
`websocket.log` line of each start and the `--selftest` header. The exe also
carries a version resource and the Quip icon (`.ico`), so Explorer shows
both.

The `.exe` is unsigned. On the PC (owner steps, in `QuipWindows/README.md`):

1. Copy `Quip.exe` to `%LOCALAPPDATA%\Programs\Quip\`.
2. Double-click it. SmartScreen says "Windows protected your PC": click
   More info → Run anyway (once). It asks only for a file marked as
   downloaded (a cloud drive marks it; a USB copy usually does not), and
   again for each new build so marked.
3. Windows Defender Firewall asks about network access: allow on **Private**
   networks. If the home network is marked Public, change it to Private in
   Settings → Network, or the phone cannot connect. The rule is for the
   exe's path: an update copied over the same path keeps it. Dismissing the
   prompt can leave a Block rule for Quip, which must be removed.
4. Tray icon → Show pairing QR, scan from the phone (or add the backend by
   IP and PIN).
5. Tray icon → Start with Windows, if wanted.
6. Over Tailscale: Tailscale sets its own adapter's network profile to
   Private. Bonjour does not cross Tailscale, so add the backend on the
   phone by hand as `ws://<the PC's 100.x address>:8765` with the PIN (the
   tray menu shows the Tailscale address).

Troubleshooting (README): `netstat -an | findstr 8765` shows
`0.0.0.0:8765 … LISTENING` while Quip runs (IPv4 only, 3.1) and one
`ESTABLISHED` line per connected phone; no `ESTABLISHED` line while the phone
tries means the firewall or the network profile. Then read `websocket.log`
(connects, auth, mDNS) and `injection.log` (failed sends), from Tray →
Open logs folder.

Getting the `.exe` to the PC: any file copy (USB, cloud drive, a share).
Choosing a transfer method is the owner's call and is not part of the build.

## 10. Tests: same bar as the Mac and iPhone

The Mac and iPhone suites hold to five habits. The Windows host keeps all five:

1. **Every pure rule has its own test file** (Mac: `MultiLineSendPolicyTests`,
   `MessageDedupeTableTests`, `AuthThrottleTests`, …, 89 files; iPhone: 106).
2. **Peers share one source of truth.** `Shared/Tests/` compiles into both
   apps, and `Shared/Tests/Fixtures/project_name_vectors.json` is already read
   by Quip and VibeCut. Windows joins through vector files, not copied numbers.
3. **Mutation checks.** For each pure rule, break the key line and confirm a
   test fails; record the results in the commit message. A survivor means a
   missing test, added before the commit.
4. **A fake peer for UI checks** (`tools/fake-mac` + `tools/qa/*.sh`): the
   phone is driven in a simulator against a stand-in, never against real data.
5. **One gate** (`tools/check.sh`, the pre-commit hook and CI) that runs every
   affected suite and never reports an unrun suite as green.

### 10.1 Code rules (checked, not hoped for)

- `cargo fmt --check` and `cargo clippy --all-targets -- -D warnings` pass, on
  macOS and for `--target x86_64-pc-windows-gnu`.
- Crate-level `#![deny(clippy::unwrap_used, clippy::expect_used)]` outside
  tests: a panic in the host is a dead remote for the user.
- Every `unsafe` block carries a `// SAFETY:` comment saying why it holds
  (`clippy::undocumented_unsafe_blocks` = deny).
- All Win32 calls live in `platform/win32/`. Nothing above `platform/` calls
  `windows::` directly, so everything above it runs on the Mac.
- No blocking call on the tray thread or the tokio reactor (lesson of
  `project_quip_hangs_not_crashes`: every Mac "crash" was a blocked main
  thread). Platform calls go to the platform thread through a channel.

### 10.2 Shared vectors (the parity contract)

New tracked folder `Shared/Tests/Fixtures/wire/` and `Shared/Tests/Fixtures/vectors/`.
The Swift side **writes or checks** each file; the Rust side **reads** it. A
change on either side that breaks the other fails a test on that side.

| File | Swift side (in `Shared/Tests/`, runs in Mac + iOS suites) | Rust side (`QuipWindows/tests/`) |
|---|---|---|
| `wire/<type>.json`, one per message in 3.1-3.3, each with a "minimal" and a "full" variant | `WireFixtureTests`: each file decodes with the `Shared/MessageProtocol.swift` type, and re-encoding gives the same keys and value types | decode each into the Rust type; encode the Rust value and compare keys/types with the file |
| `vectors/multiline.json` | `MultiLineSendPolicy` cases (Mac suite, since it is Mac-only code): text, cliKind, pressReturn → normalized text, multi-line?, Return?, line count, latency suffix | `multiline_policy.rs` gives the same outputs |
| `vectors/display_geometry.json` | `DisplayGeometry` normalization cases: display rects, window rect → `frame`, `displayID`, `spanFrame`, `spanAspect` | `geometry.rs` gives the same numbers (±1e-9) |
| `vectors/broadcast_filter.json` | `windowsForBroadcast` cases (terminal, enabled, on screen, show-all) | `broadcast.rs` gives the same id list |
| `vectors/arrange.json` | `LayoutCalculator` (`QuipMac/Models/LayoutPreset.swift`) horizontal/vertical for 1-6 windows over a work area | `layout.rs` gives the same rects (±1 px) |
| `vectors/pairing.json` | `PairingPayload` encode/parse | `pairing.rs` round-trips |
| `vectors/window_color.json` | `WindowColor` id → color | `window_color.rs` same color |
| `vectors/injection_log.json` | `KeystrokeInjector` `DROPPED` line builder (`InjectionLogTests`): formatting and escaping | `injection_log.rs` same line |

Writing the vectors is a `Shared/` (and `QuipMac/`) change, so that commit pays
for the Mac and iPhone suites. It adds tests only; no app code changes.

### 10.3 Rust unit tests, mapped to the Mac's

Each Windows module gets the cases its Mac counterpart has, by name, plus the
Windows-only ones. "Mac file" is where to copy the cases from.

| Windows module | Mac / Shared test file to match | Windows-only cases |
|---|---|---|
| `protocol/` | `Shared/Tests/MessageProtocolTests.swift` (147 tests; port the phase 1 messages) | unknown type ignored; bad JSON ignored; oversized frame dropped and logged |
| `auth_throttle.rs` | `AuthThrottleTests` | — |
| `pin_store.rs` | `PINStoreTests` | 8 digits; corrupt settings → `.bad` + new PIN |
| `dedupe.rs` | `MessageDedupeTableTests` | cap 256, oldest evicted |
| `multiline_policy.rs` | `MultiLineSendPolicyTests` (+ vectors) | `\r\n`, U+2028 count as one break |
| `injection_log.rs` | `InjectionLogTests` (+ vectors) | `kind` closed vocabulary; `op`/`window` never contain spaces |
| `quip_log.rs` | `QuipLogTests`, `LogRotationTests` | 10 MB rotation; read-only dir and full disk never panic (lesson of `99927a4`) |
| `phone_log.rs` | `PhoneLogSinkTests` | — |
| `secret_redactor.rs` | `LogRedactorTests` | — |
| `local_addresses.rs` | `LocalAddressesTests` | Tailscale `100.64/10` and `169.254/16` excluded from `localURLs` |
| `single_instance.rs` | `SingleInstanceGuardTests` | (Win32, 10.5) |
| `pairing.rs` | `PairingQRTests`, `PairingPayloadTests` (+ vectors) | — |
| `geometry.rs`, `broadcast.rs`, `layout.rs` | `DisplayGeometryTests`, `MirrorDesktopFilterTests`, `ArrangeLayoutMappingTests`, `ArrangeOutcomeTests` (+ vectors) | border compensation; work area excludes taskbar on any edge |
| `frontmost.rs` | `FrontmostMatchTests` | untracked foreground → `windowId: null` |
| `window_id.rs` | — | HWND reused by a new process → new id; same window across polls → same id |
| `classify.rs` | `CLIKindClassifierTests` (shape) | WT, conhost + powershell/pwsh/cmd, unknown console, elevated (no process access) |
| `keys.rs` | quick-action key table in `QuipMacApp.swift` | every action in 5.5 maps; unknown → error |
| `router.rs` | `SendTextSelfHealTests` (classify shape) | each message in 3.3 → the right backend call, against `platform/fake.rs` |
| `typing_plan.rs` | `KeystrokeInjectorWriteExpressionTests` (shape) | UTF-16 surrogate pairs; 64-input batches; focus check between batches |
| `ws_server.rs` | `PreHandshakeReapPolicyTests`, `ConnectionOutcomeTests`, `ListenPortTests` | port in use → clear error, tray says so |

Target: every Mac case above has a Rust twin, so the Windows rules cannot quietly
differ.

### 10.4 Integration tests on the Mac (fake platform)

`QuipWindows/tests/`, real `ws_server` on a random loopback port, real
tokio-tungstenite client, `platform/fake.rs` as the backend:

- Auth: wrong PIN → `success:false` after the delay; right PIN →
  `auth_result`, `device_identity` (`deviceKind:"windows"`), `layout_update`,
  in that order; nothing before auth gets a reply; 10 failures lock out; a
  locked-out host is refused even with the right PIN.
- Broadcast: a fake window opening, moving, closing → one `layout_update`
  each, none when nothing changed; two phones both get them.
- `send_text`: single-line + Return → fake records text then Return;
  multi-line + Return → Return dropped, `latency.log` suffix; duplicate
  `messageId` → typed once; window gone → `error` + `injection.log` line,
  nothing typed; `send_text_ack` only on success.
- Focus refused (fake returns refusal) → nothing typed, `error`, log line.
- Hang guard: a fake `send_text` that blocks 5 s does not delay a
  `heartbeat` or another client's `layout_update` by more than 100 ms.
- Heartbeat every 15 s (clock injected, no real sleep).
- `preferences_snapshot` → stored; `preferences_request` → returned as-is.

### 10.5 Win32 tests on real Windows (CI + the PC)

`QuipWindows/tests/win32_*.rs`, `#[cfg(windows)]`, gated by
`QUIP_WIN_UI=1` because they open windows and type:

- Listing: spawn `powershell.exe` (conhost) and, when installed,
  `wt.exe`; both appear as terminals with the right `app`; Notepad appears as
  non-terminal; a cloaked/tool window does not.
- Own windows only: every window a test opens carries a title marker unique
  to the run (`selftest::own::marker`), set by cmd's `title`, PowerShell's
  `$Host.UI.RawUI.WindowTitle` (also a Windows Terminal tab's title, which
  the window shows) or, for Notepad, the name of a temp file it opens. A
  test takes, and closes, only a new window carrying its marker, as
  `--selftest` does, so on a PC in use it never closes the user's window.
- The "Start with Windows" round trip (`--selftest`) writes, reads and
  deletes a value of its own, `Quip-selftest-<pid>`; the user's `Quip` value
  is only read, and the case fails if it changed.
- Displays: at least one, exactly one primary, frames inside 0..1.
- Arrange: two spawned windows, horizontal → visible rects (DWM bounds)
  touch with ≤1 px gap and fill the work area; vertical the same.
- Focus: spawned window behind another → `foreground()` succeeds, then
  `GetForegroundWindow` is it.
- Typing: type a random marker plus emoji into a spawned PowerShell that
  runs `Read-Host | Out-File $env:TEMP\quip-marker.txt`, press Return, read the
  file: equal to the marker.
- Multi-line: send two lines with Return requested; the marker file must
  NOT exist after 2 s (nothing ran), then a Return runs both.
- Wrong-window guard: focus stolen between batches → typing stops; the
  other window received nothing.
- Single instance: a second process exits within 1 s.

Where they run:

- **CI**, new job `cargo test (QuipWindows)` on `windows-latest`: fmt, clippy,
  unit + integration tests always; the Win32 UI tests with `QUIP_WIN_UI=1`.
  GitHub's Windows runners have an interactive desktop, and M0 proved
  focus, `SendInput` typing and Windows Terminal all work there (run
  42319562616). Launch consoles with `cmd /c start` and null stdio: with the
  runner's redirected stdio, a directly spawned `conhost.exe` becomes a
  pseudo-console with no window.
- **On the PC**: `Quip.exe --selftest` runs the same cases through the real
  app code and writes `%LOCALAPPDATA%\Quip\Logs\selftest-<time>.txt`: one
  `PASS`/`FAIL` line per case plus Windows version, display count and DPI.
  The owner sends the file back; it is stored under
  `docs/superpowers/evidence/q91/` (redacted: no host name, user name or IPs).

### 10.6 Phone against the host, in the simulator

`tools/fake-mac` exists so the phone can be checked without a real Mac. The
Windows host gets the same: `quip-windows --fake-platform` builds and runs **on
the Mac** with `platform/fake.rs` and `tools/fake-windows/fixture.json`. It
follows every fake-mac safety rule: 127.0.0.1 only, never port 8765, no mDNS,
fixed fake device id and a monitor name (`FakeWindows Display`) that can never
equal a real host's, no stored secrets, `preferences_request` answers "no
backup".

Scenario scripts `tools/qa/q91-*.sh` (same style as `q88-*.sh`), each with a
screenshot saved as evidence, on a simulator of our own (never D8C5154B while
another session uses it):

| Script | Checks |
|---|---|
| `q91-pair.sh` | Pair by PIN; the backend row appears; the grid shows the fixture's terminals with app names and no folder |
| `q91-layout.sh` | Fake moves/adds/removes a window; the grid follows within 2 s |
| `q91-send.sh` | Dictation text + Return from the phone; the fake's log shows text then Return; multi-line shows the guard |
| `q91-keys.sh` | Quick buttons (Return, Ctrl+C, Esc, ↑/↓) arrive as the right `quick_action` |
| `q91-arrange.sh` | Arrange side by side / stacked sends `arrange_windows` with the right `layout` |
| `q91-two-backends.sh` | fake-mac and fake-windows paired at once; switching between them keeps each grid |

This is the "simulator check before done" rule (owner caught Q-72 without it)
applied to the Windows host.

### 10.7 Mutation checks

`cargo-mutants` on the pure modules (`protocol`, `auth_throttle`, `dedupe`,
`multiline_policy`, `injection_log`, `geometry`, `broadcast`, `layout`,
`window_id`, `classify`, `keys`, `router`, `typing_plan`). Each milestone's
commit message lists caught / missed per module. A missed mutant gets a test
before the commit, or a one-line reason it is equivalent.

### 10.8 Gate wiring

- `.github/scripts/changed-scopes.sh` gains scope `windows` for
  `QuipWindows/**` and `Shared/Tests/Fixtures/**`; `changed-scopes-test.sh`
  gains cases for it.
- `tools/check.sh`, scope `windows`, on the Mac: `cargo fmt --check`, clippy
  (host and windows-gnu), `cargo test`, `cargo check --target
  x86_64-pc-windows-gnu`. Missing toolchain → reported as SKIPPED with the
  install commands, never green.
- The pre-commit hook gets this for free (it runs `check.sh` on staged paths).
- CI job from 10.5.

## 11. Acceptance on the PC (owner)

Run after M4 and again after M5. `--selftest` covers the mechanics; these are
the things only a person at the PC can see.

1. Run `Quip.exe`: tray icon appears, no console window. A second launch does
   nothing. The icon's tooltip shows the version and commit of the build
   that was copied (9).
2. `Quip.exe --selftest`: every line PASS. Send the file back.
3. Phone pairs with the QR. The PC shows as a second backend; the Mac backend
   keeps working. With the phone off Wi-Fi, a backend added by hand as
   `ws://<100.x>:8765` (Tailscale, 9 step 6) also connects.
4. Open PowerShell in Windows Terminal and in a classic window. Both show on
   the phone as terminals within 2 s. Close one: gone within 2 s.
5. Arrange side by side, then stacked, from the phone: no gaps (at most 1 px
   between tiles, none under the taskbar), also with one of the windows
   minimized or maximized first. The phone build tested so far (1.5.7) has
   no control that sends `arrange_windows` (`tools/qa/q91-arrange.sh` sends
   it from a scripted peer); if the owner's build has none either, this
   check is run the same way, with the phone paired.
6. Dictate "Get-Date" with Return into each: runs in that window, no other.
7. Dictate two lines with Return: both sit in the prompt, nothing runs.
8. Ctrl+C from the quick buttons stops `ping -t localhost`.
9. Administrator PowerShell: sending text types nothing anywhere, the phone
   shows an error, `injection.log` has a line with
   `detail="input blocked (elevated window?)"`.
10. Reboot with Start with Windows on: Quip is in the tray, the phone
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

## 14. Milestones and gates

All work stays on `eb-branch`; every milestone is pushed when its gate passes.

| # | Scope | Proof |
|---|---|---|
| M0 | Spike (throwaway `QuipWindows/spike/`): foreground workaround, `SendInput` unicode, Shift+Enter vs clipboard paste in PowerShell (WT + conhost) and cmd; same on a CI `windows-latest` runner | Spike report from the PC and from CI; decision written into 5.3/5.4 and 13 |
| M1 | Crate, protocol, shared vectors (Swift + Rust), server, auth, router, pure rules, fake platform, `--fake-platform`, gate wiring | `check.sh` green incl. Mac + iOS suites for the vectors; `q91-pair/layout/send/keys/arrange/two-backends` screenshots |
| M2 | Win32 listing, displays, frontmost, tray, single instance, mDNS, QR | CI Windows green; `--selftest` listing cases PASS on the PC; owner pairs the phone and sees the grid |
| M3 | Arrange | selftest arrange PASS; owner check 5 |
| M4 | Focus, typing, keys, multi-line rule | selftest typing/multi-line/guard PASS; owner checks 6-9 |
| M5 | Logs, autostart, README, release stamp | full selftest PASS; full acceptance (11) |

Gate for every milestone, in order:

1. `tools/check.sh` green (and CI green once pushed). An unrun suite is
   reported as skipped, never green.
2. Mutation results (10.7) in the commit message.
3. **Independent review**: a reviewer agent gets the diff and this spec, not
   the builder's summary. Every finding is fixed or answered in the commit
   message. M4 also gets a silent-failure pass (typing into the wrong window
   is the worst failure this host can have).
4. Evidence (screenshots, selftest output) saved under
   `docs/superpowers/evidence/q91/`, linked from the board row.
5. Board Q-91 row updated; commit; push to `origin/eb-branch`.
