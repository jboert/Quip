# fake-mac — a stand-in Quip Mac for simulator QA

The iOS app gets its window grid, prompt library and send acknowledgements only
from a connected Mac. A QA simulator must never connect to the owner's real Mac:
a paired test host once overwrote the owner's phone settings, and the installed
Mac app still broadcasts preference restores to every connected phone.

`fake-mac.swift` speaks enough of the Mac's WebSocket protocol for the phone to
pair, authenticate, stay connected and show realistic data from `fixture.json`:
a window grid with terminal windows, a prompt library to search, and
`send_text_ack`s for sends and broadcasts. Nothing real is on the other end.

## Safety rules

Enforced in the code:

- **127.0.0.1 only.** The listener binds the loopback address on the loopback
  interface and drops any peer that is not loopback. Only this Mac and its
  simulators can reach it. It never listens on 0.0.0.0.
- **Never port 8765.** That is the real Mac app's port. The fake refuses it, and
  refuses any port another process already listens on.
- **No Bonjour.** The fake never advertises, so nothing can discover it.
- **Reads only its fixture.** No Quip defaults (`com.quip.mac`), no Keychain, no
  prompt files, no clipboard (`{{clipboard}}` is left as written). It writes
  only its own log.
- **No secrets in the log.** A PIN the phone sends appears as a length only (the
  startup banner prints the fake's own PIN so you can pair). Preference snapshots
  the phone pushes are logged by key name and dropped; values are never logged
  or stored. `preferences_request` always gets the empty "no backup" reply,
  because a restore carrying paired backends would make the phone dial them.
- **A fake identity that cannot match a real Mac.** `device_identity` carries
  device id `FA4E3AC0-0000-4000-8000-000000000001`, and its `localURLs` holds
  only the fake's own `ws://127.0.0.1:<port>`. The fixture's monitor name is
  `FakeMac Display`. The phone treats an equal device id or monitor name as
  "same Mac" and merges rows, so neither may ever equal a real Mac's.

Rules for whoever runs it:

- Use a simulator of your own. Never the coordinator's test-gate simulator,
  never one shared with another project, and never a physical device.
- The simulator shares this Mac's network, so its connect screen can list the
  real Mac as a Bonjour row marked "Local". **Never tap it.** The pairing link
  below never needs it.
- Never sign the QA simulator into iCloud. The phone mirrors its paired-Mac list
  through iCloud key-value storage and connects to every restored entry.

## Run it

From the repository root:

```bash
xcrun swift tools/fake-mac/fake-mac.swift
xcrun swift tools/fake-mac/fake-mac.swift --port 8799 --pin 11112222 \
    --fixture tools/fake-mac/fixture.json --log /tmp/fake-mac.log
```

| Option | Default | Meaning |
| --- | --- | --- |
| `--port N` | `8799` | Port on 127.0.0.1. 8765 is refused, and so is a busy port. |
| `--pin PIN` | `11112222` | PIN the phone must send. |
| `--fixture PATH` | `fixture.json` beside the script | Windows and prompts to serve. |
| `--log PATH` | `$TMPDIR/quip-fake-mac.log` | Every log line also goes here (appended). |
| `--ack-paste` | off | Ack `paste_prompt` with a `send_text_ack`, as the Mac will once US-115 ships. |
| `--error-ids` | off | Put the request's `messageId` on `error` replies, also planned in US-115. |

Compiling once is fine too: `xcrun swiftc -O tools/fake-mac/fake-mac.swift -o /tmp/fake-mac`.
Do not commit the binary. A binary run from outside the repository root needs
`--fixture`.

At startup the fake prints the exact pairing command for its port and PIN.

## Pair a simulator

The phone's `quip://pair` link carries the server URL **base64-encoded, with the
`=` padding stripped** (`Shared/PairingPayload.swift`). A plain `url=ws://…`
does not decode. For the defaults:

```bash
xcrun simctl openurl <udid> 'quip://pair?url=d3M6Ly8xMjcuMC4wLjE6ODc5OQ&pin=11112222'
```

`d3M6Ly8xMjcuMC4wLjE6ODc5OQ` is `ws://127.0.0.1:8799`. For another port, use the
link the fake prints, or `printf 'ws://127.0.0.1:PORT' | base64 | tr -d '='`.

iOS first asks "Open in Quip?"; tap Open. The phone stores the PIN, connects,
and from then on reconnects to the fake on its own, including after the fake
restarts. A full first run on a fresh simulator:

```bash
xcrun simctl create "Quip FakeMac QA" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-26-4
xcrun simctl boot <udid>
xcrun simctl install <udid> <DerivedData>/Build/Products/Debug-iphonesimulator/Quip.app
xcrun simctl launch <udid> com.fintechadventures.quip
xcrun simctl openurl <udid> 'quip://pair?url=d3M6Ly8xMjcuMC4wLjE6ODc5OQ&pin=11112222'
xcrun simctl io <udid> screenshot /tmp/grid.png
```

On first launch the app asks for speech recognition, and after the first
connection for notifications. Either answer works with the fake.

## Commands

Type these into the fake's terminal while it runs. A `<window>` is an id, or any
unique part of an id, name or folder (`dead lantern`, `close 2290`).

| Command | Effect |
| --- | --- |
| `help` | List the commands. |
| `status` | Connected phones, windows (acking or dead), prompt count. |
| `layout` | Resend `layout_update` to every phone. |
| `library` | Resend `prompt_library` to every phone. |
| `close <window>` | Drop the window from the layout and resend it. Later sends to it get `error` "Window no longer exists". |
| `dead <window>` | Keep the window, but answer nothing to sends to it: no ack, no error. |
| `alive <window>` | Ack sends to it again. |
| `reload` | Re-read the fixture: closed windows return, dead flags and in-memory prompt edits reset. |
| `quit` | Close every connection and exit (Ctrl-C works too). |

To drive it from a script, give it a FIFO as stdin:
`mkfifo /tmp/fm.in; xcrun swift tools/fake-mac/fake-mac.swift 0<>/tmp/fm.in &`,
then `echo 'dead lantern' > /tmp/fm.in`. With stdin closed, commands are off.

## What it answers

The handshake and replies mirror `QuipMac/Services/WebSocketServer.swift` and
the handlers in `QuipMac/QuipMacApp.swift`.

| Phone sends | Fake does |
| --- | --- |
| (connects) | `auth_result` `auth_required`, as the real Mac with "Require PIN" on. |
| `auth`, right PIN | `auth_result` success, `device_identity`, then what the Mac sends on auth: `layout_update`, `project_directories`, `mac_permissions` (all granted), `whisper_status` `preparing`, `prompt_library`, `frontmost_changed`. |
| `auth`, wrong PIN | `auth_result` "Incorrect PIN" after the Mac's throttle delay (200 ms per failure, up to 2 s). The socket stays open. Ten failures lock auth for 15 minutes; restarting the fake clears the lock. |
| anything before auth | Dropped, as the Mac does. |
| more than 10 messages a second | The extras are dropped and logged, as the Mac drops them silently. |
| `send_text` | `send_text_ack` with the same `messageId` after a simulated 38–165 ms injection. `path` is `sendText`, `pasteText` (Codex or Grok in iTerm2) or `genericApp` (non-terminal app), as on the Mac. A dead window gets nothing; a missing window gets `error` "Window no longer exists". No `messageId`, no ack. |
| repeated `messageId` within 30 s | No reply (the Mac's dedupe table). |
| `paste_prompt` | Logged with the body filled for the target window (`{{folder}}`, `{{window}}`, `{{agent}}`, `{{cwd}}`, `{{date}}`). No ack, as today's Mac; with `--ack-paste`, acked like `send_text`. Unknown prompt ids are ignored. |
| `quick_action` | Logged; never acked, as on the Mac. A missing window gets `error`. |
| `request_content` | `terminal_content` from the window's fixture `content`, at most twice a second per window. |
| `preferences_request` | `preferences_restore` with the requester's `deviceID` and an empty snapshot, to that phone only: the Mac's "no backup" reply. |
| `preferences_snapshot` | Key names logged; nothing stored. |
| `put_prompt` / `delete_prompt` | Applied in memory only (the fixture file is never written), then `prompt_library` and the ack. |
| `close_window` | Same as the `close` command. |
| `image_upload` | `image_upload_error`, so the phone's spinner stops. |
| `heartbeat_ack`, `device_identity`, `phone_log`, `select_window`, push registration, anything else | Logged. |

The fake also sends a `heartbeat` every 15 s, and the phone's WebSocket pings
are answered by the network stack. Acks and errors go to every connected phone,
as the real Mac broadcasts them.

Every received message is one log line, on stdout and in the log file:

```
2026-10-07 21:14:46.960 [c2] recv send_text window=com.googlecode.iterm2.4101 messageId=AF197988 pressReturn=1 textLen=37 text="Run the tests and report the failures" -> send_text_ack in 139ms path=sendText
2026-10-07 21:15:20.326 [c2] recv send_text window=com.googlecode.iterm2.4117 messageId=D7EFE51B pressReturn=1 textLen=37 text="Second broadcast with one dead window" -> window is DEAD: no reply
```

`[c2]` numbers connections in arrival order. Text is previewed (48 characters);
message ids are shortened to 8.

## The fixture

`fixture.json` is invented data. `windows` are `WindowState` and `prompts` are
`PromptEntry` from `Shared/MessageProtocol.swift`; the fake checks them at start
(state, color, `cliKind`, unique ids) because the phone silently drops a whole
`layout_update` or `prompt_library` it cannot decode. Three window fields are
fake-only and never sent in `layout_update`:

- `dead`: start with acks off, as if `dead <window>` had been typed.
- `content`: the text served as `terminal_content`.
- `cwd`: fills `{{cwd}}`.

The phone counts a window as a terminal only when `app` is exactly `iTerm2` or
`Terminal`, so broadcasts and the Prompts button follow that field.

The shipped fixture has four windows: two iTerm2 windows (Claude in
`orchard-api`, waiting at a numbered prompt; Codex in `lantern-web`, thinking),
one Terminal.app shell in `dotfiles`, and one Safari window. It also has twelve
prompts chosen to exercise search: tags, a `targetAgent` with a description,
`{{folder}}`, an unfilled `{{ticket}}`, a diacritic (`café`), names that make
"commit", "review" and "ship" rank across name, tag and body hits, and a
2,002-character runbook whose only "zebra" sits 91 characters from the end.
