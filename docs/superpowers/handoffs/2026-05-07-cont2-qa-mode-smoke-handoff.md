# 2026-05-07 cont-2 — QA mode v1 smoke pass + 2 wire-up fixes — handoff

Continuation of `2026-05-07-cont-qa-mode-handoff.md`. This round drove Task 17 smoke pass on the Quip QA simulator's Quip iOS instance, found two implementation gaps the unit tests didn't catch, fixed them, and pushed everything.

Caveman mode active throughout. Auto mode + ios-simulator-skill scripts used to drive sim UI where possible.

## Session HEAD: `a803838` (pushed to `origin/eb-branch`)

3 commits this round, all on `eb-branch`, all pushed:

| Hash | Why |
|------|-----|
| `a803838` | QA mode (17c/N) — wishlist Task 17 smoke partial + 2 v2 asks recorded |
| `2bbec18` | QA mode (17b/N) — `Pair for QA` row added to `WindowRectangle.contextMenu` (the actual long-press menu); Task 13 had only added it to `ContextMenuView` (alternate sheet-style overlay), so users saw every existing row but no pairing entry |
| `8e8da66` | QA mode (17a/N) — `windowsForBroadcast` includes visible targets in default `mirror=off` path; without this, Sim tiles never appeared in the grid → QA mode unreachable. +2 unit tests pinning the new visibility paths |

Total session (cont-1 + cont-2): 33 commits on `eb-branch`.

## Bugs found + fixed this round

1. **Sim tiles invisible in default broadcast (`8e8da66`).** Plan/spec assumed targets would be discoverable in the grid, but `windowsForBroadcast(mirrorDesktop: false)` only included `isEnabled` windows. Sim windows are non-terminal, non-enabled by default — they never appeared, so the user had nothing to long-press for QA pairing. Fix: targets ride along the default broadcast when on-visible-screen, identical treatment to terminals in mirror=on. Off-screen disabled targets still filtered (other-Space / disconnected-monitor case).
2. **"Pair for QA" missing from long-press menu (`2bbec18`).** Task 13 added the row to `ContextMenuView` (alternate sheet view, only used for custom overlay presentations). The actual long-press menu lives in `WindowRectangle.swift` via the `.contextMenu` modifier and was never updated. Result: every existing row visible (Press Return, View Output, Restart Claude, etc.) but no pairing affordance. Fix: added Button gated on `isTarget || isTerminal` between Restart Claude and the destructive-divider section.

Both bugs are 100% logical-fix cleanups; same gating predicate (`isTarget || isTerminal`) and same iconography (`rectangle.split.2x1`) as the spec called for, just landed on the right code path now.

## Verified end-to-end on QA sim's Quip iOS

| Step | Status | Notes |
|------|--------|-------|
| Sim tile in grid | ✅ | After `8e8da66` filter fix |
| Long-press Sim tile | ✅ | After `2bbec18` wire fix |
| "Pair for QA" row in context menu | ✅ | Icon + label match spec |
| Tap → picker sheet | ✅ | Lists terminals (iTerm2 + Terminal.app) when entered from a target tile |
| Tap iTerm2 in picker → side-by-side | ✅ | Renders 50/50 with header chip |
| Header chip with re-pair (`rectangle.split.2x1`) + exit (`xmark`) | ✅ | Top of layout, both buttons visible |
| Divider drag with snaps to 0.30 / 0.50 / 0.70 | ✅ | User confirmed "dragging appears to work" |
| Tap each pane → border moves | ✅ | Selection follows tap |
| Horizontal swipe across panes → selection flip | ✅ | User confirmed swipe-flip works (selection-only, NOT pane position swap) |
| Sim selected → TextField + Send disabled | ✅ | "Read-only — switch to terminal to type" hint visible |
| Pair persistence (`set_qa_pair` over WS) | ✅ | qa-mode.log shows wire format correct |
| Per-client broadcast filter (in=N, out=2) | ✅ | qa-mode.log throttled `broadcast_filter` lines confirm |
| Connection-close cleanup (no orphan pair) | ✅ | After sim shutdown, no leaked entries in qaPairByConnection |
| Validator rejects stale IDs at receive | ✅ | `set_qa_pair rejected: targetId=...39569 missing` lines after Mac restart confirm Mac-side guard |

## Unverified (carry-over to next session)

| Step | Why not driven | Path to verify |
|------|----------------|----------------|
| Type+Send → text reaches iTerm2 | Smoke session ran out of pair stability before user drove it | Pair on physical iPhone, type, tap Send, watch iTerm2 on Mac |
| Chevron-down → keyboard min, panes expand | Same | Pair on phone, tap chevron, observe layout |
| `xmark` exit returns to grid | Same | Pair on phone, tap xmark, confirm grid |
| `qa_pair_lost` via `window_closed` | Sim pair self-destructs when sim shuts down (the WS connection itself dies, pair cleaned by close-hook NOT validator) | Pair on PHYSICAL iPhone with a Sim window, then close that Sim window from Mac. Connection survives, validator fires `qa_pair_lost reason=window_closed`, phone shows toast "Simulator closed. Exited QA mode." |
| Reconnect replay | Not driven | Pair on phone, force-quit Quip phone, relaunch — confirm pair restored from `UserDefaults("qaPair.<backendID>")` |
| Mac restart → graceful exit | Not driven | Pair on phone, ⌘Q Mac Quip, watch phone reconnect → replay `set_qa_pair` → Mac rejects (no matching ids on fresh Mac) → phone receives `qa_pair_lost reason=connection_reset` → toast → exits |

The unit tests in `Shared/Tests/MirrorDesktopFilterTests.swift` (10 tests, including 2 new for the visibility fix) and `QuipMac/Tests/QAModeBroadcastTests.swift` (6 tests) cover the validator + filter math directly. The integration tests above are the *visual* smoke that needs hardware.

## Test counts at HEAD

- Mac (`QuipMac` scheme): **335/335 passed** (was 333 in cont-1; +2 from new visibility tests).
- iOS (`QuipiOS` scheme on QA sim D853A014): not re-run this round (no shared-protocol changes; the iOS bug was a wire-up only). Last clean run was cont-1 at 349/349.
- Total (last verified): **684 tests, 0 failures**.

To re-run before any future commit:

```bash
xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS' test 2>&1 | tail -5
xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination 'id=D853A014-E5D8-46F1-A81D-37860AA9DFA2' test 2>&1 | tail -5
```

## Install state at session end

- **Mac** `/Applications/Quip.app` — built, stable-signed (Team `D2PM6R797Q`, cert `813F0602…1C4EBF`), dittoed at `May 7 13:29:45 2026`. WS listening on `*:8765`. Ready for any client.
- **Physical iPhone 17 Pro Max** (UDID `FA951BBB-D706-5FCF-9886-3E57560E9030`) — Quip iOS installed at `13:08:12` (Debug-iphoneos build). Reflects HEAD `a803838`. User force-quit + relaunched at least once during smoke; pair-from-physical state at session end unknown (sim drove most smoke).
- **QA sim** Quip QA — iPhone 17 Pro Max 26.4 (UDID `D853A014-E5D8-46F1-A81D-37860AA9DFA2`) — Quip iOS installed (Debug-iphonesimulator build). Booted at session end. Quip iOS app PID was alive but the connection has been bouncing on link-local 169.254.x addresses; recommend force-quit + relaunch on any next-session smoke.

## v2 asks surfaced this round (in `docs/superpowers/wishlist.md`)

1. **Live content in QA panes** (top user ask). v1 panes show colored `WindowRectangle` tiles — user's first reaction was "am I able to see the contents?" → no. To deliver: refactor `terminalContentView` (currently parameterized by `selectedWindowId` state) into a per-window-id view, render one in each pane, drive content updates for both paired windows even when one is "selected." Per-pane `terminalContentText` / `terminalContentScreenshot` state, Mac-side push to send content for both pair halves, then `pane(window:)` swaps from `WindowRectangle` to that view. Side-of-screen swap (currently swipe-flip is selection-flip only) is a nice-to-have on the same code path.
2. **Accessibility labels on grid tiles**. While trying to drive smoke via `ios-simulator-skill`'s `screen_mapper.py` and `navigator.py`, the tiles surfaced as zero accessibility elements — they're SwiftUI tap-gesture views without `accessibilityLabel`. Adding labels (e.g., `"Window: nugget-expo iTerm2"`) unlocks UI-test automation AND improves VoiceOver UX. Cheap fix.
3. **Mac-side debug to drop a window from snapshot without WS churn**. The `qa_pair_lost reason=window_closed` test path is hard to isolate when the paired Sim is also hosting the phone-side test client (sim shutdown drops the WS connection, pair cleaned via close-hook before validator can run). A Mac-side `simulate_window_closed` debug command would make this code path testable without WS churn.

Items 1 + 2 are the natural next-session targets if not driving the 3 recovery cases first.

## Resume one-liner

> **For a fresh session:** read `docs/superpowers/specs/2026-05-07-qa-mode-design.md` + `docs/superpowers/plans/2026-05-07-qa-mode.md` + the cont-1 handoff (`docs/superpowers/handoffs/2026-05-07-cont-qa-mode-handoff.md`) + this handoff. HEAD is `a803838` on `eb-branch`, pushed. Mac and physical iPhone both on latest. Pick one of:
> - **Finish smoke** (~10 min): pair on PHYSICAL iPhone, drive type+Send / chevron / xmark, then close paired Sim from Mac to fire `qa_pair_lost` window_closed, then force-quit phone for reconnect-replay, then ⌘Q Mac for connection_reset path.
> - **v2 work**: live content streaming in QA panes (top ask) OR accessibility labels on grid tiles (small, unlocks UI automation).
