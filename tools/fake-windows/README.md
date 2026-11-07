# fake-windows: the Windows host on the Mac, for simulator QA

`Quip --fake-platform` runs the real Windows host code (`QuipWindows/`: the
WebSocket server, auth, router, typing rules) on the Mac, against an in-memory
PC (`QuipWindows/src/platform/fake.rs`) loaded from `fixture.json`. The phone
pairs with it in a simulator exactly as it would with a PC, so phone-side
checks of the Windows backend never need a PC and never touch real data
(spec `docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md`, 10.6).

It is the Windows twin of `tools/fake-mac`, and follows every one of its
safety rules.

## Safety rules

Enforced in the code (`QuipWindows/src/fake_mode.rs`):

- **127.0.0.1 only.** It binds the loopback address and drops any peer that is
  not loopback.
- **Never port 8765**, the real app's port, and never port 0. A port another
  process already listens on fails to bind with a clear message.
- **No mDNS / Bonjour.** Nothing advertises it.
- **A fake identity that cannot match a real host.** `device_identity` carries
  device id `FA4E3AC0-0000-4000-8000-000000000002` (fake-mac's is `…0001`) and
  `localURLs` holds only `ws://127.0.0.1:<port>`. The fixture's primary display
  must be named `FakeWindows Display`; the fake refuses any other name. The
  phone treats an equal device id or monitor name as "same host" and merges
  rows, so neither may ever equal a real one.
- **No stored secrets.** No settings file is read or written. A PIN the phone
  sends is logged by length only (the banner prints the fake's own PIN so you
  can pair). `preferences_snapshot` is dropped and logged by key name only;
  `preferences_request` always gets the empty "no backup" reply, because a
  restore carrying paired backends would make the phone dial them.
- **Logs in a temp folder** (`$TMPDIR/quip-fake-windows/Logs/` by default),
  never `%LOCALAPPDATA%` and never the Mac app's `~/Library/Logs/Quip/`: a
  `--log-dir` inside either (symlinks and `..` resolved) is refused.

Rules for whoever runs it:

- Use a simulator of your own (`xcrun simctl create`). Never the coordinator's
  test-gate simulator, never one another session is using, never a device.
- Never tap a Bonjour row for a real Mac in the simulator's connect screen.
- Never sign the QA simulator into iCloud.
- Run fake-mac and fake-windows on different ports when both are up
  (`q91-two-backends.sh`).

## Run it

From the repository root:

```bash
cargo run --manifest-path QuipWindows/Cargo.toml -- --fake-platform
cargo run --manifest-path QuipWindows/Cargo.toml -- --fake-platform \
    --port 8797 --pin 11112222 --fixture tools/fake-windows/fixture.json --log-dir /tmp/fw-logs
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--port N` | `8797` | Port on 127.0.0.1. 8765 and 0 are refused; a busy port fails. |
| `--pin PIN` | `11112222` | PIN the phone must send (digits). |
| `--fixture PATH` | `tools/fake-windows/fixture.json` | The fake PC. |
| `--log-dir DIR` | `$TMPDIR/quip-fake-windows/Logs` | `websocket.log`, `injection.log`, `latency.log`, `phone.log`. |

At startup it prints the pairing link for its port and PIN:

```bash
xcrun simctl openurl <udid> 'quip://pair?url=d3M6Ly8xMjcuMC4wLjE6ODc5Nw&pin=11112222'
```

`d3M6Ly8xMjcuMC4wLjE6ODc5Nw` is `ws://127.0.0.1:8797`, base64 with the `=`
padding stripped (`Shared/PairingPayload.swift`). For another port use the
printed link, or `printf 'ws://127.0.0.1:PORT' | base64 | tr -d '='`.

## Commands

Typed into its terminal while it runs (or fed through a FIFO:
`mkfifo /tmp/fw.in; cargo run … -- --fake-platform 0<>/tmp/fw.in &`).
A `<window>` is a handle, a wire id, or a unique piece of a title.

| Command | Effect |
| --- | --- |
| `help` | List the commands. |
| `status` | Authenticated phones, the foreground window, every window with id, shell, enabled, minimized. |
| `layout` | Re-poll now (a `layout_update` goes out only if something changed). |
| `open <title> [cmd\|app]` | Add a window: Windows Terminal running pwsh (default), a classic `cmd` console, or a Notepad. |
| `close <window>` | Remove it (as if the user closed it on the PC). |
| `move <window> X Y W H` | Move / resize its visible rect, in physical pixels. |
| `title <window> <text>` | Retitle it. |
| `front <window>` / `front none` | Change the foreground window (sends `frontmost_changed`). |
| `refuse <window> on\|off` | Make focusing it fail, like Windows' foreground lock. |
| `run <window> <exe>…` / `run <window> shell` | Start a program in its shell (`run 3 python.exe`), or go back to the prompt. The host re-reads the shell at send time, so multi-line text is refused at once, with no re-poll. |
| `uipi <n>` / `uipi off` | Let only `n` units per typing batch in (`uipi 0`: an elevated window that ignores all input). |
| `block <ms>` / `block off` | Make typing block, to watch the hang guard. |
| `quit` | Exit (Ctrl-C works too). |

The fake polls its PC every second, like the real host, so changes reach the
phone within a second either way.

## What the fake did

Every platform action is printed to **stdout**, one line each, counts only
(never the text), so a tap on the phone can be checked against what the PC
would have received:

```
fake: focus handle=4097 step=set_foreground
fake: type handle=4097 units=8
fake: key handle=4097 chord=shift+return
fake: key handle=4097 chord=return
fake: move handle=4098 outer=953,0 974x1047 restore_first=false
fake: minimize handle=4098
fake: close handle=4099
```

`BLOCKED inserted=N` marks a short insert (`uipi`), `landed_in=H` input that
went to another window. Logs go to stderr. `latency.log` gets a line for each
`send_text` (`text_len`, `segments`, `multiline_guard`) and each key
`quick_action` (`action`, `inputs`) that reached the injector, with
`success=0|1`. A send refused before that (multi-line into cmd, window gone,
input thread stopped) is written to `injection.log` only, as a `DROPPED` line.

## What it answers

The real host's handlers (`QuipWindows/src/services/router.rs`), with the fake
PC underneath:

| Phone sends | Fake does |
| --- | --- |
| (connects) | `auth_result` `auth_required`, which the phone waits for before sending its PIN. |
| `auth`, right PIN | `auth_result`, `device_identity`, `layout_update`, then `frontmost_changed`. |
| `auth`, wrong PIN | "Incorrect PIN" after 200 ms per failure (up to 2 s); ten failures lock auth for 15 minutes (restart clears it). |
| anything before auth | Dropped, no reply. |
| `send_text` | Typed into the fake window (focus first, the foreground re-checked before every batch and key). Multi-line text into PowerShell gets Shift+Enter between lines and never a Return; into `cmd`, an unknown shell, or a shell running a program (`run`) it is refused with `error`. `send_text_ack` when `messageId` is present. Only windows the phone is shown can be typed into. |
| `quick_action` | The spec 5.5 keys; `toggle_enabled` flips the window; anything else gets "Not supported on Windows yet". |
| `select_window`, `minimize_window`, `close_window`, `arrange_windows` | Applied to the fake PC, then a fresh `layout_update`. `arrange_windows` tiles the windows the phone shows. `select_window` with an id the phone is not shown gets no answer (as on the Mac). |
| `request_content` | `terminal_content` "Terminal text is not available on Windows yet." for a shown window, to the asker only; nothing for any other id. |
| `preferences_snapshot` / `preferences_request` | Dropped / "no backup". |
| `phone_log` | Written to `phone.log` in the log folder. |
| anything else | Ignored. More than 10 frames a second from one phone (auth aside) are dropped, as on the Mac; a socket not authenticated within 10 s is closed, and at most 16 may wait for auth. |

`heartbeat` goes out every 15 s.

## The fixture

`fixture.json` is invented. Two displays (`FakeWindows Display` 1920x1080 with a
40 px taskbar, and a 2560x1440 second screen) and five windows:

- `pwsh in orchard-api`: Windows Terminal, pwsh, the foreground window;
- `Windows PowerShell`: classic console, Windows PowerShell 5;
- `Command Prompt`: classic console, cmd (multi-line refused), on the second display;
- `pebble-docs (tabs: pwsh, cmd)`: Windows Terminal with mixed tabs, so its
  shell is `unknown` and multi-line is refused;
- `notes.txt - Notepad`: not a terminal, hidden until "Show all apps".

Each window has `handle`, `pid`, `title`, `className`, `exePath`, optional
`productName`, `shells` (the innermost shell of each attached console), its
`visible` rect, an optional invisible `border` (default 7 px) and
`isMinimized`. App names, terminal and shell come from the real `classify.rs`.
