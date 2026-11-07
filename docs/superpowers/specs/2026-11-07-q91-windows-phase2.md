# Q-91: Quip for Windows: phase 2 spec

Status: design, not built. Phase 1 is `docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`
(called "the phase 1 spec" below): pairing, grid, arrange, typing, keys,
release build, slices S1-S12 in `docs/superpowers/plans/2026-11-06-q91-windows-host.md`.
This document covers everything after it.

Rules that carry over from phase 1, unchanged:

- The **unmodified** iPhone app is the client. A feature that needs a phone
  change is out of scope here and becomes its own ticket.
- `QuipLinux/` and `QuipAndroid/` are another developer's lane. QuipLinux is
  read for reference only; code is copied from it, never edited or shared.
- Same test bar as phase 1 (its section 10): pure rules on the Mac, shared
  vectors, fake platform, Win32 CI with `QUIP_WIN_UI=1`, `--selftest` on the
  PC, simulator QA against `--fake-platform`, `cargo-mutants`.
- All Win32 / WinRT calls stay in `platform/win32/`. No blocking call on the
  tray thread or a tokio worker.

Facts about existing code are cited as `file:line`. Anything not checked in
code is marked **(guess)**.

## 1. Where phase 1 stops

### 1.1 What the Windows host decodes

`QuipWindows/src/protocol/messages.rs:471` (`HANDLED_TYPES`) lists 14 types:
`auth`, `heartbeat_ack`, `select_window`, `send_text`, `quick_action`,
`arrange_windows`, `minimize_window`, `close_window`, `phone_log`,
`preferences_snapshot`, `preferences_request`, `request_content`, and
(since 2026-11-07, 2.14) `set_pin`, `set_color`. The enum is
`Incoming` at `messages.rs:436`. Everything else is decoded as `Unknown` and
ignored (`messages.rs:457`).

### 1.2 What the Mac handles that Windows does not

From the two Mac dispatch switches (`QuipMac/QuipMacApp.swift:522` per
connection, `QuipMacApp.swift:1663` general) and the server itself
(`QuipMac/Services/WebSocketServer.swift:1318`):

| Phone → host type | Mac handler | Covered in this spec |
|---|---|---|
| `device_identity` | `WebSocketServer.swift:1318` (names the phone in the Mac UI) | 2.13 (tray shows phone names) |
| `set_pin` | `QuipMacApp.swift:526` | 2.14 (done in phase 1, 2026-11-07) |
| `set_color` | `QuipMacApp.swift:537` | 2.14 (done in phase 1, 2026-11-07) |
| `set_qa_pair` | `QuipMacApp.swift:544` | 2.4 |
| `clear_qa_pair` | `QuipMacApp.swift:550` | 2.4 |
| `vibecut_status_request` | `QuipMacApp.swift:567` | 4 (not planned) |
| `claude_preview_request` | `QuipMacApp.swift:578` | 4 (not planned) |
| `image_upload` | `QuipMacApp.swift:1916` | 2.2 |
| `stt_started` | `QuipMacApp.swift:2107` | 2.6 |
| `stt_ended` | `QuipMacApp.swift:2162` | 2.6 |
| `duplicate_window` | `QuipMacApp.swift:2239` | 4 (not planned) |
| `spawn_window` | `QuipMacApp.swift:2316` | 4 (not planned) |
| `scan_iterm_windows` | `QuipMacApp.swift:2342` | 4 (Mac only) |
| `request_diagnostics` | `QuipMacApp.swift:2345` | 2.7 |
| `request_log_tail` | `QuipMacApp.swift:2353` | 2.7 |
| `paste_prompt` | `QuipMacApp.swift:2358` | 4 (later) |
| `put_prompt` | `QuipMacApp.swift:2367` | 4 (later) |
| `delete_prompt` | `QuipMacApp.swift:2388` | 4 (later) |
| `sync_vibecut` | `QuipMacApp.swift:2405` | 4 (not planned) |
| `register_push_device` | `QuipMacApp.swift:2414` | 2.5 |
| `push_preferences` | `QuipMacApp.swift:2420` | 2.5 |
| `attach_iterm_window` | `QuipMacApp.swift:2442` | 4 (Mac only) |
| `claude_preview_dismiss` | `QuipMacApp.swift:2484` | 4 (not planned) |
| `reliability_turn_on` | `QuipMacApp.swift:2490` | 4 (not planned) |
| `set_claude_previews` | `QuipMacApp.swift:2493` | 4 (not planned) |
| `open_mac_settings_pane` | `QuipMacApp.swift:2498` | 4 (Mac only) |
| `audio_chunk` | `QuipMacApp.swift:2504` | 2.6 |

`quick_action` sub-actions the Mac has and Windows answers with
"Not supported on Windows yet" (`QuipWindows/src/services/keys.rs:89`):
`set_plan_mode` / `set_auto_accept_mode` / `set_normal_mode`
(`QuipMacApp.swift:3827`-`3831`), `scroll_page_up|down|top|bottom`
(`QuipMacApp.swift:3845`), `restart_claude` (`QuipMacApp.swift:3867`),
`select_N` and `select_multi:` (`QuipMacApp.swift:3231`, `3248`), and the others
named in `keys.rs:7`-`9`.

Host → phone messages the Mac sends and Windows never does: `state_change`
(`QuipMacApp.swift:719`), `terminal_content` with real text, `screenshot` and
`urls` (`QuipMacApp.swift:2233`), `image_upload_ack` / `image_upload_error`,
`qa_pair_lost`, `whisper_status`, `transcript_result`, `tts_audio`,
`prompt_library`, `project_directories`, `mac_build`, `mac_permissions`,
`reliability_status`, `claude_previews`, `diagnostics_bundle`, `log_tail`.

### 1.3 Already done in phase 1 (no phase 2 work)

- **Prefs backup.** `preferences_snapshot` is stored per `deviceID` and
  `preferences_request` gets `preferences_restore` back, to the asking phone
  only (`QuipWindows/src/services/prefs_store.rs:1`-`8`,
  `QuipWindows/src/services/router.rs:7`, `router.rs:121`-`122`). The blob is
  stored as-is, so the phone's `savedAt` freshness stamp survives the round
  trip.
- **`phone_log`.** Appended to `phone.log` (`router.rs:120`).
- **Dictation.** The phone picks its PTT path with
  `selectPTTPath` (`QuipiOS/Services/SpeechService.swift:518`): remote only
  when the host has said `whisper_status` ready, else local. Windows never
  sends `whisper_status`, so the phone dictates on-device and sends
  `send_text`. That already works with phase 1 typing.
- **16 MiB cap.** `QuipWindows/src/protocol/limits.rs:3` matches
  `WSLimits.maxMessageBytes` (`Shared/Constants.swift:20`), with a 64 KiB
  protocol headroom so an oversize frame is dropped and logged, not a dead
  socket (`limits.rs:8`-`14`).

## 2. Features

Each feature lists: Mac, Windows, phone impact, tests, risks, size
(S = under a day, M = 2-4 days, L = a week or more; all **(guess)**), and
priority (P1 = do next, P2 = valuable, P3 = only if asked, Out = not in
phase 2).

### 2.1 Terminal text read (`request_content`)

**Mac.** `QuipMacApp.swift:2169`-`2236`: throttle 0.5 s per window
(`:2172`-`2176`), read the pane with `KeystrokeInjector.readContentDetailed`
(`QuipMac/Services/KeystrokeInjector.swift:1347`) with full scrollback, tidy
and tail it, redact secrets, extract URLs (`TerminalURLExtractor`), detect the
autosuggest ghost text (`Shared/AutosuggestDetector.swift`), attach a
screenshot, broadcast `TerminalContentMessage`
(`Shared/MessageProtocol.swift:709`). A failed read sends a bracketed reason
in `content`, never an empty string.

**Windows today.** `router.rs:398`-`404` answers `terminal_content` with
`TerminalContent::NOT_AVAILABLE`, "Terminal text is not available on Windows
yet." (`messages.rs:296`). The Rust `TerminalContent` struct has only
`windowId`, `content`, `hasAutosuggest` (`messages.rs:285`-`292`).

**Windows, phase 2.**

1. **Windows Terminal:** UI Automation. `CoInitializeEx` (MTA) on the platform
   thread, `CUIAutomation` → `ElementFromHandle(hwnd)` → find the descendant
   that supports `UIA_TextPatternId` (the terminal control) →
   `IUIAutomationTextPattern::DocumentRange` → `GetText(-1)`. WT is a UIA
   text provider for screen readers. **(guess)**: the document range covers
   the scrollback, not only the viewport; spike it.
2. **Classic console (conhost):** first choice is the console API, not UIA:
   `AttachConsole(shell_pid)`, `GetConsoleScreenBufferInfo`,
   `ReadConsoleOutputCharacterW` over the buffer, `FreeConsole`. A process can
   be attached to one console at a time, so this runs on its own thread,
   one window at a time. Fallback: UIA `TextPattern` on the
   `ConsoleWindowClass` HWND (conhost has a UIA provider on Windows 10 1809+
   **(guess)** on the exact build).
3. Port the Mac rules as pure Rust, held to new shared vectors:
   tidy + tail (`TerminalContentWindow`, tested in
   `QuipMac/Tests/TerminalContentWindowTests.swift`), URL extraction
   (copy `QuipLinux/src/services/terminal_url_extractor.rs`), the 0.5 s
   throttle, `SecretRedactor` (already `services/secret_redactor.rs`).
4. Add `screenshot`, `urls`, `autosuggest` to the Rust `TerminalContent` as
   optional fields (wire fixture `terminal_content.full.json`).
5. Failure text in `content`, as the Mac does: "[Quip could not read this
   window]" for a UIA/console failure, with an `injection.log`-style line in a
   new `content.log` **(decision: new log or reuse `websocket.log`)**.

**How QuipLinux did it.** tmux / Konsole D-Bus text first, a screenshot when
there is no text (`QuipLinux/src/ui/main_window.rs:1256`-`1295`,
`QuipLinux/src/platform/traits.rs:115`-`132`).

**Phone impact.** None. The phone already renders `terminal_content` from
any host.

**Tests.** Unit (Mac): tidy/tail, URL extractor, throttle, redaction, all
against vectors written from the Swift side. Integration (fake platform): a
fake window with fixed text → `terminal_content` with that text, redacted;
throttled second request gets nothing. Win32 CI: spawn `powershell.exe`
(conhost) and `wt.exe`, write a run marker, `request_content` must contain it.
Selftest: same on the PC. Simulator: `q91-content.sh` shows the fixture's text
in the phone's terminal view.

**Risks.** UIA calls can block for seconds on a hung app: give each read a
deadline and run it off the platform thread used for typing (a slow read must
never delay a keystroke). WT tabs: UIA returns the active tab's text only
**(guess)**; see 2.12. COM apartment rules on the worker thread. Large
scrollback: cap what is read (the Mac tails it).

**Size.** L. **Priority.** P1, first. Everything in 2.8 and 2.9 depends on it.

### 2.2 Image upload and paste (`image_upload`)

**Mac.** `QuipMacApp.swift:1916`-`2055`. Resolve the window first; save the
decoded bytes under `~/Library/Caches/Quip/uploads/` with a path-traversal
check (`QuipMac/Services/ImageUploadHandler.swift:73`-`123`); focus; then
route by CLI (`QuipMacApp.swift:3334`): **type the saved path plus a space**
by default (Claude Code takes a path), or put the image on the clipboard and
paste (`KeystrokeInjector.swift:434`) only for Codex in iTerm2. Reply
`image_upload_ack` (with `savedPath`) or `image_upload_error` (with a
reason).

**Windows, phase 2.**

1. Port the save rules from `QuipLinux/src/services/image_upload.rs:50`-`136`
   (format sniffing by magic bytes, MIME match, sanitized name). Folder:
   `%LOCALAPPDATA%\Quip\uploads\`. Prune files older than 7 days
   **(decision)**.
2. Default route: type `<path> ` with the phase 1 injector (Unicode
   `SendInput`, focus check before each batch). No Return.
3. Paste route (Codex, later other CLIs): `OpenClipboard`, `EmptyClipboard`,
   `SetClipboardData(CF_DIB)` plus the registered `"PNG"` format, `CloseClipboard`,
   then Ctrl+V into the foreground-checked window. Save the old clipboard
   text first and restore it after, as the Mac does.
4. Never send the ack before the injection returned; the phone defers
   `press_return` until the ack (`CLAUDE.md`, photo-upload item 3).
5. Log stages to a new `image-upload.log` line per stage (`recv`, `saved`,
   `injected`, `error`), like the Mac's `appendImageUploadDiagnostic`.

**Phone impact.** None. The phone's image path is host-agnostic. The phone
only sends HEIC-free formats already (memory: Anthropic accepts
JPEG/PNG/GIF/WEBP only).

**Tests.** Unit: save rules (traversal, bad base64, wrong MIME) copied from
`ImageUploadHandler` tests. Integration: upload to a fake window → file on
disk, fake records the typed path, ack after it; unknown window → error, no
file. Win32 CI: upload a 1x1 PNG into a spawned PowerShell, read the prompt
line back (needs 2.1) or check the clipboard for the paste route.
Simulator: `q91-image.sh`, thumbnail spinner clears on the ack.

**Risks.** A full 16 MiB frame (12 MiB image after base64) must not block the
reactor: decode and save on `spawn_blocking`. Path with spaces: PowerShell
needs it quoted for the typed route **(guess: Claude Code on Windows accepts a
quoted path; spike it)**. Clipboard held open by another app:
`OpenClipboard` retry 3 times, then error.

**Size.** M. **Priority.** P1.

### 2.3 Screenshots of a window

**Mac.** `KeystrokeInjector.captureWindowScreenshot`
(`KeystrokeInjector.swift:1529`) runs `/usr/sbin/screencapture -l <id>` to a
PNG, base64 into `terminal_content.screenshot`. It is attached to every
`request_content` reply, terminal or not (`QuipMacApp.swift:2215`).

**Windows, phase 2.**

1. First choice `PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)` into a DIB
   section, encode PNG (add the `png` crate, pure Rust). Works for
   DirectComposition windows on Windows 8.1+ **(guess for WT; spike)**.
2. Fallback: Windows.Graphics.Capture
   (`IGraphicsCaptureItemInterop::CreateForWindow`, one frame from a
   `Direct3D11CaptureFramePool`). Windows 10 1903+. On Windows 10 it draws a
   yellow border while capturing; Windows 11 can turn it off with
   `IsBorderRequired = false` after `GraphicsCaptureAccess::RequestAccessAsync`.
3. Minimized windows: no capture; send `screenshot` absent.
4. Scale down so the base64 PNG stays under 4 MiB **(decision on the cap)**,
   well under the 16 MiB frame cap.

**Phone impact.** None (the field is optional).

**Tests.** Unit: scale-to-cap math. Win32 CI: capture a spawned Notepad, PNG
decodes, size > 0, not all black. Selftest case.

**Risks.** Elevated windows cannot be captured by `PrintWindow` from a medium
process **(guess)**. GPU-rendered apps return black with `PrintWindow`; WGC
covers them. A screenshot shows whatever is on screen, including secrets the
text redactor would have removed (same as the Mac).

**Size.** M. **Priority.** P2. Ship with or right after 2.1 (non-terminal
windows have no text, so this is their only view).

### 2.4 QA mode pairs (`set_qa_pair`, `clear_qa_pair`, `qa_pair_lost`)

**Mac.** `QuipMacApp.swift:1324`-`1356`: validate both ids, keep the pair per
connection (`WebSocketServer.swift:85`-`122`), send a filtered
`layout_update` to that phone, send `qa_pair_lost` with
`QAPairLostMessage.Reason` (`Shared/MessageProtocol.swift:1595`-`1621`) when a
window closes, goes off screen for 5 s, or is stale after a reconnect. Log:
`qa-mode.log`.

**Phone impact: blocking.** The phone only offers "Pair for QA" for a window
with `targetKind` set or whose `app` is `iterm`, `iterm2` or `terminal`
(`QuipiOS/Models/WindowState+QAMode.swift:11`, `:22`-`29`;
`QuipiOS/Views/WindowRectangle.swift:334`), and the picker lists only those
terminals (`QuipiOS/Views/QAPairPickerSheet.swift:29`). Windows terminals are
named `Windows Terminal`, `PowerShell`, `Command Prompt`, so they never
qualify. Windows has no iOS Simulator to be the target. Sending a fake `app`
name would be a lie the rest of the phone acts on. So QA mode on Windows
needs a phone change (a host-agnostic "is terminal" flag on `WindowState`, or
`cliKind`-based detection). **That is a separate phone ticket.**

**Windows, if the phone ticket lands.** Port the per-connection pair table and
the broadcast filter (`broadcast.rs` gains the paired path, held to an
extended `vectors/broadcast_filter.json`); `targetKind:"browser_localhost"`
(reserved at `Shared/MessageProtocol.swift:102`) for a browser on
`localhost`; `qa-mode.log`.

**Tests.** Unit: pair validation, lost reasons, filter vectors. Integration:
two fake phones, one paired, each gets its own layout.

**Size.** M (host) + phone ticket. **Priority.** P3, after the phone ticket.

Same phone rule also hides Windows terminals from "send to all terminals"
(`QuipiOS/Models/BroadcastPromptPlan.swift:7`,
`QuipiOS/Services/SendToTargets.swift:16`). Fold that into the same phone
ticket.

### 2.5 Push notifications (`register_push_device`, `push_preferences`)

**Mac.** `QuipMac/Services/PushNotificationService.swift` (`notifyWaitingForInput`
at `:587`), `APNsClient.swift` (`api.push.apple.com` /
`api.sandbox.push.apple.com` at `:150`-`151`), key in the Keychain
(`APNsKeyStore.swift`, `APNsMetadataStore.swift`). The phone sends its token
and environment (`Shared/MessageProtocol.swift:1276`-`1286`).

**How QuipLinux did it.** A Rust APNs client with an ES256 JWT
(`QuipLinux/src/services/apns_client.rs:79`-`150`) and a push service with
quiet hours (`QuipLinux/src/services/push_service.rs:58`-`183`). So a
non-Mac host can push.

**Windows.** Copy those two files, store the `.p8` with DPAPI
(`CryptProtectData`, user scope) under `%APPDATA%\Quip\`, Key ID and Team ID
in `settings.toml`. A tray item "Import APNs key…" with a file picker.

**Phone impact.** None on the wire. But a push from the PC is only useful
with waiting-state detection (2.8), and it needs the owner's APNs `.p8` key
copied to the PC: a second copy of a signing secret.

**Tests.** Unit: JWT shape, quiet hours (copied cases), token store.
Integration: a fake APNs endpoint over HTTP/2 **(guess: `h2` + `rustls`
cross-compile to mingw cleanly)**.

**Risks.** Secret sprawl. A dev-signed phone build registers a sandbox
token; the env must match. Two hosts (Mac and PC) pushing the same event
would double-notify.

**Size.** M. **Priority.** Out, unless the owner asks (decision 6.3).

### 2.6 Speech: Whisper, Kokoro, `stt_started` / `audio_chunk`

**Mac.** `WhisperDictationService.swift`, `KokoroTTS.swift`;
`stt_started` sets the window `stt_active` (`QuipMacApp.swift:2107`-`2123`).

**Windows.** Not needed for dictation: the phone falls back to on-device
speech when no `whisper_status` ready arrives (1.3). `stt_started` /
`stt_ended` could set `state_change` `stt_active` for the grid colour, cheap
once 2.8 exists. Whisper on the PC (whisper.cpp) and Kokoro (Python venv)
mean bundling native models and runtimes: not a tray `.exe` any more.

**Phone impact.** None.

**Size.** `stt_active` S; Whisper/Kokoro L each. **Priority.** `stt_active`
P3 (with 2.8); Whisper/Kokoro Out.

### 2.7 Diagnostics from the phone (`request_diagnostics`, `request_log_tail`)

**Mac.** `QuipMacApp.swift:2345`, `:2353`; replies `diagnostics_bundle` and
`log_tail` (`Shared/MessageProtocol.swift:1221`, `:1263`).

**Windows.** Tail `%LOCALAPPDATA%\Quip\Logs\*.log` (already written by
`services/logs.rs`, `quip_log.rs`), pass every line through
`SecretRedactor`, reply to the asker only. Saves the owner from fetching log
files off the PC by hand.

**Phone impact.** None **(guess: the phone's diagnostics sheet does not gate
on `BackendKind.mac`; check before building)**.

**Tests.** Unit: tail bounds, redaction. Integration: request → reply to the
asker only.

**Size.** S. **Priority.** P2.

### 2.8 Waiting-state detection for agent CLIs

**Mac.** `QuipMac/Services/TerminalStateDetector.swift`: CPU of the shell's
children (`:646`-`687`) plus pane movement between two reads
(`PaneStability`, `:509`, `Shared/PaneStability.swift`). Since `dccc888` both
directions are gated on pane movement (memory: CPU alone cannot tell a
network-blocked agent from a prompt). Sends `state_change`
(`QuipMacApp.swift:719`), sets `isThinking`, `cliKind`, `claudeMode`
(`QuipMac/Services/ClaudeModeDetector.swift`).

**How QuipLinux did it.** CPU only, from `/proc`
(`QuipLinux/src/services/state_detector.rs:1`-`35`). That is the rule the
Mac found unreliable; do not copy it alone.

**Windows today.** Every window is `neutral`, `isThinking:false`,
`cliKind:"shell"` (phase 1 spec 3.4, 5.1). `classify::foreground_program`
(`QuipWindows/src/services/classify.rs:94`) already walks the shell's child
processes.

**Windows, phase 2.**

1. `cliKind`: name the child. `claude.exe`, or `node.exe` whose command line
   names Claude Code; `codex.exe` / `node.exe` for Codex **(guess on the exact
   image names; check on the PC)**. Command line via
   `NtQueryInformationProcess(ProcessCommandLineInformation)` (Windows 8.1+).
2. CPU: `GetProcessTimes` deltas over the child tree.
3. Pane movement: two reads from 2.1, compared with a Rust port of
   `PaneStability` held to a new vector file.
4. Debounce as `TerminalStateDebounce.swift`; send `state_change`.
5. `claudeMode` from the read text (port `ClaudeModeDetector` rules +
   vectors); then `set_plan_mode` etc. become key presses (Shift+Tab count,
   `Shared/MessageProtocol.swift:295`).

**Phone impact.** None. The phone already colours cards from `state_change`
(`QuipiOS/Services/WebSocketClient.swift:1473`).

**Tests.** Unit: debounce, stability, classifier vectors. Integration: fake
pane text that stops moving → one `state_change waiting_for_input`; moving
again → `neutral`. Win32 CI: a PowerShell running `Read-Host` reaches waiting
within N s (CI has no Claude Code; use a stand-in script).

**Risks.** Reading every terminal every second through UIA costs CPU; read
only windows with an agent child. Hang risk: same deadline as 2.1.

**Size.** L. **Priority.** P1, right after 2.1.

### 2.9 Numbered prompt and smart answer (`select_N`, `promptFingerprint`)

**Mac.** The phone draws answer chips from `terminal_content`
(`Shared/NumberedPromptDetector.swift`, compiled into both apps) and sends
`quick_action` `select_N` / `select_multi:` / `press_y` with
`promptFingerprint` (`Shared/MessageProtocol.swift:534`). The Mac re-reads the
pane, refuses with "Prompt changed — not sent" when the fingerprint no longer
matches (`QuipMacApp.swift:3426`, gate at `:3678`), and decides whether a Return follows
(`QuipMacApp.swift:3340`). Memory: this is a two-peer contract; both sides
must run the same detector or taps are dropped.

**Windows today.** `promptFingerprint` is ignored (phase 1 spec 3.3);
`select_N` is unsupported (`keys.rs:89`).

**Windows, phase 2.** Port `NumberedPromptDetector` (about 40 KB of Swift)
to Rust, held to a new `vectors/numbered_prompt.json` written by the Swift
tests from the same fixtures. Revalidate the fingerprint with a fresh read
(2.1) before any key. Then map `select_N` to the digit and the Return rule,
`select_multi:` to the walk to the Submit row (memory: Claude multi-select
Enter toggles).

**Phone impact.** None, once 2.1 sends text. Buttons also need the phone's
Labs `oneTapAnswer` (default off), a phone setting, not a change.

**Tests.** Vectors first (every Swift detector case has a Rust twin);
mutation on the port; integration: stale fingerprint → error, nothing typed.

**Risks.** Drift between the Swift and Rust detectors. The vectors are the
only defence; a Swift detector change must regenerate them in the same
commit.

**Size.** L. **Priority.** P2, after 2.8.

### 2.10 Code signing, installer, auto-update

**Today.** The `.exe` is unsigned; the owner clicks through SmartScreen
(phase 1 spec 9, step 2).

**Windows.**

- **Authenticode.** Sign `Quip.exe` with `osslsigncode` on the Mac (works
  with a `.pfx` or a cloud HSM key **(guess for the cloud HSM path)**). Options:
  an OV/EV certificate (since 2023 the keys must live in an HSM or a cloud
  signing service), or Azure Trusted Signing (monthly fee; individual
  eligibility varies by country **(guess; check current terms)**).
  SmartScreen reputation builds per certificate over downloads; an EV cert no
  longer skips it **(guess, based on Microsoft's 2024 change)**.
- **Installer.** MSIX needs a signed package and changes paths (virtualized
  `%APPDATA%`), which breaks the phase 1 settings and log paths **(guess on
  how much)**. Inno Setup is per-user, no admin, and can be built on the Mac
  only through Wine. A portable zip plus `winget` manifest (`winget` takes a
  zip with a portable exe) avoids an installer entirely.
- **Auto-update.** Tray "Check for updates" reads a signed manifest from a
  GitHub Release, downloads the new `.exe`, verifies the Authenticode
  signature (`WinVerifyTrust`) and a SHA-256 from the manifest, swaps on
  next start. Never auto-runs an unsigned binary.

**Phone impact.** None.

**Tests.** CI: `osslsigncode verify` on the artifact. Selftest:
`WinVerifyTrust` on itself reports signed. Update: unit tests for manifest
parse and hash check; a tampered file is refused.

**Risks.** Certificate cost and identity checks. A bad update bricks the
remote; keep the previous `.exe` for rollback.

**Size.** M (signing + zip/winget), M (updater). **Priority.** P2. Signing is
a prerequisite of 2.11 (UIAccess).

### 2.11 Elevated windows (UIPI)

**Today.** Text and keys into an Administrator window are blocked; the
phone gets an error (phase 1 spec 5.4 step 4, acceptance 9).

**Windows.** Two routes:

1. **UIAccess.** Manifest `uiAccess="true"`. Windows only honours it for a
   signed exe in a secure folder (`%ProgramFiles%`, `%SystemRoot%\System32`).
   So it needs 2.10 and a per-machine install (admin once). Then `SendInput`
   reaches elevated windows.
2. **Run Quip elevated.** A Task Scheduler task "run with highest
   privileges" at logon. Every window is reachable, but the whole host and
   its network listener run as admin. Not recommended.

**Phone impact.** None.

**Tests.** Selftest: an elevated PowerShell (the owner accepts one UAC
prompt) receives a marker.

**Risks.** UIAccess raises the blast radius of a host bug: it can type into
UAC-elevated apps. Per-machine install is a new install mode.

**Size.** M. **Priority.** P3 (decision 6.6).

### 2.12 Windows Terminal tab-level targeting

**Today.** One card per WT window; text goes to the active tab (phase 1
spec 13).

**Windows.** UIA: the WT window exposes its tabs as `TabItem` elements with
`SelectionItemPattern` **(guess; spike)**. Each tab becomes its own card, id
`w-<window id>-t<runtime id>`, same frame as the window. `select_window` on a
tab card selects the tab (`SelectionItemPattern.Select`), then foregrounds
the window. Alternative: `wt.exe -w <window> focus-tab -t <index>`, but
mapping an HWND to WT's window id is not direct **(guess)**.

**Phone impact.** Several cards with the same frame on the desktop-mirror
view would overlap **(guess; check in the simulator with a fixture)**. If
they overlap badly, a phone ticket (stacking same-frame cards).

**Tests.** Unit: id scheme, tab list diff. Win32 CI: `wt.exe` with two tabs
→ two cards; select the second, type a marker, it lands there only.

**Risks.** Tab ids change when tabs are torn out or reordered. Typing into
the wrong tab is the worst failure: recheck the selected tab before every
batch, like the foreground check.

**Size.** L. **Priority.** P2 (a single WT window with many tabs is the
common Windows setup **(guess)**).

### 2.13 Network: IPv6, Bonjour retry, Tailscale UX

**IPv6 listener.** Today IPv4 only, on purpose, pinned by
`the_real_host_listens_on_ipv4_only` (`QuipWindows/src/app.rs:249`-`250`).
Phase 1 spec 3.1 (line 115-123) says: before an IPv6 socket, cap the queued
wrong PINs per network below `max_unauthenticated_per_network`
(`QuipWindows/src/host.rs:93`) or reserve a slot for a sender holding none.
The 2026-11-07 review in `docs/superpowers/wishlist.md` adds a third option:
cap how long a closed socket's queued PIN keeps its slot. Order: the cap and
its test first, then the listener. Phone impact: none (the phone dials
whatever URL it has). Size M. Priority P3: nothing needs IPv6 today; the
phone, Bonjour and Tailscale are all IPv4.

**Bonjour retry.** Today `app::advertise` gives up once when there is no LAN
address at start ("mDNS: no LAN address, not advertising",
`QuipWindows/src/app.rs:148`-`166`). Wishlist 2026-11-07 asks for a retry.
Windows: re-check addresses on `NotifyIpInterfaceChange` (IP Helper) or every
30 s, start or restart the advertiser when the LAN set changes, log each
change. Phone impact: none. Tests: unit on the "start / restart / stay"
decision from two address sets; fake clock. Size S. Priority P1.

**Tailscale UX.** Today the tray line shows both (`QuipWindows/src/tray/menu.rs:87`-`105`)
and the QR carries the Tailscale URL only when there is no LAN URL
(`QuipWindows/src/services/pairing.rs:110`-`111`). The owner adds
`ws://<100.x>:8765` by hand (wishlist 2026-11-07). Windows: the QR window
gets a "LAN / Tailscale" switch; a second QR for the `100.x` URL; tray item
"Copy Tailscale URL". Optional: ask `tailscale status --json` for the
MagicDNS name, as `QuipLinux/src/services/tailscale.rs:38`-`110` and
`QuipMac/Services/TailscaleService.swift:42` do. Phone impact: none (the
phone already parses `quip://pair` with any URL, `Shared/PairingPayload.swift`).
Tests: unit for the URL choice per switch; selftest renders both QRs. Size S.
Priority P1.

**Tray shows connected phones** (`device_identity`). Store the phone's
`displayName` per socket and list it in the tray menu, as the Mac does at
`WebSocketServer.swift:1318`. Size S. Priority P2.

### 2.14 Pins and colours from the phone (`set_pin`, `set_color`)

**Done in phase 1 (2026-11-07):** see phase 1 spec 3.3 (`set_pin`,
`set_color` rows) and 3.4 (`isPinned` and order, chosen colour). The text
below is the original plan, kept for the record.

**Mac.** `QuipMacApp.swift:526`-`543`: the Mac owns pins and colours, the
phone asks, the next broadcast carries the result.

**Windows today.** Ignored, so a pin or colour chosen on the phone for a PC
window does not stick: the next `layout_update` sends `isPinned:false` and
the dealt colour.

**Windows.** Keep a pin set and a colour override per window id; persist by
the same `exe path + title` key as the enabled set (phase 1 spec 5.1); order
pinned windows first, as `Shared/WindowPinOrder.swift` (vector file).

**Phone impact.** None. **Tests.** Unit + pin-order vectors; integration.
**Size.** S. **Priority.** P1 (silent no-op today).

### 2.15 Multi-monitor arrange

**Mac.** Arranges the enabled windows on the **primary** display only
(`QuipMacApp.swift:3087`-`3098`).

**Windows today.** Same: the primary display's work area (phase 1 spec 5.2).

**Windows, phase 2.** `ArrangeWindowsMessage` carries only `layout`
(`Shared/MessageProtocol.swift:648`-`656`), so the phone cannot name a
display. Host-only option: tile each display's windows on that display
(group by `displayID`). This changes behaviour versus the Mac; the Mac would
need the same change to stay in parity.

**Phone impact.** Choosing a display from the phone needs a new field: phone
ticket, out of scope.

**Tests.** `vectors/arrange.json` gains multi-display cases from the Swift
side, only if the Mac adopts the rule. **Size.** S (host). **Priority.** P3
(decision 6.7).

### 2.16 ARM64 Windows build

**Today.** `x86_64-pc-windows-gnu` with Homebrew `mingw-w64` (phase 1 spec 9).

**Windows.** Target `aarch64-pc-windows-gnullvm` with an llvm-mingw toolchain
on the Mac, or `aarch64-pc-windows-msvc` built in CI on a Windows runner
**(guess on which is less work)**. The x64 build already runs on ARM64
Windows 11 under emulation **(guess for this binary; check `--selftest`)**.

**Phone impact.** None. **Tests.** CI job builds and runs the unit tests on
an ARM64 runner if one is available **(guess)**; selftest on an ARM64 PC.

**Size.** S-M. **Priority.** P3 (no ARM64 PC in the owner's setup is known).

### 2.17 `deviceKind:"windows"` on the phone

**Today.** The phone maps unknown kinds to `.unknown`
(`QuipiOS/Services/BackendConnectionManager.swift:325`, `:1799`;
`BackendKind` has `mac`, `linux`, `unknown` at
`QuipiOS/Models/PairedBackend.swift:97`-`101`). The kind is only stored; no
view branches on it (grep of `QuipiOS` for `.linux` / `.unknown` finds no UI
use). Phone-side ticket: add `case windows`, a PC icon on the backend row,
and use it to word host-specific errors ("Mac" vs "PC"). Out of scope here.

## 3. Phone change list (separate tickets, none in phase 2)

1. Host-agnostic terminal flag for QA mode and send-to-all (2.4).
2. `BackendKind.windows` and "Mac" wording (2.17). The phone says
   "No reply from the Mac for this window" (phase 1 spec 3.3) to a PC.
3. Display choice for arrange (2.15), only if wanted.
4. Same-frame card stacking for WT tabs (2.12), only if the simulator shows
   it is needed.

## 4. Not planned (Mac-only or not worth it on Windows)

| Feature | Why |
|---|---|
| iTerm2 scan / attach (`scan_iterm_windows`, `attach_iterm_window`) | iTerm2 is Mac only. |
| `open_mac_settings_pane`, `mac_permissions` | macOS TCC panes. Windows has no TCC; the closest is the firewall profile (README). |
| VibeCut sync, Claude previews, reliability (`reliability_turn_on`) | Mac-side tools and launchd. |
| `spawn_window`, `duplicate_window`, project directories | Needs a project list on the PC. Possible later with `wt.exe -d <dir>`; not asked for. |
| Prompts library (`paste_prompt`, `put_prompt`, `delete_prompt`) | The library lives on the Mac. `paste_prompt` into a PC window is a plausible later ask; the phone would need the library from another host first **(guess)**. |
| Virtual desktops (`spaces`) | Phase 1 spec 12. The public API (`IVirtualDesktopManager`) can tell if a window is on the current desktop but cannot list desktops **(guess on the API limits)**. |

## 5. Recommended order

Every milestone keeps the phase 1 gate (phase 1 spec 14): `tools/check.sh`
green and CI green; mutation results in the commit message; an independent
review of the diff against this spec; evidence under
`docs/superpowers/evidence/q91/`; board row; commit; push to `eb-branch`.
The gate column below is what must be true in addition.

| # | Scope | Gate |
|---|---|---|
| M6 | Quick wins: Bonjour retry (2.13), Tailscale QR + copy (2.13), ~~`set_pin` / `set_color` (2.14)~~ (done in phase 1), phone names in tray (2.13), `request_log_tail` / `request_diagnostics` (2.7) | Unit + integration green; simulator `q91-pin.sh`; owner: phone pairs over Tailscale from the QR alone; PC started with no network, then joined, is found by Bonjour within 60 s |
| M7 | Spike (throwaway, like M0): UIA text from WT and conhost, console API read, `PrintWindow` vs WGC on WT, WT tab elements | Spike report from CI and the PC; decisions written into 2.1, 2.3, 2.12 |
| M8 | Terminal text read (2.1) + screenshots (2.3) | Win32 CI: marker read back from conhost and WT; Notepad screenshot decodes; selftest PASS; simulator `q91-content.sh`; hang guard: a read that blocks 5 s delays no keystroke and no heartbeat |
| M9 | Image upload (2.2) | Win32 CI: PNG upload lands as a typed path in PowerShell; ack after injection; owner: photo from the phone into Claude Code on the PC, spinner clears |
| M10 | Waiting state + `cliKind` + Claude modes (2.8), `stt_active` (2.6) | Vectors from the Swift side pass in Rust; CI stand-in agent reaches waiting; owner: a Claude Code card on the PC turns waiting when it asks |
| M11 | Numbered prompt / smart answer (2.9) | Every Swift detector vector has a Rust twin; stale fingerprint types nothing (integration); owner: answer a Claude Code prompt from the phone on the PC |
| M12 | Signing + zip/winget + updater (2.10) | Signed artifact verifies in CI; SmartScreen behaviour recorded on the PC; tampered update refused (unit) |
| M13 | WT tabs (2.12) | CI: two tabs, two cards, marker lands in the chosen tab only; silent-failure review (wrong-tab typing) |
| Later | UIAccess (2.11), ARM64 (2.16), multi-monitor arrange (2.15), IPv6 (2.13), QA mode (2.4, after its phone ticket), push (2.5) | Each gets its own gate when the owner says go |

## 6. Decisions only the owner can make

1. **Order.** Is terminal text (M7-M8) the next thing, ahead of image upload
   and signing? This spec assumes yes.
2. **Signing.** Buy a certificate or a signing service, and which one
   (cost, identity check). Without it, SmartScreen stays and UIAccess (2.11)
   is impossible.
3. **Push from the PC.** Copy the APNs `.p8` key to the PC (2.5), or leave
   push Mac-only?
4. **Installer shape.** Portable zip + `winget`, Inno Setup, or MSIX (2.10).
5. **Auto-update.** Wanted at all, and from where (GitHub Releases on this
   repo is public **(guess on repo visibility)**).
6. **Elevated windows.** UIAccess with a per-machine install, or keep
   refusing Administrator windows (2.11)?
7. **Multi-monitor arrange.** Keep "primary only" in parity with the Mac, or
   arrange each display on its own (and change the Mac too) (2.15)?
8. **Phone tickets.** Open the QA-mode / send-to-all terminal-flag ticket and
   the `BackendKind.windows` ticket now, or later (section 3)?
9. **Uploads folder retention** (2.2) and **screenshot size cap** (2.3).
10. **IPv6.** Needed at all? If yes, which of the three slot mitigations
    (2.13).
11. **Whisper / Kokoro on the PC.** Confirm out (2.6).
