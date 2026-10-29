# Q-87 — Renders Claude opens on the Mac show on the phone

Specced 2026-10-28 from the owner's ask: "sometimes I have Claude Code pull
up renders of app screens in Preview. Is there a way to have those show in
Quip?" Built 2026-10-28, not committed or installed — see "Build status" at
the end for what differs from the plan below and what is still open.

## Intent

Claude Code, running in a terminal Quip mirrors, often finishes a UI task
with `xcrun simctl io booted screenshot shot.png && open shot.png`. The
render opens in Preview on the Mac, where the owner (on the phone, away
from the desk) cannot see it. The phone should show it, attached to the
terminal whose Claude session opened it, with a control that closes the
Preview window on the desktop.

## Goals

- A file Claude opens with `open` shows on the phone as a thumbnail on the
  terminal whose Claude session ran the command.
- Tapping the thumbnail opens it full screen. Pinch zooms, one-finger drag
  pans, double-tap toggles fit / 100 %, so every detail of a render can be
  reviewed. The full-screen image is sharp enough for that (see the image
  message: the original pixels when they fit).
- The phone shows the file's own pixels, not a screenshot of the Preview
  window.
- Each thumbnail has a close control. It closes that Preview window on the
  Mac and removes the thumbnail.
- One switch turns the feature on, on the Mac (Settings → General) or on the
  phone (Settings → Mac Status). The switch installs and removes the Claude
  Code hook itself; nobody edits `~/.claude/settings.json` by hand. The
  target is Erick trying the feature with no setup beyond the switch.

## Anti-goals (the owner's explicit concern)

- **A Preview window Claude did not open never reaches the phone.** Not one
  the owner opened by hand, not one already open when the feature was
  switched on. The only way onto the phone is the hook reporting the path.
  Quip never lists Preview windows and guesses which are Claude's.
- Editing the user's other Claude Code hooks. The installer adds and removes
  exactly one entry it can recognise, and leaves everything else in the file
  byte-for-byte equivalent (same keys, same order, same values).
- A broken or slow hook slowing Claude down. The hook must return in well
  under 100 ms on commands that open nothing, and must exit 0 always.

## Non-goals (v1)

- Renders opened any other way: Xcode canvas previews, the Simulator window
  itself (QA mode already covers that), `qlmanage -p`, images Claude only
  `Read`s, or files opened by a script Claude runs (`./make-shots.sh` that
  calls `open` inside). Only `open <path>` in the command text Claude ran.
- Shell expansion. `open "$OUT"` cannot be resolved from the command text;
  it is skipped (logged). Globs are expanded against the cwd.
- Tunnel (Cloudflare) clients. Renders are local work product; v1 sends them
  to LAN/Tailscale phones only, like local-only prompts (Q-83).
- Android and Linux.

## How it fits together

```
Claude Code ──PostToolUse(Bash)──▶ quip-claude-hook (in Quip.app)
                                        │ parses `open <paths>` from the command,
                                        │ finds the terminal (tty / ITERM_SESSION_ID)
                                        ▼
            ~/Library/Application Support/Quip/claude-previews/inbox/<uuid>.json
                                        │ (DispatchSource watch)
                                        ▼
                     Quip.app  ClaudePreviewService
                       - keeps a registry of Claude-opened files
                       - matches each to a terminal window id
                       - matches Preview windows by AXDocument path
                                        │ WebSocket
                                        ▼
                    Phone: thumbnail strip on that terminal; full screen; ✕
```

The hook never talks to the network or to Quip directly. A drop file works
when Quip is not running (it is read on next launch, then expired by age),
needs no port, and cannot block Claude.

## The hook

### Binary

A command-line target `quip-claude-hook` in `QuipMac/project.yml`, embedded
at `Quip.app/Contents/Helpers/quip-claude-hook` and signed with the app. A
compiled helper, not a shell script: it starts in a few ms, has no
`python3`/`jq` dependency (neither is guaranteed on Erick's Mac), and its
parsing logic is unit-tested in Swift. The parsing and tty code lives in
`QuipMac/Services/ClaudeHook/` and is compiled into both the helper and the
QuipMac test target.

### What it does, in order

1. Read stdin (the PostToolUse JSON). If `tool_name != "Bash"` or the
   command does not contain the token `open`, exit 0. This is the fast path
   for nearly every call.
2. `OpenCommandParser.paths(in: command, cwd:) -> [URL]` (pure):
   - Split on `&&`, `||`, `;`, `|`, newlines (outside quotes).
   - For each segment whose first word, after stripping leading `env VAR=x`
     assignments and a leading `rtk`/`rtk proxy` (the owner's PreToolUse
     rewriter), is `open` or `/usr/bin/open`: take the non-flag arguments.
     Flags that take a value (`-a`, `-b`, `--args` stops parsing) consume it.
   - Unquote; expand `~`; resolve relative paths against `cwd`; expand globs.
   - Skip anything containing `$` or a backtick (logged as `skipped=expansion`).
   - Keep only existing regular files with a previewable extension: png, jpg,
     jpeg, heic, gif, tiff, webp, pdf. URLs (`open http://…`) are dropped.
3. Identify the terminal (see below).
4. Write one JSON file atomically (write to `.tmp`, rename) into the inbox:
   ```json
   {"v":1,"at":1793170000.2,"sessionId":"<claude session_id>","cwd":"…",
    "paths":["/abs/shot.png"],"tty":"/dev/ttys004",
    "itermSessionId":"8C1F…","termSessionId":null}
   ```
5. Exit 0. Every failure path also exits 0 with nothing on stdout, so a
   hook bug can never block or alter a Claude turn.

### Identifying the terminal

- `ITERM_SESSION_ID` (`w0t1p0:<UUID>`) from the environment, UUID part.
  Quip already tracks `iterm2SessionId` per window, so this is an exact match.
- The tty of the nearest ancestor that has one, for Terminal.app (and as
  an iTerm fallback against the existing `iterm2Tty`). Claude Code runs
  command hooks in their own session with no controlling terminal, so the
  hook's own tty is empty and `ttyname(0)` is a pipe. Walk up from
  `getppid()` with `sysctl(KERN_PROC_PID)` (parent pid `e_ppid`, tty
  `e_tdev` → `devname`) until a process has a tty — that is the `claude`
  process in its terminal. Stop after 8 levels or at pid 1.
- `TERM_SESSION_ID` (Terminal.app) is recorded for diagnostics only.

Both are builder checks against a real hook run (see "Facts to confirm").

## The installer (the switch)

`ClaudeHookInstaller` in `QuipMac/Services/ClaudeHook/`, pure where it can
be:

- `static func install(into settings: Data?, hookPath: String) throws -> Data`
  and `static func uninstall(from settings: Data) throws -> Data` operate on
  bytes, so every case is a unit test with no file I/O.
- Shape added (merged into `hooks.PostToolUse`, never replacing it):
  ```json
  {"matcher":"Bash","hooks":[{"type":"command",
    "command":"'/Applications/Quip.app/Contents/Helpers/quip-claude-hook' # quip-previews",
    "timeout":5,"async":true}]}
  ```
  `async: true` runs it in the background, so Claude never waits on it.
  The trailing `# quip-previews` is the marker. Uninstall removes exactly the
  hook objects whose `command` ends with it, then removes a matcher group only
  if that left it empty. The path is the running app's
  `Bundle.main.bundleURL`, so a Quip in `~/Applications` works.
- Missing file → create `{"hooks":{…}}`. Missing `hooks` / `PostToolUse` →
  create them. A file that is not valid JSON → refuse, change nothing, show
  "Claude settings file isn't valid JSON — not touched".
- Before the first write, copy the original to
  `~/.claude/settings.json.quip-backup` (once; never overwritten).
- Write atomically (temp file in `~/.claude/`, `rename`), preserving the
  file's permissions.
- Key order: decode with `JSONSerialization` loses order. Use an
  order-preserving JSON model (a small `OrderedJSON` enum or the
  `JSONSerialization` + `.sortedKeys`-free re-emit with a recorded key order)
  so the owner's file does not reshuffle. The test is a round trip of the
  owner-shaped fixture (several PreToolUse/PostToolUse groups, other top-level
  keys) that must come back equal apart from the one added group.
- `status(settings:hookPath:) -> HookStatus` (pure): `.off`, `.on`,
  `.stale(path)` (marker present, path is an older Quip location → Repair),
  `.unreadable`.

### Where the switch lives

- **Mac**, Settings → General, new row "Show Claude's previews on phone":
  toggle + status line (`On`, `Off`, `Points at an old Quip — Repair`,
  `Claude settings unreadable`). Claude Code's docs say it reloads hooks
  from the settings file while running, so no restart caption is planned; if
  fact 2 fails in the real run, add "Restart open Claude sessions to start
  sharing previews".
- **Phone**, Settings → Mac Status section: the same toggle. Phone → Mac:
  `{"type":"set_claude_previews","enabled":true}`. The Mac runs the installer
  and answers through the existing `MacPermissionsMessage` broadcast, which
  gains `claudePreviews: String?` (`off|on|stale|unreadable`, nil from an
  older Mac → row hidden). A tunnel client's `set_claude_previews` is
  dropped: a remote client must not be able to make the Mac run a hook.
- The Mac re-checks status on launch and on each Settings open; an app moved
  to a new path shows `stale`, and Repair rewrites the path.

## Mac: ClaudePreviewService

- Watches the inbox with a `DispatchSource` on the directory. On each new
  file: decode, delete the file, add one `ClaudePreview` per path:
  ```swift
  struct ClaudePreview: Identifiable, Sendable {
      let id: UUID; let path: String; let openedAt: Date
      var terminalWindowId: String?   // matched below; nil = unattached
      var previewWindowNumber: CGWindowID?  // Preview window showing it, once seen
  }
  ```
  A path already in the registry is refreshed (new `openedAt`), not
  duplicated — `open shot.png` twice reuses one Preview window.
- **Terminal match** (pure `static func terminalWindowId(for:in:)`):
  `itermSessionId` against `iterm2SessionId`, then `tty` against
  `iterm2Tty` / Terminal.app tab tty. No match → unattached (shown under a
  "Claude previews" row on the phone's main screen rather than dropped).
  Terminal.app tab tty is not tracked today; add it to the existing
  Terminal.app read.
- **Preview match**: on the snapshot tick, for Preview windows only
  (`com.apple.Preview`), read `kAXDocumentAttribute` from the AX window
  (file URL) and match to registry paths. Map AX window → `ManagedWindow`
  with the existing public-API `resolveAXWindow` (position/size/title). AX,
  not AppleScript: no Automation prompt for Preview, and it stays off the
  AppleScript path that hangs on macOS 27.
- **Expiry**: a preview leaves the registry when (a) its Preview window was
  seen and then closed, (b) the phone dismisses it, (c) its file is deleted,
  or (d) 6 hours pass. The inbox ignores files older than 6 hours on launch.
- Log: `~/Library/Logs/Quip/claude-previews.log` (new; add to
  `LogPaths.swift` and the CLAUDE.md list): `REPORTED paths=N tty=… iterm=…`,
  `ATTACHED preview=… window=…`, `UNATTACHED preview=…`, `SKIPPED
  reason=expansion|missing|type`, `INSTALL/UNINSTALL result=…`. Paths are
  logged as file names only.

## Wire (Shared/MessageProtocol.swift)

All new, all additive; an older peer ignores them.

- Mac → phone, on auth and on each registry change (local clients only):
  ```json
  {"type":"claude_previews","items":[{"id":"…","name":"shot.png",
    "terminalWindowId":"com.googlecode.iterm2-1234","openedAt":1793170000.2,
    "hasDesktopWindow":true,"thumb":"<base64 JPEG, 240px>"}]}
  ```
  Full list each time (small: thumbnails only), so the phone never merges.
- Phone → Mac: `{"type":"claude_preview_request","id":"…"}`.
  Mac → that phone: `{"type":"claude_preview_image","id":"…",
  "format":"png|jpeg","data":"<base64>","pixelWidth":…,"pixelHeight":…}`.
  The original bytes when the file is PNG or JPEG and its base64 fits under
  `WSLimits.maxMessageBytes` with headroom (12 MiB raw): a simulator
  screenshot (1290×2796 PNG, ~1–3 MB) always does, so zooming shows real
  pixels. Otherwise (HEIC, TIFF, GIF, WebP, or too large) a JPEG at the
  original size, quality 0.9, stepping down in size until it fits. PDF:
  first page rendered with `PDFKit` at 2× its point size; v1 shows page 1
  only and says "page 1 of N".
- Phone → Mac: `{"type":"claude_preview_dismiss","id":"…","closeOnDesktop":true}`.
  Mac: if `closeOnDesktop` and a Preview window is matched, press its
  `kAXCloseButtonAttribute` (generic AX close; the iTerm-only `closeWindow`
  is not touched). Then drop it from the registry and rebroadcast.
- `MacPermissionsMessage.claudePreviews: String?` and `set_claude_previews`
  as above.

## Phone (QuipiOS)

- `WebSocketClient`: `claudePreviews: [ClaudePreviewItem]` (observable,
  cleared on disconnect like `macBuild`), `onClaudePreviewImage`,
  `requestClaudePreview(id:)`, `dismissClaudePreview(id:closeOnDesktop:)`.
  Bridge each `onFoo` in `BackendConnectionManager.wire(session:)`.
- `ClaudePreviewStrip` (new view), shown above the terminal content in the
  selected terminal when it has previews: horizontal thumbnails, newest
  first, each with an ✕. A badge with the count on that terminal's tile in
  the grid.
- Tap → `ClaudePreviewViewer`, a `fullScreenCover`:
  - The image sits in a `UIScrollView` (`UIViewRepresentable`,
    `ZoomableImageView`), not SwiftUI gestures: pinch zoom and one-finger
    pan with native momentum, bounce and edge behaviour. Min zoom = fit to
    screen, max = 4× the image's pixel size per screen point (so 100 % and
    beyond is reachable), centred while smaller than the screen.
  - Double-tap toggles between fit and 100 % (1 image pixel = 1 screen
    pixel), zooming around the tapped point.
  - Rotation to landscape re-fits the image.
  - Swipe down at fit zoom, or the top-left Done button, dismisses. Swipe is
    ignored while zoomed in, so panning never closes it by accident.
  - Toolbar: share sheet, and a "Close on Mac" button. Shows the thumbnail at once and swaps in the full
  image when `claude_preview_image` arrives (spinner with a 10 s watchdog,
  as `PendingImageState` does).
- ✕ on a thumbnail: closes on the Mac and removes. "Close on Mac" in the
  viewer does the same. When `hasDesktopWindow == false` (opened in a
  browser, or already closed on the Mac) the ✕ only removes from the phone.
- Settings → Mac Status: the toggle row, hidden when `claudePreviews` is nil.

## Facts to confirm before building

Checked against Claude Code's docs (hooks, settings and plugins reference
pages at code.claude.com/docs) on 2026-10-28. The builder re-verifies each
with a real hook run, since docs lag:

1. **PostToolUse stdin** — documented: `session_id`, `transcript_path`,
   `cwd`, `permission_mode`, `hook_event_name`, `tool_name`, `tool_input`
   (Bash: `command`, `description`, `timeout`, `run_in_background`),
   `tool_response`, `tool_use_id`. Confirm by logging one real payload.
2. **Live pickup** — the settings page says settings files are watched and
   reloaded, hooks included, so a running session should start using the
   hook without a restart. No documented approval gate for user-level hooks
   (workspace trust applies to project-level ones). Confirm: switch on with
   a session open, then `open` a file in it.
3. **Rewritten commands** — undocumented whether PostToolUse's `tool_input`
   is the command as typed or as rewritten by a PreToolUse hook (the
   owner's `rtk` rewriter). The parser handles both (`rtk` prefix stripped).
4. **Environment and tty** — hooks inherit the parent environment (minus
   `OTEL_*`), so `ITERM_SESSION_ID` should be present; the docs do not list
   it, so confirm. Hooks run with **no controlling terminal**, which is why
   the tty comes from the parent chain. `CLAUDE_PROJECT_DIR` is set.
5. **Preview's `kAXDocumentAttribute`** on its windows (macOS 26/27) — not
   a Claude fact; check with Accessibility Inspector.
6. **Plugin instead of settings.json** — plugins can ship hooks
   (`hooks/hooks.json`) that merge with the user's, which would avoid
   touching `settings.json` at all. But no documented way exists for an app
   to install and enable a plugin without the user going through Claude's
   plugin flow. v1 edits `settings.json`; if `claude plugin install` from a
   local path works non-interactively, that is a cleaner v2 and the rest of
   the design is unchanged.

## Tests

- `OpenCommandParserTests`: `open a.png`; `open -a Preview a.png b.pdf`;
  chains (`xcrun simctl io booted screenshot s.png && open s.png`); quoted
  paths with spaces; `~`; relative to cwd; glob; `open "$OUT"` skipped;
  `open https://…` dropped; `rtk open x.png`; `echo open x.png` not matched;
  `open` inside a quoted string not matched; non-image extension dropped.
- `ClaudeHookInstallerTests`: install into nil / `{}` / owner-shaped file
  (round trip equal except the added group, key order preserved); install
  twice is a no-op; uninstall removes only the marked hook and keeps a group
  that still has others; invalid JSON refused unchanged; `status` for each
  case including `stale`.
- `ClaudePreviewServiceTests` (pure statics): terminal match by iTerm id, by
  tty, none → unattached; same path twice → one entry; expiry rules.
- `MessageProtocolTests`: round trips of the five messages and an old
  `MacPermissionsMessage` without `claudePreviews`.
- Phone: `ClaudePreviewItem` decoding; strip shows only the selected
  terminal's previews (pure filter function); `ZoomMath` (pure) — fit scale
  for image/viewport sizes, the 100 % scale for a screen scale, the
  double-tap target (fit ↔ 100 %), and the zoom rect centred on a tap point
  clamped to the image.
- Mutation checks: drop the marker check in uninstall → owner-fixture test
  fails; remove the `$` skip → expansion test fails; match terminals by "most
  recent" instead of id → match test fails.

## Acceptance

- Mac with the switch on, in a fresh Claude session in iTerm2: ask Claude to
  screenshot the booted simulator and `open` it. Within 2 s the phone shows a
  thumbnail on that terminal. Tap → full-size image. ✕ → the Preview window
  closes on the Mac.
- Open a different PNG in Preview by hand from Finder: nothing on the phone.
- Have a Preview window open before turning the switch on: nothing on the
  phone.
- Two Claude sessions in two terminals, each opens a render: each thumbnail
  is on its own terminal.
- Switch off: `~/.claude/settings.json` is back to its pre-install content
  (diff against the backup is empty apart from formatting the installer did
  not introduce).
- Toggle from the phone: the Mac's Settings row follows within a second.

## Order and size

Three commits on `eb-branch`, each gated with `tools/check.sh`:

1. `feat(mac)`: helper target, parser, installer, Mac Settings switch,
   inbox + registry + log. Testable on the Mac alone via the log.
2. `feat(protocol)`: the five messages + `MacPermissionsMessage` field, Mac
   send/handle paths, AX Preview match and close, fake-mac support
   (`claude preview <path>` console command that injects a registry entry).
3. `feat(phone)`: strip, viewer, dismiss, settings toggle.

Medium size. Mac install needed (TCC risk; owner schedules it), plus iOS.

## Left to the builder

- Where the unattached row lives on the phone's main screen, if the
  terminal match turns out to fail often in practice.
- Whether 240 px thumbnails keep `claude_previews` small enough to send on
  every change, or whether thumbnails should be fetched per item.

## Build status, 2026-10-28

Built on `eb-branch`'s working tree, uncommitted at the owner's request.

**Verified**
- Mac: 45 new tests (parser 20, installer 13, service 12) + images/tunnel 5 +
  message round trips 3, alongside the existing `MessageProtocolTests`: 185
  green (`-only-testing`; the full Mac suite was not run).
- Phone: app and test target build (`build-for-testing`, generic iOS). The
  local simulator is unusable, so `ClaudePreviewLogicTests` has not run under
  XCTest; the same assertions pass in a swiftc harness on the Mac.
- Helper smoke test: a fake PostToolUse payload with `open shot.png` wrote a
  report in 8 ms with `tty=/dev/ttys000` — Claude's terminal, found through
  the parent chain. A payload with no `open` exits in 6 ms writing nothing.
- Fact 5: Preview exposes `AXDocument` (a `file://` URL) on every window.
  Fact 4 (tty): the hook's process has no tty, its `claude` parent has it.

**Differs from the plan above**
- The helper ships at `Contents/MacOS/quip-claude-hook` (xcodegen's
  `executables` copy), not `Contents/Helpers`.
- The switch state rides in `claude_previews` (`state`: off / on / stale /
  unreadable / remote) instead of a new `MacPermissionsMessage` field: one
  message carries everything the phone needs, and the permissions broadcast's
  equality dedupe stays about TCC.
- Preview groups files from one `open` call into one window and reports only
  the file on screen, so a match for one file of a report is a match for all
  of them. ✕ on one of a group closes the Mac window only when no other
  listed file is in it.
- Unattached previews (and those whose terminal has closed) show on whatever
  terminal is selected rather than in a separate row, so none is invisible.
- Tunnel clients get `claude_previews` with `state: "remote"` and no items,
  and the Mac refuses `claude_preview_request`, `claude_preview_dismiss` and
  `set_claude_previews` from them (`WebSocketServer.refusedTunnelType`).

**Not done yet**
- Fake Mac support (`claude preview <path>` console command).
- The count badge on a terminal's tile in the grid.
- Facts 1–3 in a real Claude session (they need the hook installed in the
  owner's `~/.claude/settings.json`, which waits for the owner).
- Hardware acceptance (needs a Mac install, which risks TCC grants, and an
  iOS install).
- Full-suite gate (`tools/check.sh`) before committing.

### On by default (owner, 2026-10-28)

"I don't really like the idea of this feature requiring any manual work." The
switch now turns itself on: at launch, a Quip running from an Applications
folder on a Mac that has `~/.claude/` installs the hook (or re-points a stale
one) unless someone turned the switch off (`claudePreviews.userTurnedOff`,
set by any non-automatic change). Debug builds and test hosts run from
DerivedData and never touch the settings file. An unreadable file is still
never touched. Rule: `ClaudeHookSwitch.shouldAutoInstall`, tested.

Verified on the owner's Mac: launch logged `INSTALL source=auto result=ok`;
the diff against `settings.json.quip-backup` is one added PostToolUse group.
Fact 1 confirmed: the running Claude session picked the hook up with no
restart, and a plain `open <png>` was `ATTACHED … window=com.apple.Terminal.47`.
Seen: `open "$VAR/x.png"` is `SKIPPED reason=expansion`, as designed.
