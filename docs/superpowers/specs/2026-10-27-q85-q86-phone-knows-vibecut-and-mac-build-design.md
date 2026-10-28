# Q-85 and Q-86 — the phone knows whether VibeCut changed, and which Mac build it talks to

Two small cross-peer tickets, specced 2026-10-27 after the owner's day of
"is this outdated?" questions. Both are additive on the wire, both need no
owner decision, both ship together because they touch the same three places
(a Shared message, a Mac handler, a phone row).

## Q-85 — Prompts hub says whether VibeCut changed since the last sync

### Intent

Q-82 built the Mac half: Settings → Prompts on the Mac reads Current /
Changed / Never synced. The phone, where the owner actually taps Sync, still
knows only "N synced" for three seconds after a sync. The owner edits VibeCut
on the Mac and has no way to see from the phone that a sync is due.

### Goals

- The Prompts hub shows one line with the VibeCut sync state whenever the hub
  is open and the Mac can say.
- The state is the Mac's own `VibeCutSyncService.freshness`, never a guess
  made on the phone.
- A phone-triggered sync's ack carries the state, so the line is right the
  instant the sync finishes.

### Non-goals

- No automatic sync. The line says "Sync" is due; the owner taps it.
- No polling. The phone asks once when the hub appears and once after each
  ack. The Mac's own 5 s permissions cadence is not reused.
- No change to the Mac's Prompts pane.

### Anti-goals

- Showing Current when the Mac has not computed a fingerprint. Unknown stays
  blank, as on the Mac.
- Breaking an older peer. Every field is optional on decode; an old Mac that
  ignores the request produces no line, an old phone ignores the new fields.

### Wire (Shared/MessageProtocol.swift)

1. `SyncVibeCutAckMessage` gains `let freshness: String?` (nil from an older
   Mac). Values: the `VibeCutFreshnessWire` raw values below.

2. New, phone → Mac:
   ```json
   {"type":"vibecut_status_request"}
   ```
   `struct VibeCutStatusRequestMessage: Codable, Sendable { let type: String }`,
   `init()` sets `"vibecut_status_request"`.

3. New, Mac → the requesting phone only:
   ```json
   {"type":"vibecut_status","freshness":"changed","lastSyncAt":1793150000.5,
    "syncedCount":49,"error":null}
   ```
   `struct VibeCutStatusMessage: Codable, Sendable` with
   `freshness: String`, `lastSyncAt: Double?` (epoch seconds of the last
   outcome, nil when never synced), `syncedCount: Int?` (nil when never
   synced or the last attempt failed), `error: String?` (the last attempt's
   error, nil when it succeeded).

4. `enum VibeCutFreshnessWire: String, Codable, Sendable { case unknown,
   neverSynced = "never_synced", current, changed }` in Shared, next to the
   messages. The Mac maps its `Freshness` to it; the phone decodes to it
   with `VibeCutFreshnessWire(rawValue:) ?? .unknown` so a future value
   reads Unknown, never a crash and never Current.

### Mac (QuipMac)

- `VibeCutSyncService`:
  - `func probeFreshness() async -> Freshness`: the body of today's
    `refreshRepoProbe` (root resolve, detached stat + `sourceFingerprint()`,
    the path-changed guard), returning what it set. `refreshRepoProbe()`
    becomes a fire-and-forget wrapper around it so the Settings pane is
    unchanged.
  - `var wireFreshness: VibeCutFreshnessWire` (pure mapping, one switch).
  - `func statusMessage() -> VibeCutStatusMessage` built from `freshness`
    and `lastOutcome`.
- `QuipMacApp.onMessageWithConnection`, new case next to
  `preferences_request` (the reply must go to one connection):
  `"vibecut_status_request"` → on main, `Task { let _ = await
  vibeCutSyncService.probeFreshness(); webSocketServer.sendToClient(
  vibeCutSyncService.statusMessage(), connection: connection) }`.
- `handleSyncVibeCut`: after `sync` returns, the ack adds
  `freshness: vibeCutSyncService.wireFreshness.rawValue`. `sync` already
  calls `refreshRepoProbe()` after writing; it must `await probeFreshness()`
  instead so the ack's value is the post-sync one, not last pane's.
- `websocket.log`: no new lines. The existing `sync finished` line stands.

### Phone (QuipiOS)

- `WebSocketClient`: `var onVibeCutStatus: ((VibeCutStatusMessage) -> Void)?`;
  `case "vibecut_status"` (guard `isAuthenticated`, same decode pattern as
  `sync_vibecut_ack`); `func requestVibeCutStatus() -> Bool { send(
  VibeCutStatusRequestMessage()) }`.
- `BackendConnectionManager.wire(session:)`: no bridge needed; the hub sets
  `client.onVibeCutStatus` directly, as it does `onSyncVibeCutAck`.
- `QuipiOS/Services/VibeCutStatusText.swift`, pure:
  ```swift
  enum VibeCutStatusText {
      struct Line: Equatable { let text: String; let tone: Tone }
      enum Tone { case neutral, due, failed }
      /// nil for unknown: the hub shows nothing rather than a guess.
      static func line(freshness: VibeCutFreshnessWire, lastSyncAt: Date?,
                       syncedCount: Int?, error: String?, now: Date) -> Line?
  }
  ```
  Rules, in order:
  - `error != nil` → `"Last sync failed — <error>"`, `.failed`.
  - `.neverSynced` → `"Never synced from VibeCut"`, `.neutral`.
  - `.changed` → `"VibeCut changed since the last sync — Sync"`, `.due`.
  - `.current` → `"Up to date with VibeCut · <N> prompts · <when>"`,
    `.neutral`, where `<when>` is `RelativeDateTimeFormatter` against `now`
    ("2 hours ago"); `· <N> prompts` omitted when `syncedCount` is nil.
  - `.unknown` → nil.
- `PromptLibrarySheet`:
  - `@State private var vibecutStatus: VibeCutStatusMessage?`.
  - `.onAppear`: set `client.onVibeCutStatus = { vibecutStatus = $0 }`; if
    connected and authenticated, `client.requestVibeCutStatus()`.
  - `.onDisappear`: nil the callback.
  - `handleSyncAck`: unchanged result text; additionally, if
    `ack.freshness != nil`, `client.requestVibeCutStatus()` (one round trip,
    the Mac has the fresh outcome by then).
  - The line renders directly under the "Most used first" header row, as a
    `Text` in `.caption`, colour by tone: `.secondary`, `.orange`, `.red`.
    When `tone == .due` the whole line is a `Button` that calls
    `syncFromVibeCut()`, with `accessibilityLabel("Sync from VibeCut now")`.
  - The three-second `syncResult` flash stays as it is.

### Fake Mac (tools/fake-mac/fake-mac.swift)

- `case "sync_vibecut"`: log, then `broadcast` an ack
  `{"type":"sync_vibecut_ack","messageId":…,"syncedCount":<fixture prompt
  count>,"skippedCount":0,"skippedPacks":0,"freshness":"current"}` and set
  an internal `vibecutFresh = true`.
- `case "vibecut_status_request"`: reply to that client with
  `{"type":"vibecut_status","freshness": vibecutFresh ? "current" :
  "changed","lastSyncAt": <now or nil>,"syncedCount": <count>}`. Starts
  `false` so a fresh simulator pairing shows the orange line, and the Sync
  tap turns it neutral.
- Console command `vibecut changed` flips `vibecutFresh` back to false for
  QA.

### Tests

- `Shared/Tests/MessageProtocolTests.swift`: round-trip for
  `VibeCutStatusRequestMessage`, `VibeCutStatusMessage` (with and without
  the optionals), `SyncVibeCutAckMessage` decoding an old Mac's JSON without
  `freshness` (nil) and a new one with it.
- `QuipMac/Tests/VibeCutFreshnessTests.swift`: `testWireFreshnessMapsEveryCase`
  (4 cases); `testStatusMessageCarriesLastOutcome` (never synced → nil
  fields; a failed outcome → error set, syncedCount nil; a good one → count
  and date).
- `QuipiOS/Tests/VibeCutStatusTextTests.swift`: one test per rule above
  plus `testUnknownFreshnessShowsNothing` and
  `testFutureFreshnessValueReadsUnknown` (`VibeCutFreshnessWire(rawValue:
  "stale") == nil`).
- Mutation checks the builder must run: (a) map `.unknown` to `.current` in
  `wireFreshness` → freshness test fails; (b) drop the `error` branch in
  `VibeCutStatusText.line` → its test fails; (c) do not re-request status
  after an ack → no unit test can catch this, so the simulator pass is the
  check.

### Acceptance

- Simulator with the fake Mac: open Prompts hub → orange "VibeCut changed
  since the last sync — Sync" under the header; tap it → "N synced" flashes,
  line becomes "Up to date with VibeCut · N prompts · now"; `vibecut changed`
  on the fake's console, reopen the hub → orange again.
- Hardware, after the next Mac install: on the Mac, append one byte to a copy
  of VibeCut pointed to by `vibecutRepoPath` (see the acceptance-tests spec
  A2); the phone's hub reads the orange line; Sync; neutral line.

## Q-86 — Settings on the phone names the Mac's build

### Intent

Today the phone cannot tell which Mac build it is paired with. Twice on
2026-10-27 the owner asked "is this outdated?", and the answer lived only in
the Mac's menu bar, which the phone is meant to replace. The phone already
shows its own `BuildInfo` line; it should show the Mac's beside it.

### Goals

- Settings → the Mac Status section gains one row: "Mac build" ·
  `1.5.7 (1642) 0038c48`, the Mac's `BuildInfo.shortDisplay`.
- Arrives on auth, so it is there before the owner scrolls to it.

### Non-goals

- No version comparison or "update available" logic. Two builds a few
  commits apart are both fine. The row informs; it does not judge.
- No row for a Mac that predates the message: the section is unchanged.

### Wire

New, Mac → every authenticated phone, sent from `onClientAuthenticated`
beside `broadcastPermissions(force: true)`:
```json
{"type":"mac_build","short":"1.5.7","build":"1","commit":"0038c48",
 "number":"1642","date":"2026-10-27 19:55","deviceID":"17161F64-…"}
```
`struct MacBuildMessage: Codable, Sendable, Equatable` with `short: String`,
`build: String`, `commit: String?`, `number: String?`, `date: String?`,
`deviceID: String` (the Mac's `WebSocketServer.deviceID()`, so a phone with
two Macs keys the row per backend). `init(stamp: BuildInfo.Stamp, deviceID:
String)`. The display string is computed on the phone with the shared
`BuildInfo.shortDisplay(BuildInfo.Stamp(...))`, never sent, so one function
renders both peers' builds.

### Mac

- `QuipMacApp.onClientAuthenticated`: `self.webSocketServer.broadcast(
  MacBuildMessage(stamp: BuildInfo.current, deviceID:
  WebSocketServer.deviceID()))`. Broadcast is acceptable here: the message
  carries no per-phone data (unlike preferences), and the other phones
  already have it.

### Phone

- `WebSocketClient`: `var macBuild: MacBuildMessage?` (`@Observable`-visible
  like `promptLibrary`), set in `case "mac_build"` (guard `isAuthenticated`),
  cleared to nil in `handleDisconnect` and `disconnect()` so a reconnect to
  another Mac never shows the old row. Also `var onMacBuild:
  ((MacBuildMessage) -> Void)?` for parity with the other messages.
- `BackendConnectionManager.wire(session:)`: bridge
  `c.onMacBuild → self.onMacBuild?(session, msg)` (the multi-backend rule:
  every `onFoo` needs its `c.onFoo` bridge or host subscriptions no-op).
- `SettingsSheet.macPermsSection`, after the push row: when
  `client.macBuild` is non-nil,
  ```
  settingsIcon("desktopcomputer", tint: .secondary)
  Text("Mac build")   Spacer()   Text(<shortDisplay>).font(.subheadline).foregroundStyle(.secondary)
  ```
  Tap copies `"Quip Mac <display>"` to the pasteboard with the same 1.5 s
  "Copied" flip the Version row uses (`versionCopied` pattern, own state).
- The row's `shortDisplay` is `BuildInfo.shortDisplay(BuildInfo.Stamp(short:
  msg.short, build: msg.build, commit: msg.commit, date: msg.date, number:
  msg.number))`.

### Fake Mac

- `sendWelcome(to:)` also sends `{"type":"mac_build","short":"0.0.0",
  "build":"1","commit":"fake000","number":"0","date":"2026-01-01 00:00",
  "deviceID":"fake-mac"}` so the simulator row reads `0.0.0 (0) fake000`.

### Tests

- `Shared/Tests/MessageProtocolTests.swift`: `MacBuildMessage` round-trip;
  decoding a message without `commit`/`number`/`date` (all nil) still
  decodes; `BuildInfo.shortDisplay` of the decoded stamp equals the Mac's
  own `shortDisplay` for the same stamp (one renderer, both peers).
- `QuipiOS/Tests/WebSocketClientMacBuildTests.swift`: feeding a `mac_build`
  frame sets `macBuild`; `handleDisconnect()` clears it. Mirror the existing
  client tests that drive `handleDisconnect` without a socket
  (`WebSocketFailoverTests`).
- Mutation checks: drop the clear in `handleDisconnect` → client test fails;
  send the row's text from the Mac instead of the stamp → the "one renderer"
  test is the guard (it would still pass, so the builder reviews the diff
  for a `display` string field and rejects it).

### Acceptance

- Simulator with the fake Mac: Settings shows "Mac build · 0.0.0 (0) fake000".
- Hardware, after the next Mac install: Settings shows the Mac's real line,
  equal to the Mac menu bar's. Quit the Mac app: the row disappears on the
  phone within the stall watchdog's 25 s; relaunch: it is back after auth.

## Order and size

Q-85 first (it has the larger phone surface), Q-86 second; one commit each,
`feat(sync)` and `feat(phone)`. Both are "small change" size: no further
design document. Gate: `tools/check.sh` (Shared change → all three suites).
Install: iOS OTA for both; the Mac half rides the next Mac install, which
the owner schedules because it risks the TCC grants.

## Left to the builder

- Exact placement of the status line if the "Most used first" header turns
  out to be hidden while searching: put it above the list in that case.
- Whether `probeFreshness()` needs a timeout: the stat can hang on a dead
  network volume (see the comment on `refreshRepoProbe`). If the phone's
  request would otherwise wait forever, reply Unknown after 3 s.
