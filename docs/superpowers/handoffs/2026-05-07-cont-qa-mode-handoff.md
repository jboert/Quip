# 2026-05-07 continuation — QA mode v1 implementation handoff

Session ran from `b4a9090` (prior handoff `2026-05-07-session-handoff.md`) to `1cc5f24`. Caveman mode active throughout. Auto mode + Subagent-Driven Development for the implementation phase. Spec brainstorm + plan written first, then 16 plan tasks dispatched to fresh subagents per task with two-stage review (spec compliance + code quality).

User device: iPhone 17 Pro Max. Simulator: Quip QA — iPhone 17 Pro Max 26.4 (`D853A014-E5D8-46F1-A81D-37860AA9DFA2`).

## Commits this session (newest first)

| Hash | Why |
|------|-----|
| `1cc5f24` | QA mode (20/N) — wishlist v2 hooks + manual smoke deferred to user. |
| `a2e8777` | QA mode (19/N) — `CLAUDE.md` documents QA-mode lifecycle, log path, failure modes. |
| `bea56c7` | QA mode (18/N) — throttled `broadcast_filter` log line in Mac per-client `broadcastLayout` (5s OR count-change). |
| `11c7bbd` | QA mode (16/N) — `QuipApp.swift` wires `.pairForQA` action → picker sheet, exit/re-pair callbacks, `manager.onQAPairLost` → `errorToast`. Wraps inline grid in `MainiOSView.body` with QA-mode branch (RemoteLayoutView turned out to be unused). |
| `d5096e1` | QA mode (15/N) — `RemoteLayoutView` gains `qaPair` branch (NB: dead code in current iOS app — see Open Threads). |
| `78005f8` | QA mode (14/N) — `QAPairLayoutView` (side-by-side 50/50, draggable divider 0.30..0.70 snap [0.30,0.50,0.70], swipe-flip 40pt+2:1 ratio, header chip with re-pair + exit, input bar with chevron-down keyboard-minimize). |
| `3884af1` | QA mode (13/N) — `WindowAction.pairForQA` enum case + "Pair for QA" context menu row gated on `window.isTarget \|\| window.isTerminal`. Placeholder `case .pairForQA: return` in `sendAction` switch (replaced in 11c7bbd). |
| `894b8b5` | QA mode (12.1/N) — `WindowState.isTarget` / `WindowState.isTerminal` extension; tightened terminal match to exact `"iterm2"` / `"terminal"` (no substring). |
| `b0b5a0a` | QA mode (12/N) — `QAPairPickerSheet` — `.target` / `.terminal` modes, empty states, NavigationStack + Cancel. |
| `c28e8fe` | QA mode (11.1/N) — `private(set)` on `BackendSession.qaPair` + DRY UserDefaults key via `qaPairUserDefaultsKey`. Rebuild path uses `updateQAPair(_:)` instead of direct assign. |
| `08d217d` | QA mode (11/N) — `BackendSession.qaPair` + UserDefaults persistence; `BackendConnectionManager.onQAPairLost` host callback + `wire()` bridge; replay `set_qa_pair` on every `c.onDeviceIdentity` (covers reconnect). |
| `f8c477d` | QA mode (10/N) — `WebSocketClient.setQAPair` / `clearQAPair` / `onQAPairLost` callback + decode case. |
| `e342b17` | iOS: gate `onScrollGeometryChange` behind `if #available(iOS 18.0, *)`. **Pre-existing break** from prior commit `02f6457` blocking all iOS builds; not part of QA-mode plan but needed before iOS tasks could compile. |
| `de7047e` | QA mode (9/N) — `QAPair` Codable model + tests. |
| `d672f34` | QA mode (8/N) — `QAModeBroadcastTests.swift` covering filter + isTarget + targetKind. |
| `38e1f87` | QA mode (7.1/N) — tunnel broadcasters get unfiltered `LayoutUpdate` even when direct clients are in QA; `qaPairOffscreenSince` purges entries on every pair-clear path. |
| `54eae50` | QA mode (7/N) — per-client `LayoutUpdate` filter + snapshot-tick `validateQAPairs()` with closed/offscreen reasons. |
| `9a74719` | QA mode (6.1/N) — typed reason constants on `QAPairLostMessage.Reason` (windowClosed / windowOffscreen / connectionReset). |
| `2b9f005` | QA mode (6/N) — `set_qa_pair` / `clear_qa_pair` handlers in `QuipMacApp` + `qa-mode.log` path + `qaModeLog` helper + `onMessageWithConnection` callback on WebSocketServer. |
| `97338e4` | QA mode (5.1/N) — rename `forEachAuthenticatedClient` → `forEachAuthenticatedClientWithQAPair` + tighten doc comments. |
| `6e864aa` | QA mode (5/N) — `WebSocketServer.qaPairByConnection` storage + 5 accessor methods + cleanup hook in `removeConnection`. |
| `8d3a6ac` | QA mode (4/N) — `windowsForBroadcast(qaPair:)` filter + 4 unit tests (override mirror+enabled, mirror-on still narrows, nil falls back, missing-id returns existing half). |
| `8c38a38` | QA mode (3.1/N) — collapse `isTarget` into `targetKind != nil` with `switch` on bundleId for v2 extensibility. |
| `adca697` | QA mode (3/N) — `ManagedWindow.isTarget` + `targetKind` properties; plumbed through `toWindowState`. |
| `4d5fdbf` | QA mode (2/N) — `WindowState.targetKind: String?` field (lenient decode for backward compat). |
| `b19fc14` | QA mode (1.1/N) — round-trip tests use `MessageCoder.encoder/decoder` instead of bare `JSONEncoder/JSONDecoder`. |
| `3644286` | QA mode (1/N) — `SetQAPairMessage` / `ClearQAPairMessage` / `QAPairLostMessage` protocol structs with snake_case wire keys. |
| `a383fc2` | Plan: QA mode v1 — 20 tasks, TDD where it pays. |
| `ecdcea6` | Spec: QA mode (paired Simulator + terminal layout). |

29 commits total. All on `eb-branch`, **NOT pushed** per `feedback_eb_branch_push_policy.md` (durable rule overrides hook's push instruction).

## Test results

- Mac (`QuipMac` scheme): **333/333 passed**, 0 failures.
- iOS (`QuipiOS` scheme on QA sim `D853A014-E5D8-46F1-A81D-37860AA9DFA2`): **349/349 passed**, 0 failures.
- Total: **682 tests, 0 failures**.

## Install state

- **Mac** `/Applications/Quip.app` — mtime `Apr 16 15:22:04 2026`. **Predates this session entirely.** Does NOT contain any QA-mode Mac changes (Tasks 1-8, 18). Mac rebuild + stable-signing reinstall required before any phone smoke test can exercise the Mac side.
- **iOS iPhone 17 Pro Max** — not installed this session. iOS app needs `devicectl install app` before manual smoke (Task 17).
- **iOS QA simulator** (`D853A014-E5D8-46F1-A81D-37860AA9DFA2`) — used for unit-test runs only this session; phone-side QA-mode UI never exercised in interactive mode.

## Hardware-verified vs install-only matrix

| Component | Built | Tested | Hardware-verified |
|---|---|---|---|
| Shared protocol (set/clear/lost messages, `targetKind`) | ✅ | ✅ unit | n/a (compile-time + JSON round-trip) |
| Mac filter, storage, validator, log throttle | ✅ | ✅ unit | ❌ — needs Mac install |
| iOS QAPair model + Codable | ✅ | ✅ unit | n/a |
| iOS WebSocketClient send/recv | ✅ | ❌ no unit | ❌ — needs phone install |
| iOS `BackendSession.qaPair` persistence + reconnect replay | ✅ | ❌ no unit | ❌ — needs phone install |
| iOS `QAPairPickerSheet` (target/terminal modes) | ✅ | n/a UI | ❌ — needs phone install |
| iOS context menu "Pair for QA" row | ✅ | n/a UI | ❌ — needs phone install |
| iOS `QAPairLayoutView` (split/divider/swipe/input) | ✅ | n/a UI | ❌ — needs phone install |
| iOS `QuipApp` wiring (entry/exit/toast) | ✅ | n/a UI | ❌ — needs phone install |
| End-to-end pair → broadcast filter → render | ✅ | ❌ | ❌ — needs both installs |
| `qa_pair_lost` recovery (close Sim → toast → exit QA) | ✅ | ❌ | ❌ — needs both installs |
| Reconnect replay (force-quit phone, relaunch) | ✅ | ❌ | ❌ — needs both installs |
| Mac restart while phone in QA → graceful exit | ✅ | ❌ | ❌ — needs both installs |

**Net: every QA-mode behavior is install-only at session end.** None has been exercised on real hardware.

## Open threads

1. **Task 17 (manual smoke pass)** — DEFERRED. 16-step flow documented in `docs/superpowers/plans/2026-05-07-qa-mode.md` Task 17. Requires:
   - Mac install via stable-signing recipe (`reference_quip_install_recipe.md`).
   - iOS install via `devicectl install app` to physical iPhone 17 Pro Max + force-quit + relaunch.
   - Then run the 16 steps (long-press → pair → side-by-side → divider snaps → tap-select → swipe-flip → type/send → keyboard min/max → close-Sim toast → reconnect-replay → mac-restart-rejection → app-relaunch-restore).

2. **Task 20 (final acceptance)** — DEFERRED. Re-run smoke after any user-found polish.

3. **`RemoteLayoutView` is dead code.** Task 15 added a `qaPair` branch to `RemoteLayoutView`, but `RemoteLayoutView` is declared and never instantiated by the iOS app — `MainiOSView.body` renders the grid inline. Task 16 wrapped the inline grid directly. Cleanup options recorded in wishlist:
   - Remove the QA branch from `RemoteLayoutView` (and possibly the file itself).
   - OR wire `RemoteLayoutView` into the iOS app properly (cleanup of much older drift).

4. **Legacy-id orphan UserDefaults entry.** When `BackendConnectionManager.onDeviceIdentity` rekeys a session from synthetic legacy id to real UUID, the UserDefaults entry under `qaPair.<legacy-id>` is orphaned. Harmless (key namespaced, never collides; first restart after rekey loses persistence until next `updateQAPair`). Cleanup could land an `UserDefaults.standard.removeObject(forKey: "qaPair.\(oldID)")` in the rebuild path.

5. **Phone-side `WindowState.isTerminal` matches by exact lowercased app name.** Any new terminal emulator added on the Mac (beyond iTerm2 / Terminal.app) requires updating the set in `QuipiOS/Models/WindowState+QAMode.swift` or QA-mode pairing will silently exclude it. Documented inline.

6. **Pre-existing iOS deployment break** (`onScrollGeometryChange` is iOS 18+; target was 17.0) was repaired in `e342b17` with `if #available(iOS 18.0, *)` guard. iOS 17 users now get the pre-§36 scroll behavior in InlineTerminalContent — works, just no auto-pin-to-bottom optimization. Not strictly a QA-mode issue but worth flagging.

## v2 hooks (no work yet — design accommodates)

- `WindowState.targetKind` is a free-form string; adding `"browser_localhost"` is purely additive.
- `BrowserURLExtractor` parallel to `TerminalURLExtractor` (AX-scrape Safari/Chrome/Arc URLs, regex match `localhost|127\.0\.0\.1|:\d+`) is the v2 entry point.
- `KeystrokeInjector` extension for non-terminal paste (focus Sim via `NSRunningApplication.activate` + `NSPasteboard.general` + simulated `⌘V`) — toggles Sim from read-only to writable.
- Multi-pair management, refresh-rate boost on the pair, header-chip backend-cycle chevron, push-to-text primary input — all listed in wishlist with rationale.

## Resume one-liner

> **For a fresh session:** read `docs/superpowers/specs/2026-05-07-qa-mode-design.md` + `docs/superpowers/plans/2026-05-07-qa-mode.md` + this handoff (`docs/superpowers/handoffs/2026-05-07-cont-qa-mode-handoff.md`); 29 commits at HEAD `1cc5f24` — local only on `eb-branch`, not pushed. Mac + iPhone install + run Task 17 16-step manual smoke pass to validate, fix any UI/UX nits found, then re-run for Task 20 final acceptance. iOS QA sim UDID `D853A014-E5D8-46F1-A81D-37860AA9DFA2`. iPhone 17 Pro Max install via `devicectl`.
