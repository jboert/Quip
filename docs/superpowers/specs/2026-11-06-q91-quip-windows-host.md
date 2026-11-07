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

M0 (CI) needed every step: most focus calls succeeded at step 2, and one
(a classic PowerShell window, first focus after launch) only at step 4.

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
   nothing.
2. `Quip.exe --selftest`: every line PASS. Send the file back.
3. Phone pairs with the QR. The PC shows as a second backend; the Mac backend
   keeps working.
4. Open PowerShell in Windows Terminal and in a classic window. Both show on
   the phone as terminals within 2 s. Close one: gone within 2 s.
5. Arrange side by side, then stacked, from the phone: no gaps.
6. Dictate "Get-Date" with Return into each: runs in that window, no other.
7. Dictate two lines with Return: both sit in the prompt, nothing runs.
8. Ctrl+C from the quick buttons stops `ping -t localhost`.
9. Administrator PowerShell: sending text types nothing anywhere, the phone
   shows an error, `injection.log` has a line.
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
