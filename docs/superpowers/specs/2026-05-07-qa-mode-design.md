# QA Mode (paired Simulator + terminal layout) — Design

**Status:** Spec / pre-implementation
**Date:** 2026-05-07
**Author:** Erick (with Claude)
**Scope:** QuipiOS (phone client), QuipMac (server), Shared/MessageProtocol

## Problem

When QA-testing the iOS app you build, the Mac desktop usually has exactly two windows of interest: a Simulator running the app, and a terminal running the dev tooling (Metro/Expo, Claude Code, build commands). Quip's current `RemoteLayoutView` shows every visible terminal plus any explicitly-enabled non-terminal window. During a QA loop the phone's mirrored layout is cluttered with windows that aren't relevant, and switching the Mac's input target between Sim and terminal requires extra taps.

The user wants a "QA mode" that, when toggled on, narrows the phone's view to just one Simulator and one terminal, side-by-side, with a faster input loop for rapid iteration.

The same model is intended to extend later to a browser pointed at a local-dev URL (`localhost:<port>`), so the design treats the non-terminal half of the pair as a generic "target" with `Simulator` as the v1 implementation.

## Goals

- Pair one **target** (Simulator now; browser-on-localhost in v2) with one **terminal**.
- Side-by-side 50/50 layout on phone, with a draggable divider.
- Tap a pane to select that window; horizontal swipe across the divider flips the selection.
- Text input routes to the selected terminal only (Sim is read-only screenshot in v1).
- PTT (volume buttons) and Enter remain primary input affordances. Manual minimize-keyboard control for max pane real estate.
- Bandwidth-tight: Mac filters its `LayoutUpdate` broadcast to the two paired windows when QA mode is active for a connection.
- Pair persists across phone relaunch / WS reconnect when both windows still exist.

## Non-goals (v1)

- Sim text injection (read-only this round).
- Browser-on-localhost target (predicate stub only — full impl deferred).
- Named/multi-pair management (single active pair per backend).
- Refresh-rate boost on the pair (existing snapshot cadence).
- Mac-app UI surface (phone-driven only).
- Push-to-text UI redesign (PTT stays primary).

## Architecture

```
[Phone, normal layout]
   long-press window with targetKind != nil → "Pair for QA"
        │
        ▼
   [Pick terminal sheet]   ← lists windows where isTerminal
        │  tap → picks terminalId
        ▼
   [Phone] → WS → set_qa_pair { target_id, terminal_id }
   [Mac]   stores pair in qaPairByConnection[connId]
   [Mac]   per-connection LayoutUpdate filtered to pair only
   [Phone] receives 2-window LayoutUpdate → renders QAPairLayoutView
```

Symmetric entry: long-pressing a terminal first opens a "Pick Simulator" sheet.

Exit: phone sends `clear_qa_pair`. Mac drops the entry, broadcast returns to current rules (`mirrorDesktop` + isEnabled).

Failure recovery: every Mac snapshot tick validates the pair against the current window list. Either id missing → Mac sends `qa_pair_lost { missing_id, reason }`, drops the entry. Phone exits QA mode with toast.

Per-backend isolation: pair is keyed by `ConnectionId` on Mac and by active backend on phone. Cycling backends switches pairs. Two phones to one Mac maintain independent pairs.

## Phone-side components

### New files

- `QuipiOS/Models/QAPair.swift` — `struct QAPair: Codable { let targetId: String; let terminalId: String }`. Persistence via `@AppStorage("qaPair.<backendId>")` JSON-encoded.
- `QuipiOS/Views/QAPairLayoutView.swift` — side-by-side 50/50 with draggable divider, header chip, exit button, input bar.
- `QuipiOS/Views/QAPairPickerSheet.swift` — sheet for picking the missing half of the pair (target picker or terminal picker depending on entry path).

### Modified files

- `QuipiOS/Views/RemoteLayoutView.swift` — branch on `qaPair != nil`. Render `QAPairLayoutView` when set; otherwise current grid.
- `QuipiOS/Views/ContextMenuView.swift` — add "Pair for QA" item when long-pressed window has `targetKind != nil` (offer terminal picker on tap), or `isTerminal == true` (offer target picker on tap). Item hidden otherwise.
- `QuipiOS/Services/WebSocketClient.swift` — `func setQAPair(target:terminal:)`, `func clearQAPair()`, new `onQAPairLost: ((String, String) -> Void)?` callback.
- `QuipiOS/Services/BackendConnectionManager.swift` — `wire()` bridges `c.onQAPairLost` to host. Stores per-backend `qaPair: QAPair?`. Cycle-active swaps pair into view.

### Selection model

Existing `selectedWindowId` carries through unchanged. Tap pane → set to that pane's id. Horizontal-swipe ≥40pt with 2:1 horizontal-to-vertical ratio across the divider flips it (matches `RemoteLayoutView`'s existing backend-cycle gesture pattern, lines 52–74).

### Keyboard behavior

- Tap-outside dismisses focus (existing pattern).
- Manual chevron-down button on input bar resigns first responder.
- Tap input bar re-focuses.
- Panes auto-resize via SwiftUI safe-area when keyboard up.
- iOS keyboard renders normally — no compact mode in v1; user controls visibility via the toggle.

### Pair persistence

Per `project_phone_prefs_backup.md` — extend `PreferencesSnapshot` with `qaPairByBackend: [String: QAPair]?`. Both apply and snapshot paths must be wired so phone reinstalls don't lose pair state. Divider ratio stored in `@AppStorage("qaPair.dividerRatio.<backendId>")` separately.

## Mac-side components

No new files. Logic fits into existing services.

### Modified files

- `QuipMac/Services/WindowManager.swift`
  - Add `var isTarget: Bool` on `ManagedWindow`. v1: `bundleId == "com.apple.iphonesimulator"`.
  - Extend `windowsForBroadcast(_:mirrorDesktop:)` to take optional `qaPair: (CGWindowID, CGWindowID)?`. When set, returns ONLY those two windows (overrides mirrorDesktop and isEnabled — pair wins).
  - Snapshot validation hook: after applying a snapshot, for each connection's pair, check both ids exist in `windows`. Either missing → emit `qa_pair_lost` to that connection and drop the entry.

- `QuipMac/Services/WebSocketServer.swift`
  - Handle `set_qa_pair` / `clear_qa_pair`.
  - Add `qaPairByConnection: [ConnectionId: (CGWindowID, CGWindowID)]`.
  - Pass the connection's pair into `windowsForBroadcast` when assembling that connection's `LayoutUpdate`.
  - Validate `set_qa_pair` ids against current snapshot before storing — if invalid, respond `qa_pair_lost` immediately, don't store.
  - On connection drop, remove the entry.

- `Shared/MessageProtocol.swift`
  - Add `setQAPair(targetId: String, terminalId: String)`, `clearQAPair`, `qaPairLost(missingId: String, reason: String)`.
  - `WindowState` gains `var targetKind: String?` (`"simulator"` v1; `nil` otherwise; `"browser_localhost"` reserved for v2). String type chosen for additive forward compat.

## Protocol additions

### Phone → Mac

```json
{ "type": "set_qa_pair",   "target_id": "com.apple.iphonesimulator.42", "terminal_id": "com.googlecode.iterm2.117" }
{ "type": "clear_qa_pair" }
```

### Mac → Phone

```json
{ "type": "qa_pair_lost", "missing_id": "com.apple.iphonesimulator.42", "reason": "window_closed" }
```

`reason` values (string for forward compat):
- `"window_closed"` — window vanished from snapshot
- `"window_offscreen"` — `isOnVisibleScreen == false` for >5s
- `"connection_reset"` — Mac no longer recognizes the IDs (e.g., post-restart replay)

### Mac → Phone (existing, modified)

`LayoutUpdate.windows[*].target_kind` is added. Existing phones ignoring the field are unaffected.

### Idempotency

`set_qa_pair` with the current pair as new value is a silent no-op. `clear_qa_pair` when no pair set is a silent no-op. Phone tolerates `qa_pair_lost` for an already-cleared pair.

## Pairing flow + UX

### Entry

1. Long-press a window rect in `RemoteLayoutView`.
2. `ContextMenuView` shows "Pair for QA" only when the long-pressed window is a target (`targetKind != nil`) OR a terminal (`isTerminal`). Otherwise hidden.
3. Tap → opens `QAPairPickerSheet` for the OTHER half (target → picks terminal; terminal → picks target).
4. Tap a row in the sheet → phone sends `set_qa_pair`, dismisses sheet, swaps to `QAPairLayoutView`.

### Re-pair from inside QA mode

Header chip shows: `● <target name>  ↔  <terminal name>  ⓘ ✕`

- Tap chip → re-opens picker (both steps if user wants to swap both).
- Tap ⓘ → debug info (window IDs, last update time).
- Tap ✕ → sends `clear_qa_pair`, returns to normal layout.

### Picker sheet

- Title: "Pick Simulator" or "Pick terminal".
- List rows: window app icon + name + cwd subtitle (existing `WindowState`).
- Greyed/disabled rows: `isOnVisibleScreen == false`.
- Empty state for target picker: "No Simulators detected. Open Xcode → Run on a Simulator."
- Cancel returns to normal layout (no pair set).

### Layout

- 50/50 split with draggable divider (4pt visible, 10pt hit zone).
- Drag horizontally within 30/70 to 70/30 range; release snaps to nearest of [30, 50, 70].
- Selected pane has 2pt accent-color border.
- Bottom strip with `[●] <selected app name> · <selected cwd>` (reuse pattern from `RemoteLayoutView` lines 77–89).

### Swipe to flip

- ≥40pt horizontal, 2:1 H/V ratio.
- 0.18s spring; accent border slides to the new pane.

### Input bar

- Single-line text field + chevron-down (minimize keyboard) + send button (▲).
- PTT volume buttons unchanged.
- Tap chevron-down → resign first responder, panes expand to full height.
- Tap text field → focus, keyboard returns.
- Tap-outside on either pane also dismisses.

### Header chip + bottom input bar pin

Header stays put when keyboard up; bottom input bar pins above keyboard; panes shrink between them.

### Sim selected = read-only hint

When `selectedWindowId` is the Sim's id, send button is disabled with inline hint "Read-only — switch to terminal to type." Less noisy than per-keystroke toast. PTT works the same way (no-op if Sim selected).

## Error handling + edge cases

| Case | Behavior |
|---|---|
| Sim quit / terminal closed mid-session | Mac emits `qa_pair_lost { reason: "window_closed" }`. Phone exits QA, toast 3s: `"<App name> closed. Exited QA mode."`, clears `@AppStorage` qaPair. |
| Window goes off-screen sustained ≥5s | Mac emits `qa_pair_lost { reason: "window_offscreen" }`. Same exit path. 5s grace covers Mission Control flicker. |
| Phone WS reconnects (Mac alive) | Phone replays `set_qa_pair`. If both ids match → restored, no UI flicker. If stale → Mac responds `qa_pair_lost { reason: "connection_reset" }`. |
| Mac restart while phone offline | On reconnect, replay → Mac doesn't recognize IDs → `qa_pair_lost`. Phone exits gracefully. |
| Picker step shows stale window that has since vanished | User picks → `set_qa_pair` with missing target → Mac validates → immediate `qa_pair_lost`. Phone shows toast, returns to normal. |
| Multi-backend cycle while in QA | Each backend has independent qaPair. Backend cycle gesture moves to header chip's chevron menu while QA active (avoids conflict with flip-selection swipe). |
| Two phones one Mac, both in QA | `qaPairByConnection` keyed by `ConnectionId` → independent. Same physical window can be in two pairs. |
| `send_text` arrives for Sim's id | `KeystrokeInjector` no-ops for non-terminal. Send button disabled in UI guards 99% of cases; this is a defense-in-depth no-op. |
| Text input arrives before pair set (race on entry) | No `selectedWindowId` → existing fallback no-ops. |

## Testing

### Manual acceptance flow (primary)

1. Open Xcode, run nugget-expo on Quip QA simulator (UDID `D853A014-E5D8-46F1-A81D-37860AA9DFA2`). Open iTerm2 in same project dir.
2. Connect phone to Quip Mac.
3. Long-press Simulator rect → confirm "Pair for QA" appears.
4. Tap → terminal picker shows iTerm2 with cwd = nugget-expo.
5. Tap iTerm2 → side-by-side QA layout renders. Header chip shows pair names.
6. Drag divider — confirm snaps to 30/50/70.
7. Tap Sim → border on right; tap terminal → border on left.
8. Horizontal swipe across divider → border flips.
9. Type + send while terminal selected → text appears in iTerm2 via `cmd+k` paste.
10. With Sim selected → send button grayed + read-only hint.
11. Tap chevron-down → keyboard dismisses, panes expand.
12. Tap input bar → keyboard returns.
13. PTT volume buttons → dictation routes to currently selected window (terminal-only effective).
14. Quit Sim from Mac → toast `"<Sim name> closed. Exited QA mode."` → returns to grid.
15. Re-enter QA, kill Quip Mac, restart Quip Mac → phone reconnects, replays pair, Mac rejects, phone exits gracefully.
16. Force-quit phone, reopen → if pair persisted and both Mac windows still match, QA mode restored.

### Unit-level (lightweight)

- `QuipMac/Tests/WindowManagerTests.swift` — extend with: `windowsForBroadcast` returns exactly 2 windows when qaPair set; full unfiltered list when nil; pair survives `mirrorDesktop=false` + both `isEnabled=false`.
- `isTarget` predicate: Simulator bundleId returns true; iTerm2/Terminal/Safari return false.
- Phone-side: `QAPair` Codable round-trip; reducer for `qa_pair_lost` clears state + emits toast.

### Diagnostic logging

Add `~/Library/Logs/Quip/qa-mode.log` (per `LogPaths.swift` convention):

- `[set_qa_pair] connId=<id> target=<id> terminal=<id>`
- `[clear_qa_pair] connId=<id>`
- `[qa_pair_lost] connId=<id> missing=<id> reason=<reason>`
- `[broadcast_filter] connId=<id> in=<n> out=2 (qa pair)`

Skip XCUITest automation — Quip uses manual acceptance per repo pattern.

## Quip-specific gotchas honored

- New `@AppStorage` prefs (`qaPair.<backendId>`, `qaPair.dividerRatio.<backendId>`) added to `PreferencesSnapshot` apply + snapshot wiring (`project_phone_prefs_backup.md`).
- New `WebSocketClient.onQAPairLost` callback gets a `c.onQAPairLost` bridge in `BackendConnectionManager.wire()` (`project_multibackend_wire_bridge.md`).
- Test on physical iPhone 17 Pro Max (default install device per `feedback_default_install_device.md`).
- iOS QA on dedicated cloned sim (UDID `D853A014-E5D8-46F1-A81D-37860AA9DFA2`).
- Keep iPhone UI compact (`feedback_compact_ui.md`) — header chip uses icons; no fixed growth.
- Mac side IS changing → Mac rebuild required, apply stable-signing recipe (`reference_quip_install_recipe.md`).
- Skip QuipLinux / QuipAndroid mirror (`feedback_skip_linux_android.md`).

## Forward-compat hooks

- `WindowState.targetKind` is a string — adding `"browser_localhost"` is additive.
- `QAPair` carries opaque id strings — new target kinds drop in without protocol churn.
- `qa_pair_lost.reason` is free-form string — new reason codes don't break older clients.

## Decisions deferred to plan/implementation

- Exact pixel sizes for header chip / divider grab area / input bar height.
- Whether minimize-keyboard chevron lives on input bar or floats over top of keyboard.
- Toast component: reuse existing or new — depends on what's already in `QuipiOS/Views`.
