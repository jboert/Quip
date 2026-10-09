# Release Notes — eb-branch → 2026-10-09

For Jakob. Summarizes what eb-branch adds since the last push (`e5ed6ee`,
2026-10-07). Pull `eb-branch`. Earlier notes (2026-06-28) follow below.

> **Rebuild both peers.** Three things in this batch change the **Shared/**
> wire contract, all additive and optional: `PreferencesSnapshot.savedAt`
> (settings backups carry a stamp), `quip_option_labels` + `mutable-content`
> on waiting pushes, and `PushCoalescer.Wait.agentName` feeding the alert
> subtitle. An old Mac drops `savedAt` on re-encode, after which the phone
> treats that Mac's backup as unstamped and keeps its own settings (safe, but
> no restore from that Mac). The iOS app gains a **Notification Service
> Extension target** (`QuipNotificationService`, embedded); run
> `xcodegen generate` in `QuipiOS/` before building.

## Features

### Push: fewer, readable, answerable alerts (Q-56, Q-57, Q-60)
- **Batching (Q-56).** A window pushes once per prompt after it has waited
  10 s; windows that start waiting together share one alert (8 s bundle);
  one APNs collapse id per Mac. The owner had measured ~90 pushes an hour.
- **Answer from the alert (Q-57).** Categories `waiting.yn` (Yes, No, Reply),
  `waiting.12` / `waiting.123` (numbers + Reply), `waiting.1234`,
  `waiting.text` (Reply only), `waiting.many` (bundle, no actions). A button
  sends `quick_action` with the prompt fingerprint; Reply sends `send_text`
  with Return and requires an unlocked phone. `PushAnswerQueue` keeps an
  answer the phone cannot send yet (app killed from the lock screen), wakes
  the connection, sends on auth, for 10 minutes; after 25 s unreachable it
  posts "Couldn't reach your Mac". The notification delegate is installed in
  `didFinishLaunching`, so a cold-launch tap is never lost.
- **Descriptive alerts (Q-60).** Title = project, subtitle = who is asking
  with the call to action (`Claude is asking · hold to answer`), body = the
  question line (prompt text now **on by default**; an explicit off still
  wins) plus the answer legend (`1 Yes · 2 Yes, don't ask again · 3 No`).
  A wait with nothing to answer goes out passive and silent. The Mac marks
  numbered prompts `mutable-content` with `quip_option_labels`; the new
  **Notification Service Extension** registers a per-alert category so the
  long-press buttons read `Yes / Yes, don't ask again / No` instead of
  `1 / 2 / 3`. Registration merges on both sides (static set + up to 12
  recent dynamic categories) so neither the app nor the extension wipes the
  other's buttons. Alert text passes `SecretRedactor`.
- **Push diagnostics (Q-55).** The phone's Mac Permissions row says why
  pushes are off ("Push on Mac — missing Key ID"); Team ID defaults to the
  signing team; the Key ID rides on the key item (fixes the key/kid desync).
- Simulator-verified: lock-screen Yes with the app killed, Reply, the
  unreachable alert and the flush on relaunch. **Not yet seen on hardware:**
  the labelled buttons over real APNs (`simctl push` never runs a service
  extension).

### Phone: pins, card menu, colours, settings that stick (Q-58, Q-61, Q-62, Q-63)
- **Pinned window is first, top left (Q-58).** The phone honoured only its
  own drag order and ignored `isPinned`; now pins float to the front
  (`PhoneWindowOrder.display`), and the Mac lines a new pin up after the
  existing ones (`WindowPinOrder.placingNewPin`). Pinning from the phone
  also drops any free-drag position saved for that card and forces an
  arranged mode, the two things that could keep a pinned card in place.
- **Card menu you can find (Q-61).** Every card has a ⋯ button in its colour
  that opens the long-press menu; **Color** is a submenu of ten named
  swatches with the current one checked, plus Custom… and Reset. The ⋯
  hides on narrow cards (horizontal mode) and from VoiceOver, so the card
  stays one button with its actions rotor.
- **Design-audit fixes (Q-62).** Card titles in the text colour (four
  palette colours failed AA as text on their own tint), secondary line at
  full alpha, 44 pt tap targets on the prev/next chevrons without changing
  the row width, the mic as the only tinted tile in the main row (amber;
  red now means "no mic" only), "Loading windows…" between auth and the
  first layout instead of "No windows" + New Window. Full audit:
  `docs/superpowers/2026-10-09-ios-main-screen-design-audit.md`.
- **Settings survive updates (Q-63).** Every restore (iCloud at launch and
  on change, the Mac's copy on every auth) used to overwrite UserDefaults
  with no age check, so an older backup won and the quick row came back in
  its old order. Backups carry `savedAt`; the phone stamps its own edits and
  applies only a newer copy (`PreferencesFreshness`). Verified on the
  simulator against a deliberately stale backup: the old build reverted, the
  new one keeps the edit.
- **PIN field after a rejected PIN.** A saved PIN the Mac no longer accepts
  left the bar on "Authenticating…" with nothing to type into; the field
  now appears with the error.
- Compact broadcast bar (one line; Settings → Main Row Buttons → Broadcast
  Bar hides it). Search slash commands from the long-press palette (US-105).

### Broadcast and minimize (Q-49, Q-53)
- **Broadcast (US-106 to US-116).** Suggestions and a Most-used shelf,
  library prompts filled per window through `paste_prompt`, Broadcast from a
  prompt row or as a quick button, Press Return toggle, delivered N-of-N with
  retry, `quip://broadcast`. Mac: `paste_prompt` acks (`send_text_ack`),
  `error.messageId` so a failed target fails at once, `raiseWindow` so a
  broadcast no longer flashes every iTerm2 window; `{{clipboard}}` reads the
  user's own text; Terminal.app raises stay on the serial AppleScript queue.
- **Minimize from the phone (Q-53, GH #39).** `minimize_window`,
  `WindowState.isMinimized`, a tray above the grid while anything is
  minimized, Minimize/Restore in the card menu; restore via `select_window`.

### Mac: SwiftUI review applied as a Ralph PRD (Q-59, US-001 to US-007)
- One WebSocket port constant (`WebSocketServer.listenPort`), not a dead
  setting. Layout presets: save, apply, rename, delete (`LayoutPresetStore`).
  Menu-bar Arrange says why it did nothing (`ArrangeOutcome`). QR, Keychain,
  disk and `getifaddrs` work out of view bodies. Every icon button named,
  row actions reachable without a pointer, Reduce Motion honoured.
  Structured concurrency and current APIs in the views. Settings split one
  file per pane under `QuipMac/Views/Settings/`.

### Build and tests
- Every build stamps its commit and build time into Info.plist
  (`QuipBuildCommit`, `QuipBuildDate`, shown in Settings and the Mac menu
  panel); `-dirty` when tracked files differ from HEAD at build time
  (`*.pbxproj` and `*.db` excluded). Version 1.5.7.
- CI's unsigned iOS test host: Keychain-backed stores use an in-memory
  backing under XCTest (-34018 fix). Mac tests keep PINStore and the owner's
  network addresses out of the owner's defaults.
- `tools/fake-mac`: a fake Quip Mac for simulator QA (fixture windows,
  prompts, acks, error ids, `set_color`, `set_pin`, stored preference
  backups with `freeze`/`thaw` to replay a stale copy).

## Hardware checks still owed
Labelled alert buttons over APNs; pin from the phone's card menu on the real
Mac; Save Layout / Apply and the menu-bar Arrange message; VoiceOver and
Reduce Motion passes on the Mac. Everything else above was run on the QA
simulator against the fake Mac, with the full gate green (harness 15 checks,
QuipMac 1155 tests, QuipiOS 1167 tests).

---

# Release Notes — eb-branch → 2026-06-28

For Jakob. Summarizes what eb-branch adds since the last pull. Pull `eb-branch`.

> **Rebuild both peers.** The smart-answer work changes the **Shared/** detector
> contract, which drives fingerprint revalidation on *both* Mac and iOS. Ship Mac
> and iOS together or taps silently drop ("Prompt changed — not sent").

## Features

### Smart answers — inline bracketed choice prompts (§18.3)
Claude/Codex also prompt on a single **inline** line — `Continue? [yes/no]`,
`Approve which to delete? [all / 1 / 2 / 3 / none / pick]` — not line-prefixed
`N.` options. The old detector keyed only on per-line numbers, so these rendered
no buttons.
- **Shared detector:** new `detectInlineOptions(in:)` single-line scanner —
  trailing `[ … ]`, same-line choice cue, splits on `/`, accepts only
  charset-safe tokens with ≥1 digit or known anchor word (all/none/yes/no/pick/…).
  Rejects `array[0]`, `rm -rf [dir]`, `[docs](url)`, `[foo / bar]` prose.
  `fingerprint` gains an `inline:` branch (numbered wins ties).
- **iOS:** `InlineAnswerBar` — one chip per token, single tap. Digits reuse
  `select_N`; words send new `answer_text:<word>`.
- **Mac:** types token + Return; membership check (token must be in
  `detectInlineOptions(liveContent)`) is the real guard.

### Smart answers — multi-select for Claude `[ ]` checkbox menus (§18.2)
Claude checkbox menus are model-emitted **text**; user answers by typing picks.
- iOS `MultiSelectAnswerBar` accumulates picks → one `select_multi:1,3` submit.
- Mac toggles each digit + one Return. One-submit avoids per-tap drop (screen
  doesn't mutate until submit).
- Correctness follow-ups: text-submit keystroke fix + detector body-line/task-list
  guards.

### Phone grid drag-to-reorder fixed
Card drag never engaged — inner `onTapGesture` + `contextMenu` won as
descendants. Fixed via `.highPriorityGesture`. Plus follow-ups: cycle order,
override migration, tests.

## Chores / docs
- `swrm.md` — swrm project manifest.
- Session logs + handoffs (2026-06-23, 2026-06-24).

## Tests
Detector 48 (iOS), AnswerRevalidation 18 (Mac) — all green.

## Still pending (on-device, needs hardware)
- TUI keystroke path for multi-select (number = toggle) unverified live.
