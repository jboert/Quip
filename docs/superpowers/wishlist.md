# Quip Wishlist

Future features, improvements, and known bugs tracked for eventual implementation. Each item here is a candidate for a GitHub issue or sprint work. When you're ready to implement one, it should graduate to a spec in `docs/superpowers/specs/` and a plan in `docs/superpowers/plans/`, then land as a commit on a working branch.

**Scrub history:** 2026-05-05 — collapsed verbose ✅ Done bodies to status line + commit hash. Original context lives in git log + code; the entries here track *what shipped* not *how*. Wishlist / In Progress / Blocked items kept full. Tabled §55 (Universal Clipboard already covers it) and §52 (no iPad).

---

## Session log — 2026-05-24 (Quip Labs beta features — §0 + §7.4 shipped)

HEAD `9003bcd`. Four-feature Labs effort, built by **extension** (no parallel systems).
Design: `specs/2026-05-24-quip-labs-beta-features-design.md`. Plan: `~/.claude/plans/polished-wondering-garden.md`.
Full handoff: `handoffs/2026-05-24-labs-beta-features-handoff.md`. Tests: QuipMac 346 / QuipiOS 367 green.

### Shipped (`9003bcd`)
- **§0 Quip Labs** — opt-in Settings → Quip Labs section; `LabsFlags` registry; all flags default off
  (`labs.cursorAgent`, `labs.oneTapAnswer`, `labs.promptPackSharing`).
- **§7.4 Cursor agent** — `CLIKind.cursor` + `SpawnAgent.cursor`; Mac classifies `cursor-agent`
  (below codex, above node→claude) + routes/spawns it; Cursor in the iOS agent picker gated by
  `labs.cursorAgent`. ⚠️ Cursor not installed on dev box — process name + routing are assumptions,
  verify on a device with Cursor (currently routed like Claude / sendText).

### Shipped (cont. 2026-05-25)
- **§3.2 One-tap answers** — DONE (`acf1b60`, `84c9d85`, `ab200ca`, `d113537`, `e36dab1`).
  Detector moved to Shared + fingerprint/yes-no; Mac sends dynamic push categories
  (`waiting.yn/.12/.123/.1234`) with `quip_options`+`quip_prompt_fingerprint`; iOS registers the
  category set, unifies answers onto `select_N`/`press_y`/`press_n` and echoes the fingerprint;
  Mac re-validates (`answerStillValid`) and drops stale answers with "Prompt changed — not sent";
  Labs-gated prominent in-app buttons (`labs.oneTapAnswer`). Tests: Mac 371 / iOS 383.

- **§6.1 Prompt/hot-button packs** — DONE (`997ded0` metadata+front-matter, `436c9cb` SharedPromptPack
  model, `da89497` uniquePromptID/remint, `33694f8` export/import UI). Share prompts/buttons as `.quippack`;
  import via "Open in Quip" → preview → apply (non-colliding prompt ids, reminted button UUIDs). All
  Labs-gated (`labs.promptPackSharing`).

### All four Labs features SHIPPED — remaining is on-device validation only
- One Mac rebuild + reinstall (re-grant Accessibility + Screen Recording), then verify on a device:
  Cursor spawn/classify (Cursor not yet installed), one-tap answers incl. stale→"Prompt changed",
  pack export→import. Optional: Mac version bump 1.5.2→1.5.4.

### Notes for next session
- Projects are xcodegen-globbed → new/moved files need only `xcodegen generate` (no pbxproj surgery).
- iOS tests require watchOS 26.5 runtime (installed). Dedicated QA sim recreated 2026-05-24:
  `Quip QA — iPhone 17 Pro Max` UDID `3B2ACF04-1B0A-4842-827C-5B1699B8D4F8` (iOS 26.4).
  Final on-device verify needs one Mac rebuild (re-grant TCC).

---

## Session log — 2026-05-07 cont-3 (QA mode v1.5 — live content + focus mode + a11y)

HEAD `4f2c8c8` (pushed pending). Eleven-task plan from `docs/superpowers/plans/2026-05-07-qa-mode-v1.5.md` driven via subagent-driven-development. 354/354 iOS tests passing, 335/335 Mac tests passing.

### v1.5 scope shipped (16 commits this round)

- **Live per-pane content**: per-windowId state maps (`terminalContent{Text,Screenshot,URLs}ById`) replace the single-window state slots in QA panes. Both pair halves refresh simultaneously on the existing screenshot cadence. Bug fix `4964df5` plumbed `onRefresh` so the periodic timer chain still fires; `4102841` purges both slots on QA exit / `qa_pair_lost`.
- **Focus mode**: cycle arrows, follow-frontmost auto-pin, spawn / arrange / photo / prompts buttons all gated `&& !isQAModeActive` in `MainiOSView`. PTT mic, keyboard, Send still visible. `cycleWindow(direction:)` early-returns in QA. Final-review fix added the same guard to `volumeHandler.onSelectionChanged` so volume-button cycling honors QA mode.
- **Accessibility labels**: `WindowRectangle` now exposes `accessibilityLabel("Window: \(app) — \(folder ?? name)")` + `accessibilityHint(...)` so VoiceOver and `ios-simulator-skill`'s `screen_mapper.py` can address grid tiles by meaning.
- **Position-swap chip**: `arrow.left.arrow.right` button in the header chip swaps which window renders left vs right. Persisted per-backend via `BackendSession.swapKey(forBackendId:)` → `UserDefaults("qaPair.swapped.\(backendId)")`. `init` re-seeds `@State` from defaults so the choice survives view recycling.
- **Divider drag UX (cont-3 user-feedback iteration, `3ecde3f`)**: 4pt visible line + 3×24pt low-opacity grip pill + 44pt invisible hit zone via `.contextShape(Rectangle().inset(by: -20))`. `.highPriorityGesture` on the divider so its `DragGesture(minimumDistance: 1)` wins over the parent HStack `swipeFlipGesture` (was eating slow drags). Double-tap divider snaps to 50/50.
- **Final review fixes (`4f2c8c8`)**: sticky content writes (no flicker on transient `screencapture` failure), volume-cycle gated in QA, header separator changed from `arrow.left.arrow.right` to `circle.fill` so it stops looking like the swap button.

### Bugs caught by review (all fixed)

1. `applyContent` was clearing the screenshot/urls slots on nil/empty input while legacy single-state was sticky → QA panes flickered for one tick on transient capture fails. Fixed with sticky semantics + `testApplyContentIsStickyOnNilScreenshotAndEmptyURLs`.
2. `volumeHandler.onSelectionChanged` not gated on QA mode → volume buttons could change selection out from under the pair, second pane went stale. Fixed with same `manager.active.qaPair != nil` early-return as `cycleWindow`.
3. Header chip used `arrow.left.arrow.right` for both static separator AND swap button → visually ambiguous. Static separator changed to a small filled dot.

### Skipped / future work

- **Task 11 — full single-state cleanup**: `BackendSession.swift` and `BackendConnectionManager.swift` still hold legacy `terminalContentText/Screenshot/URLs/WindowId` for the phone-prefs-backup mechanism. Removing them without migrating the prefs backup would break sync. Documented as v1.6+ work.
- **Sim writability** (KeystrokeInjector): out of scope per use case (agent drives the Sim, not the human).
- **Browser-on-localhost target type**: separate spec, ships as v2.
- **Multi-pair management**: single pair per backend stays the limit.
- **Refresh-rate boost**: only if v1.5 field testing shows lag.

### Smoke pass (driven this session)

| Step | Status | Notes |
|------|--------|-------|
| Sim tile in grid + long-press → "Pair for QA" → picker → side-by-side | ✅ | Carried over from cont-2 fixes |
| **Live content in BOTH panes** | ✅ | Headline v1.5 deliverable confirmed on physical iPhone |
| Position-swap chip swaps left↔right + persists | ✅ | User confirmed |
| Focus mode hides cycle/spawn/arrange/photo/prompts | ✅ | User confirmed |
| Divider drag with grip pill + 44pt hit zone | ✅ | User-driven UX iteration mid-session |
| Double-tap divider → 50/50 snap | ✅ | New escape hatch |
| All 354 iOS tests passing | ✅ | +1 sticky-write test added in final-review pass |
| All 335 Mac tests passing | ✅ | No Mac-side changes this round |

---

## Session log — 2026-05-07 (QA mode v1 — paired Simulator + terminal layout)

19 commits on `eb-branch`. Started after `b4a9090`. Spec at `docs/superpowers/specs/2026-05-07-qa-mode-design.md`. Plan at `docs/superpowers/plans/2026-05-07-qa-mode.md`.

| Section | Status | Commit | Hardware-tested |
|---------|--------|--------|-----------------|
| Tasks 1–8: Shared protocol + entire Mac side (set/clear/lost messages, WindowState.targetKind, ManagedWindow.isTarget+targetKind, windowsForBroadcast(qaPair:), per-connection storage, message handlers, per-client filter, snapshot validator, Mac unit tests) | ✅ | through `d672f343` | n/a (Mac unit tests pass — 333/333) |
| iOS deployment-target fix — `onScrollGeometryChange` gated on iOS 18 (pre-existing break from `02f6457`) | ✅ | `e342b178` | n/a (build fix) |
| Tasks 9–16: phone side (QAPair model + tests, WebSocketClient send/recv, BackendSession persistence + reconnect replay, picker sheet, WindowAction.pairForQA + context menu row, QAPairLayoutView, RemoteLayoutView branch, QuipApp wiring) | ✅ | through `11c7bbd4` | install + 16-step smoke pass DEFERRED to user (Task 17) |
| Task 18: throttled broadcast_filter log line | ✅ | `bea56c7` | n/a (Mac code) |
| Task 19: CLAUDE.md QA mode docs | ✅ | `a2e8777` | n/a (docs) |
| Task 20: final acceptance — all tests passing (333 Mac + 349 iOS = 682) | ✅ tests pass; manual smoke deferred | tests verified | DEFERRED |

### v1 scope shipped

- Pair source: target (Simulator only in v1) + terminal. Never two terminals or two targets.
- Phone-side picker sheet, long-press → "Pair for QA" entry, header chip with re-pair + exit, side-by-side 50/50 with draggable divider (clamps 0.30–0.70, snaps to [0.30, 0.50, 0.70]), horizontal swipe-to-flip selection.
- Mac per-connection broadcast filter (only the 2 paired windows ride out for that connection); tunnel broadcasters always get unfiltered.
- Snapshot-tick validator with 5s grace for off-screen; immediate `qa_pair_lost` for closed windows.
- Pair persistence per-backend via `UserDefaults` keyed `"qaPair.<backendID>"`; `dividerRatio` per-backend in `@AppStorage`.
- Sim is read-only (TextField + Send disabled when target selected; "Read-only — switch to terminal to type" hint).
- Reason constants on `QAPairLostMessage.Reason` (windowClosed / windowOffscreen / connectionReset).
- Toast on `qa_pair_lost`: `<App name> closed. Exited QA mode.` (3s auto-dismiss, mirrors existing `errorToast` path).
- Per-tick throttled `broadcast_filter` log to `~/Library/Logs/Quip/qa-mode.log` (5s OR count-change).

### Outstanding (DEFERRED to user)

- **Task 17 — manual hardware smoke pass**: Mac install via stable-signing recipe (`reference_quip_install_recipe.md`), iPhone install via `devicectl` to UDID for "iPhone 17 Pro Max", then run the 16-step flow documented in `docs/superpowers/plans/2026-05-07-qa-mode.md` Task 17. Required to validate visual layout, gesture feel, end-to-end pair lifecycle, and toast behavior in real conditions.
- **Task 20 — final acceptance**: re-run Task 17 smoke after any user-found polish iterations.

### v2 hooks (deferred — design accommodates)

- **Browser-on-localhost target**: `WindowState.targetKind` is a string for forward compat. Add `"browser_localhost"` value + a Mac-side `BrowserURLExtractor` (parallel to `TerminalURLExtractor`) that AX-scrapes Safari/Chrome/Arc URLs and returns true when matching `localhost|127\.0\.0\.1|:\d+`. No protocol changes needed.
- **Sim text injection**: extend `KeystrokeInjector` with a non-terminal paste path (focus Sim via `NSRunningApplication.activate`, then `NSPasteboard.general` + simulated `⌘V`). Toggle Sim from read-only to writable when this lands.
- **Named/saved multi-pair management**: not asked for in v1; would require Mac-side pair store + UI for pair selector. v1 has single active pair per backend.
- **Refresh-rate boost on the pair**: bandwidth is freed up by the filter, so the pair's screenshots could push at higher fps. Currently keeps existing snapshot cadence.
- **Backend cycle while in QA**: spec called for a header-chip chevron menu to switch backends without leaving QA. v1 expects the user to tap ✕ to exit QA, switch backends via existing chrome, and re-enter QA on the new backend. Header chip already has the affordance space for a chevron when v1.5 lands.
- **Push-to-text** as primary input affordance (vs PTT). v1 keeps PTT prominent + Enter prominent + manual chevron-down minimize. Future iteration when push-to-text UX is designed.

### Notes / minor follow-ups

- `RemoteLayoutView.swift` was extended with a QA-mode branch (Task 15) but the iOS app actually renders the grid inline in `MainiOSView.body` — not via `RemoteLayoutView`. The Task 15 changes are dead code. Either wire `RemoteLayoutView` into the iOS app (cleanup), or remove the QA branching from `RemoteLayoutView` and document it as the inline-only path.
- `BackendSession.qaPair` UserDefaults entries under the synthetic legacy backend ID get orphaned when `onDeviceIdentity` rekeys to the real UUID. Harmless (key namespaced, never collides), but a future cleanup could add `UserDefaults.standard.removeObject(forKey: "qaPair.\(oldID)")` in the rebuild path.
- Phone-side `WindowState.isTerminal` matches by exact lowercased app name (`"iterm2"` / `"terminal"`). Adding a new terminal emulator on the Mac requires updating this set or QA-mode pairing will silently exclude it. Documented at `QuipiOS/Models/WindowState+QAMode.swift`.

## Session log — 2026-05-07 cont (QA mode v1 — Task 17 smoke pass partial)

Continuation of QA mode v1 session. 2 fix commits + smoke drive on QA sim's Quip iOS instance.

| Section | Status | Commit | Hardware-tested |
|---------|--------|--------|-----------------|
| Discoverability fix — `windowsForBroadcast` includes visible targets in mirror=off path | ✅ | `8e8da66` | n/a (Mac unit tests pass, smoke confirmed) |
| Wire fix — `Pair for QA` row added to `WindowRectangle.contextMenu` (the actual long-press menu); Task 13 had only added it to `ContextMenuView` (alternate sheet) | ✅ | `2bbec18` | yes (sim smoke) |
| Mac install (rebuild + stable-sign + ditto) at HEAD `2bbec18`+`8e8da66` | ✅ | n/a | yes |
| iOS install (physical iPhone 17 Pro Max + QA sim) | ✅ | n/a | yes (sim) / install-only (physical) |
| Smoke: Sim tile in grid → long-press → "Pair for QA" appears | ✅ | n/a | yes (sim) |
| Smoke: picker sheet → tap iTerm → side-by-side renders | ✅ | n/a | yes (sim) |
| Smoke: divider drag with 0.30/0.50/0.70 snaps | ✅ | n/a | yes (sim) |
| Smoke: tap-pane to select + horizontal swipe-flip selection | ✅ | n/a | yes (sim) |
| Smoke: Sim selected = Send disabled + read-only hint visible | ✅ | n/a | yes (sim) |
| Smoke: type+send → text reaches iTerm2 | ⚠️ unverified | n/a | not driven |
| Smoke: chevron-down keyboard min | ⚠️ unverified | n/a | not driven |
| Smoke: xmark exit returns to grid | ⚠️ unverified | n/a | not driven |
| Smoke: `qa_pair_lost` window_closed reason | ⚠️ unverified | n/a | sim-shutdown closed the WS connection itself; pair cleaned by connection-close hook, NOT by validator |
| Smoke: reconnect-replay (force-quit phone, relaunch → pair restored) | ⚠️ unverified | n/a | not driven |
| Smoke: Mac restart → phone receives `qa_pair_lost` | ⚠️ unverified | n/a | not driven |

### Bugs found + fixed during smoke

1. **Sim windows never broadcast in default mode.** `windowsForBroadcast(mirrorDesktop: false)` only included `isEnabled` windows. Sim windows are non-terminal, non-enabled by default → never appeared in the grid → user couldn't long-press to enter QA. Fixed in `8e8da66`: targets ride along default broadcast when on-visible-screen, same as terminals in mirror=on path. Added 2 unit tests pinning the new visibility paths.
2. **"Pair for QA" row missing from long-press menu.** Task 13 added the row to `ContextMenuView` (alternate sheet-style overlay), not to `WindowRectangle.swift` `.contextMenu` modifier — the latter is what fires on long-press. Result: row never visible. Fixed in `2bbec18`: added Button gated on `isTarget || isTerminal` between Restart Claude and the destructive-divider section.

### New v2 asks surfaced this round

- **Live content in QA panes (highest priority).** v1 panes use `WindowRectangle` (colored tile + label). User's first reaction: "am I able to see the contents?" → no. To deliver: refactor `terminalContentView` (currently parameterized by `selectedWindowId` state) into a per-window-id view, render one in each pane, drive content updates for both paired windows even when one is "selected." Rough scope: per-pane `terminalContentText` / `terminalContentScreenshot` state, Mac-side push to send content for both pair halves, then `pane(window:)` swaps from `WindowRectangle` to that view. Side-of-screen-swap (currently swipe-flip is selection-flip only) is a nice-to-have on the same code path.
- **Long-press menu on grid tiles needs accessibility labels.** While trying to drive smoke via `ios-simulator-skill` scripts (`screen_mapper.py`, `navigator.py`), the grid tiles surfaced as zero accessibility elements — they're SwiftUI tap-gesture views without `accessibilityLabel`. Adding labels (e.g., "Window: nugget-expo iTerm2") would unlock end-to-end UI test automation and improves VoiceOver UX.
- **`qa_pair_lost` window_closed test path is hard to isolate** when the paired Sim is also hosting the phone-side test client. Future testability: a Mac-side debug command to drop a specific window from the snapshot without touching the connection (so the validator path is exercisable without WS churn).

### Outstanding for next session

- Drive remaining 6 smoke steps on physical iPhone (type/send/chevron/exit + 3 recovery cases).
- v2 work: live content streaming in panes, accessibility labels on grid tiles.

## Session log — 2026-05-06 (§B16 + log-spam burn-down)

6 commits, all pushed to `origin/eb-branch`. Started after `c6eb974`.

| Section | Status | Commit | Hardware-tested |
|---------|--------|--------|-----------------|
| §B16 Mac broadcast frontmost (NSWorkspace + 400ms AX poll + FrontmostChangedMessage + PreferencesSnapshot field) | ✅ | `b6ef907` | install only — needs phone follow-frontmost smoke |
| §B16 iOS receive + Auto pill + manual-tap pin | ✅ | `918cb5c` | install only — needs phone smoke |
| Continuation 3 handoff (recap + resume one-liner) | ✅ | `18cdf5b` | n/a (docs) |
| Mac log-spam fix (NWProtocolWebSocket opcode filter + Kokoro log-once) | ✅ | `3a3a7c7` | yes (Mac live verify, control-frame filter shipped, kokoro log-once shipped) |
| iOS prefs storm + select_window heal on reconnect | ✅ | `f471415` | yes (live monitor: 0 prefs_snapshot post-fix vs ~30/min before) |
| §B17 wishlist file (4-byte unknown trace) | ✅ | `80d5d3c` | n/a (docs) |

Tail finding: `type=unknown (4 bytes)` survived the opcode filter — the payload is a TEXT frame, not a control frame. Filed as §B17 for next-session trace.

## Session log — 2026-05-04 (autonomous burn-down)

20 commits on `eb-branch`. Started after `64a8376` (§44 iOS WS resilience).

| Section | Status | Commit | Hardware-tested |
|---------|--------|--------|-----------------|
| §45 Mac NWPath + stall watchdog | ✅ | `352be75` | yes (Mac) |
| PTT lifecycle fix (pauseMonitoring split + 100ms suppression) | ✅ | `efb49c7` | yes (iPhone) |
| PTT route-change hardware-only filter + telemetry | ✅ | `149bcf6` | yes (iPhone) |
| §46 iOS Connection diagnostics panel | ✅ | `6668893` | yes (iPhone) |
| §47 Image upload encoder | ✅ then reverted | `684956b` → `2097684` | yes (failed → fixed) |
| §48 Mac menubar last-event + tunnel state | ✅ | `45346ed` | yes (Mac) |
| §49 Diagnostics bundle (Mac share + iOS request) | ✅ | `d0a69bc` | yes (both) |
| §B1 Custom Buttons scroll-conflict fix | ✅ | `067c0a2` | yes (iPhone) |
| §53 v1 Apple Watch glance | ✅ | `a2c977b` | install only — needs Watch verify |
| §50 v1 QR pairing | ✅ | `a52ad4f` | install only — needs end-to-end pair |
| §57 v1 Mac prompt library + Stream Deck importer | ✅ | `ad4fb57` | yes (both) |
| §57 v2 iPhone prompt editor (create/edit/delete) | ✅ | `fcd2ba1` | install only — needs verify |
| §B3 Prompts as keyboard quick-buttons | ✅ | `2ec3ed9` | install only — needs verify |
| §B6 addMenu observation-chain leak + sheet picker rewrite | ✅ | `3dbc7da` + `5a00a36` | yes (iPhone) |
| §B7 Prompts as main-row button option | ✅ | `3dbc7da` | yes (iPhone) |
| §B5 Per-client visibility (Mac + iOS transport tag) | ✅ | `2cbeb21` | yes (iPhone) |
| §B8 Live captions regressed on remote Whisper path | ✅ | `4751272` | yes (iPhone) |
| §B9 Auto-pick first window on layout (PTT silent-fail fix) | ✅ | `6d47a51` | yes (iPhone) |
| §B10 Paired-backends dedupe on load + addPaired URL match | ✅ | `93cc9a8` | yes (iPhone) |
| §B11 SpeechService weak-ref drop fix + 4 tests | ✅ | `059f614` + `314b37d` | yes (iPhone) |
| §B12 Strip Whisper [BLANK_AUDIO] tokens + 8 tests | ✅ | `a6afdc5` | needs verify (Mac) |
| §B4 Prompts paste-wrong-window — closure-resolver fix | ✅ | `bc39aaf` | install only — needs verify |
| §A1 Auto-enable mainRow.prompts on first non-empty catalog | ✅ | `bc39aaf` | install only — needs verify |
| §A4 Searchable PromptsQuickPickerSheet | ✅ | `bc39aaf` | install only — needs verify |

---

## Session log — 2026-05-05 (continuation)

13 commits on `eb-branch` after `bc39aaf`. Mac CFBundleShortVersionString stepped 1.3.3 → 1.4.0 → 1.4.1 → 1.4.2 → 1.5.0 → 1.5.1.

| Section | Status | Commit | Hardware-tested |
|---------|--------|--------|-----------------|
| §B13 iOS PTT remote silent-bail when engine not armed | ✅ | `dc5e322` | yes (iPhone — captions + audio_chunks confirmed in Mac kokoro.log) |
| §22 Visible Mac-side perms surface (menubar warning + wake re-probe) | ✅ | `40af168` | install only (warning glyph triggers when a TCC grant is revoked) |
| §25 iTerm2 verb smoke tests (11 read-only verbs) | ✅ | `e6b3539` | green against current iTerm2 |
| §23 Spawn-race dedupe + vanish toast | ✅ | `2701983` | unit-tested via `SpawnedWindowPicker` (7 tests) |
| §27 Idempotent message IDs + Mac dedupe table v1 | ✅ | `e26a8f6` | 7 dedupe-table unit tests; manual not yet exercised |
| §15 Push notifs — all-windows toggle + batched body | ✅ | `c15d575` | install only — needs hardware verify (push lands w/ 🤖 copy + collapsed batch) |
| §15 follow-up — DevicePushPreferences decode tolerant of missing fields | ✅ | `6cdae55` | 4 regression tests; user confirmed pause-bug behavior on hardware |
| §15 v2 — UNNotificationCategory yes/no/1/2 actions on lock screen + Watch (path A) | ✅ | `26e04a3` | yes (Yes button verified at 19:07:42 + 19:08:56 audit.log press_y) |
| §15 v2 — Notifications settings sectioned + status footer + test-fire button | ✅ | `506c195` | yes (test fire round-trips to APNs; lock-screen banner renders) |
| §15 v2 — test-fire bypass selection gate + per-tap synthetic id | ✅ | `b46b45d` | yes (push.log `test_push fired synthetic id=…` confirms branch hit) |
| §49 follow-up — DiagnosticsBundle redacts IPv4s + hostname before share | ✅ | `2dfccc8` | 11 LogRedactor tests + 2 systemInfoText tests green; Tailscale + LAN + public IPv4 all masked, hostname → 8-char hash |
| §22 follow-up — MacPermissionsStore aggregation tests | ✅ | `2dfccc8` | 8 tests covering nil/all-granted/all-denied/single/pair/replace |
| §27 follow-up — dedupe wiring audit (no new handlers) | 📝 | `8fdbd66` | grep confirms all 7 side-effecting handlers (`send_text`/`quick_action` (covers `test_push`)/`duplicate_window`/`close_window`/`spawn_window`/`paste_prompt`/`attach_iterm_window`) still wrap `messageDedupe.checkAndRecord` post-`b46b45d`; no code change |
| §B14 iOS quick-button row seed on fresh install (built-ins + demo custom) | ✅ | `43dbbc5` | 7 new `QuickSlotStoreSeedTests` green; verified on `simctl erase`'d iPhone 17 — `customButtonsJSON` contains `/help` demo, `quickSlotsJSON` contains 11 slots including a `.custom` slot pointing at the demo def. iOS CFBundleShortVersionString bumped 1.4.0 → 1.5.2 |

**Test still owed by user:**
- §15 hardware verify: phone backgrounded → trigger `waiting_for_input` → push lands with `🤖 AI is waiting`. Trigger 2+ windows → batches to `🤖 N AIs waiting`. Toggle "Notify on All Windows" → non-selected window now pushes.
- §22: revoke Accessibility for Quip in System Settings → menubar icon flips to ⚠️ red triangle within 5s; "Permissions needed" section appears with click-to-open button.
- §15 v2 — "1" or "2" buttons confirmed visually but not yet seen in audit.log; "All Windows" toggle behavior; Watch tap (only iPhone-side `press_y` confirmed).
- Carryovers from 2026-05-04: §53 v1 Watch glance, §50 v1 QR pairing, §57 v2 prompt CRUD, §B3 keyboard pills.

**Resolved today:**
- Watch notifications gave "dismiss only" — picked path A (UNNotificationCategory inline actions). Yes / No / 1 / 2 buttons render on lock screen + Watch via iOS forwarding. Tap on wrist → iOS dispatches `quick_action press_y` / `press_n` or `send_text "1"` / `"2"`. §53 v2 (full Watch slash-button send-back) remains the bigger-lift v2 if interactivity past these four actions is needed.

---

**Maintenance rules:**

- Every item has **Title**, **Status**, **Context**, optionally **spec/plan** links.
- Status values: `Wishlist` (idea), `Planned` (spec + plan exist), `In Progress` (note branch), `Blocked` (depends on item or external decision), `Done` (note commit).
- Lives on `eb-branch`; pullable into `main` when desired.

---

## Active Wishlist

### 0. PTT reliability — C-scope timing fixes

**Status:** ✅ Done on `eb-branch` — 17 commits 2026-04-23 (`1b5cba2` → `4a89731`). Five iterations + three bonus fixes. Tests: 120 passing in `QuipiOSTests` (was 51).

**Spec:** `docs/superpowers/specs/2026-04-23-ptt-reliability-design.md`
**Plan:** `docs/superpowers/plans/2026-04-23-ptt-reliability.md`

---

### 0b. PTT recognizer swap (D-scope) — Mac Whisper local, v1 thinnest slice

**Status:** 🟡 Code landed on `eb-branch` (2026-04-24) — pending user acceptance on hardware.

**Spec:** `docs/superpowers/specs/2026-04-24-ptt-whisper-recognizer-design.md`
**Plan:** `docs/superpowers/plans/2026-04-24-ptt-whisper-recognizer.md`
**Commits (9):** `f1dec29` → `59cc271` → `c88fea4` → `bd34ec5` → `ddf82ca` → `52432db` → `c5da543` → `a216533` → `37619c6`

iPhone streams 100ms PCM frames over Bonjour WS. Mac runs WhisperKit 0.18.0 (`openai_whisper-base`, ~150MB). Auto-fallback to iPhone on-device SFSpeech if WS down or status != `.ready`.

**Pending acceptance tests (block shipped status):**
1. Happy path: WS up, 5-10s dictation with technical vocab — Whisper transcribes cleanly.
2. Fallback at start: kill Mac → PTT works via local SFSpeech.
3. Mid-session drop: PTT, `pkill -9 Quip` → toast within 3s, no ghost recording.
4. First-run model download: fresh install → SFSpeech until download finishes, then Whisper.

---

### 0c. PTT recognizer Settings picker + model-size selector (follow-up to §0b)

**Status:** Wishlist
**Depends on:** §0b acceptance passing

**Scope:**
- Settings UI — recognizer source picker (iPhone on-device / Mac Whisper / Mac Apple Speech).
- Model-size picker for Mac Whisper: tiny (~40MB) / base (~150MB, current) / small (~500MB) / medium (~1.5GB) / large (~3GB).
- Per-source diagnostics panel.
- Vocab editor — live-editable companion to bundled `dictation-vocab.txt`. Whisper `promptTokens`.

---

### 1. `/plan` shortcut button on iPhone

**Status:** ✅ Done (upstream) — `68fdb04`, `87f6e16`, `aa3ab2e`, `5fd0bf6` on `main`.

---

### 2. Add / close terminal tabs from iPhone

**Status:** ✅ Done — open via `SpawnWindowMessage` (§29 commits `5b35c71`+`24fee2d`+`2320170`); close via `CloseWindowMessage` (commits `44033ee`→`75c2b95`).

---

### 3. Landscape layout for `/plan` shortcut button

**Status:** ✅ Done — `/plan` already in landscape `TerminalContentOverlay` (upstream `5fd0bf6`); `/btw` added in `c3d8b78`.

---

### 4. Cross-platform parity for `/plan` button

**Status:** Wishlist
**Depends on:** #1
**Context:** QuipLinux and QuipAndroid lack the `/plan` button. Mirror to other clients — at least two follow-up commits (one per client).

---

### 5. `/plan` button v2 — optional auto-dictation

**Status:** Wishlist
**Depends on:** #1
**Context:** Original `/plan` ask included auto-starting voice dictation after button tap. Scrapped for v1; may revisit. Edge cases: cancel mid-way → does `/plan ` stay typed but uncommitted?

---

### 6. Real Claude Code plan mode via Shift+Tab cycling

**Status:** ✅ Done on `eb-branch` (2026-04-20). New `shift+tab` keystroke + `set_plan_mode` / `set_auto_accept_mode` / `set_normal_mode` quick actions reading `claudeModeDetector.windowModes[windowId]` for cycle math. iOS `planMode` + `shiftTab` QuickButton cases. 116 Mac tests pass.

---

### 7. Read Claude Code mode from terminal content stream

**Status:** ✅ Done on `eb-branch` (2026-04-20). New `ClaudeModeDetector` polls each tracked window every 2s for `plan mode on` / `auto-accept edits on`; exposes via optional `claudeMode: String?` on `WindowState`.

**Unlocks:** #6, #18, mode indicator on iPhone status area.

---

### 8. Number shortcut buttons (1 / 2 / 3) for multiple-choice answers

**Status:** ✅ Done (upstream) — shipped by jboert in `4e774e6` as part of settings drawer + configurable quick-buttons.

---

### 9. Window list organized/filtered by application, iTerm2 at top

**Status:** ✅ Partially done (upstream) — `23f1032`. Terminal windows herded to top; folder name in bold colored text.
**Still wishlist:** Explicit grouping by app (section headers on phone), per-app filtering.
**Related:** #16 (alternative arrangements).

---

### 10. Persist last session — remember which windows were open

**Status:** ✅ Done (upstream) — jboert's `9f1b531` ("Fix push-to-talk not submitting, and persist enabled windows across Mac restarts").

---

### 11. Window ID stability across QuipMac restarts

**Status:** ✅ Partially done — `30be68c` on `eb-branch`. iPhone auto-selects first window when its `selectedWindowId` is no longer in the list. Full stable-UUID-based identity still wishlist.
**Related:** #10, #20.

---

### 12. Silent failure diagnostics

**Status:** ✅ Done — `30be68c` on `eb-branch`. Added `ErrorMessage` to protocol; all 4 Mac handlers that drop messages broadcast back. Phone shows red capsule toast (3s auto-dismiss).

---

### 13. Multi-iTerm2-window keystroke targeting

**Status:** ✅ Done — `2ec1ed0` on `eb-branch`. iTerm2 session `unique id` (UUID) cached on `ManagedWindow.iterm2SessionId`; all three injection functions select by `unique id of s` with fallback to `current session of front window`. 40 Mac + 51 iOS tests pass.

**Spec:** `docs/superpowers/specs/2026-04-15-iterm2-session-id-targeting-design.md`

---

### 14. Gitignore generated Info.plist files

**Status:** ✅ Done — `6ca6f60` on `eb-branch`. Both `QuipMac/Info.plist` and `QuipiOS/Info.plist` now `.gitignore`'d; README note explains rule + asymmetry with `.xcodeproj`.

**Spec:** `docs/superpowers/specs/2026-04-15-gitignore-generated-info-plist-design.md`

---

### 15. Push notifications when Claude asks for input

**Status:** ✅ Done v1+v2 on `eb-branch` 2026-05-05. v1 (`c15d575`) added `notifyAllWindows: Bool` toggle, batched body (`🤖 AI is waiting` / `🤖 N AIs waiting`), shared `waiting-batch` collapseId. v1 follow-up (`6cdae55`) made `DevicePushPreferences` decode tolerant of missing fields. v2 (`26e04a3`) added UNNotificationCategory inline actions (Yes/No/1/2) on lock screen + Watch via iOS forwarding. Settings UX restructured into 5 sections + status footer + test-fire button (`506c195`); test-fire bypasses selection gate via per-tap synthetic id (`b46b45d`).

Mac CFBundleShortVersionString: 1.4.0 → 1.4.1 → 1.4.2 → 1.5.0 → 1.5.1.

---

### 16. Alternative window list arrangements (grid / compact / carousel)

**Status:** ✅ Done v1 — grid mode shipped 2026-05-06 (`93b5f23`). Arrange-button cycle: horizontal → vertical → grid → horizontal. Auto-chooser picks grid for 4+ windows. Compact + carousel modes deferred to future iterations; file as new entries if needed.

---

### 17. Keyboard-input `onSubmit` + `pressReturn: true` double-Return bug

**Status:** ✅ Not a bug — investigated 2026-04-15. SwiftUI's `onSubmit` consumes Return before text buffer; `sendTextInput()` trims newlines. Single `pressReturn: true` flag appends exactly one newline.

---

### 18. Context-aware 1/2/3 buttons — auto-appear only when Claude shows numbered prompt

**Status:** ✅ Done 2026-05-06 (commit shipping with this update). Pure detector `NumberedPromptDetector.detect(in:)` in `QuipiOS/Services/NumberedPromptDetector.swift` scans the last 30 lines of `terminalContentText`, looks for contiguous numbered-option lines (`. ` or `) ` separators), requires at least one `❯` (or ASCII `>`) cursor marker in the run to disambiguate real prompts from prose with numbered lists. Strips ANSI color codes before matching. Returns `[Int]?` of contiguous option numbers (typically `[1,2,3]` or `[1,2]`).

UI: when detector returns ≥2 options, a strip of small numbered chips renders inside `InlineTerminalContent` between the header and the URL tray. Tap fires `quick_action("select_<n>")` which the Mac handler maps to `sendText(digit, pressReturn: true)` — same shape as `press_y` / `press_n`. Hidden entirely when no prompt detected (compact-UI discipline preserved).

12 NumberedPromptDetectorTests cover positive paths (3-options, 2-options, marker on second line, ASCII `>` fallback, `)` separator), negative cases (prose without marker, empty, out-of-order numbers, single option, prompt past scan-window cutoff, ANSI sequences stripped before match), and helper coverage (parseNumberedLine pickup).

Deferred to follow-ups: option labels (currently shows "1 / 2 / 3" only, not "Yes / No / Cancel"), letter-marker prompts (a/b/c).

---

### 19. `/btw` shortcut button on iPhone

**Status:** ✅ Done — `c3d8b78` on `eb-branch`. Added `btw` case to `QuickButton` enum.

---

### 20. WebSocket heartbeat / dead-peer detection

**Status:** ✅ Partially done — `30be68c` on `eb-branch`. Client keepalive 30s→10s ping; failed pings trigger immediate reconnect with exponential backoff. Server already had TCP keepalives at 15s/5s/3-probe (~30s). Combined: dead connections surface within ~10-15s. Full bidirectional app-level heartbeat with server-initiated pings still wishlist.

---

### 21. Automated test suite — `MessageProtocol.swift` round-trip tests

**Status:** ✅ Done — 4 commits on `eb-branch` 2026-04-15: `a0f69a9`, `fca32f9`, `9f09851`, `97cff43`. Tests run on both platforms: `QuipiOSTests` (51) + new `QuipMacTests` (40). Shared at `Shared/Tests/MessageProtocolTests.swift`.

**Side-quest:** Two pre-existing latent test-target bugs (`GENERATE_INFOPLIST_FILE: YES` missing; `@testable import QuipiOS` should have been `import Quip` since `PRODUCT_NAME: Quip`). Both fixed in `a0f69a9`.

**Spec:** `docs/superpowers/specs/2026-04-15-protocol-round-trip-tests-design.md`

**Not yet done (follow-ups):** Handler-level tests with fake KeystrokeInjector + WindowManager; iPhone ViewModel tests for `sendAction`; cross-platform JSON key compat checks. File as own wishlist items if priority.

**Related:** #26.

---

### 22. Startup self-test for required macOS permissions

**Status:** ✅ Done v1 on `eb-branch` 2026-05-05. New `MacPermissionsStore` (@Observable @MainActor) — single source the menubar reads. `MenuBarExtra` icon flips from `waveform.circle.fill` to `exclamationmark.triangle.fill` when any TCC perm denied. New "Permissions needed" section + `NSWorkspace.didWakeNotification` re-probe so sleep/wake doesn't leave warning stale up to 5s.

Local Network deliberately skipped — macOS lacks a clean public probe (no Mac counterpart to iOS `NWParameters.requiresLocalNetworkPermission`). Stance: "if you can read this, Local Network is working."

Follow-up (`2dfccc8`): 8 unit tests on aggregation logic.

**Related:** #12, #20.

---

### 23. Race conditions in just-shipped duplicate/close feature

**Status:** ✅ Audited + fixed v1 on `eb-branch` 2026-05-05. **Race A** (3 rapid duplicates picking same window): fixed via pure `SpawnedWindowPicker.pick(...)` + `claimedSpawnedIds` accumulator. 7 unit tests including 3-rapid-spawn case. **Race C** (keystroke target vanished mid-async): added `ErrorMessage("Window closed mid-action")` broadcasts in `ensureITermSessionResolved`'s two silent-return paths. **Race B** (spawn-then-close-original): confirmed benign by code review.

---

### 24. Crash recovery for QuipMac via launchd LaunchAgent

**Status:** ✅ Done 2026-05-06 (commit shipping with this update). New `CrashRecoveryAgent` enum in `QuipMac/Services/` writes `~/Library/LaunchAgents/com.quip.QuipMac.crash-recovery.plist` and bootstraps via `launchctl bootstrap gui/$UID`. KeepAlive gated on `Crashed: true` + `SuccessfulExit: false` so Cmd+Q never triggers relaunch. ThrottleInterval=30 prevents tight crash loops. RunAtLoad=true also covers Mac-just-rebooted. ProcessType=Interactive lets the relaunched app draw windows + take focus.

Settings UI: new "Reliability" section in GeneralTab between Startup and Phone Display. Toggle wired to `crashRecoveryEnabled` AppStorage; flip → install/uninstall via custom Binding. Errors surface inline in red below the caption (revert toggle visually if launchctl refuses).

10 CrashRecoveryAgentTests cover: label stability, plist-URL location in user LaunchAgents, label/ProgramArguments/RunAtLoad/KeepAlive/ThrottleInterval/ProcessType plist content, XML round-trip, and unusual paths (spaces + version digits round-trip verbatim).

**Hardware verification needed:** rebuild Mac + reinstall + toggle on → verify plist exists at `~/Library/LaunchAgents/com.quip.QuipMac.crash-recovery.plist`; force-crash via `kill -SEGV $(pgrep -f Quip.app)` → verify launchd relaunches within ~30s; toggle off → plist removed; Cmd+Q → no relaunch. Path captured at toggle-time = `Bundle.main.executablePath`, so users running from DerivedData and toggling on get a stale plist on next rebuild — opt-in footgun, acceptable for v1.

**Related:** #20.

---

### 25. iTerm2-version smoke test against AppleScript verbs

**Status:** ✅ Done v1 on `eb-branch` 2026-05-05. New `QuipMacTests/ITermVerbSmokeTests` exercises 11 read-only verbs against live iTerm2, asserts return TYPE on each. Auto-skips when iTerm2 isn't running.

Discovery: iTerm2 returns `miniaturized` Booleans as `typeTrue`/`typeFalse` rather than `typeBoolean`; assertion accepts all three.

**Related:** #13.

---

### 26. Diagnostic-capture ("share state") gesture on iPhone

**Status:** ✅ Done 2026-05-06 (commit shipping with this update). Shake the phone → DiagnosticsSheet presents with a frozen iPhone-side snapshot: app version + build, connection flags (connected/connecting/authenticated), serverURL, lastError, paired count, active backend name, last 30 lifecycle events from `WebSocketClient.recentConnectionEvents`. Sheet has a Copy button (writes the full snapshot to UIPasteboard) and a Request Mac bundle button (fires existing `RequestDiagnosticsMessage`; gated on `client.isAuthenticated` so dropped requests don't silently fail).

Pure formatter `DiagnosticsSnapshotFormatter.format(_:now:)` with stable line order — users grep for tokens like `connected: true` / `lastError: <none>`, so additions APPEND new sections rather than reshuffle. Shake detection via `ShakeDetector` (UIViewControllerRepresentable that becomes first responder + handles `motionEnded`) mounted as a 0×0 background view on MainiOSView, in the responder chain without taking layout space.

8 DiagnosticsSnapshotFormatterTests cover: app-version line, all connection flags, lastError nil-sentinel + verbatim, paired count + active name, empty-events sentinel, events rendered in order, ISO8601 timestamp in header.

Deferred to follow-ups: device shake-to-share UI tweak (haptic on detection), include `lastConnectedAt` per-backend in the snapshot block (now that §J ships), inverse-direction (Mac shake → request iOS bundle).

---


### 27. Idempotent message IDs + Mac-side dedupe table

**Status:** ✅ Done v1 on `eb-branch` 2026-05-05 — `e26a8f6`. Lighter "ID + dedupe, no ack" path. `messageId: UUID?` on 7 side-effecting iPhone-originated messages. `MessageDedupeTable` (cap 100, TTL 30s, NSLock-guarded ring + dict index, pluggable clock). Mac handlers wrap each in `if messageDedupe.checkAndRecord(msg.messageId) { break }`. 7 unit tests including 8-thread concurrent insert.

**Deliberately NOT covered v1:** `image_upload` (already file-path idempotent), `put_prompt` / `delete_prompt` (FS-idempotent), `arrange_windows` (geometric), `audio_chunk` (per-frame stream — dedupe would BREAK upload), strict ack-required version (parked for retry-on-reconnect).

Mac CFBundleShortVersionString 1.3.3 → 1.4.0.

Follow-up audit (`8fdbd66`): all 7 wraps still cover post-`b46b45d`; no new side-effecting handlers added.

---

### 28. Larger / higher-contrast option for shortcut row buttons (esp. night mode)

**Status:** ✅ Partially done — contrast fix shipped on `eb-branch` 2026-04-15. Bumped shortcut row font 9pt→11pt (icons 11→13pt), weight `.medium`→`.semibold`, opacities up, padding 7×5→9×7. Settings-based size picker (Small/Medium/Large) still wishlist.

**Two distinct accessibility needs:** size (tap accuracy — fat fingers, gloves, one-handed) vs contrast (visibility — low light, aging eyes, sunglasses). Should ship as separate options. Open: scope (just 1/2/3 row, full shortcut row, or every iPhone button), Settings placement (row vs new Accessibility tab), Dynamic Type interop.

**Related:** #8, #18.

---

### 29. Launch iTerm2 window from iPhone — project directory picker

**Status:** ✅ Done — 3 commits on `eb-branch` 2026-04-15: `5b35c71`, `24fee2d`, `2320170`. Implemented as project-directory picker (simpler than original iTerm2-profile approach). Mac broadcasts subdirectories of configured project roots via `ProjectDirectoriesMessage`. iPhone "+" button (40pt, between chevrons and PTT) opens sheet. Tap → `SpawnWindowMessage` → Mac spawns iTerm in dir with configured spawn command, auto-enables, broadcasts updated layout, auto-selects on phone.

**Related:** #2.

---

### 30. Reliability & UX hardening pass (5-thread backlog)

**Status:** Half-eaten 2026-05-06 (continuation 7). Threads #1, #2, #4 shipped; #3 + #5 still wishlist.

**5 threads:**
1. **Diagnostic tooling / observability** — extend the loud-drop logging pattern. ✅ **Shipped 2026-05-06** (`5b2a6a8`): WatchSyncService + PromptLibrary + CloudflareTunnel + PushNotificationService + MessageDedupeTable now log enough context to spot the cause.
2. **Connection truth / status pill honesty** — surface *why* a disconnect happened. ✅ **Shipped 2026-05-06** (`9f382ef`): `DisconnectReason` enum (userInitiated / timedOut / stalled / authFailed / networkError / serverClosed / unknown). `lastDisconnectReason` set BEFORE clearing isConnected. `TopBarStatus.classify(reason:)` overload prefers structured signal over keyword-matching `lastError`. DiagnosticsSheet renders the typed tag.
3. **State invariants across app lifecycle** — audit `willResignActive` / `didEnterBackground` / `willEnterForeground` / `didBecomeActive` on iOS + Mac equivalents. Known offenders: `isPTTActive`, Live Activity handles, `PreferencesSyncService.suppressUntil`, force-quit-after-install. **Untouched.**
4. **Error-handling gaps** — `try?`, silent `if let { } else { return }`, empty `catch {}`, swallowing `guard`. ✅ **Shipped 2026-05-06** (`cc3bddc` + `6aca7d8`):
   - `WebSocketClient.decodeMessage` helper replaces 22 silent `try? decoder.decode(...)` sites in `handleMessage`. Failures now log `[WebSocketClient] decode FAILED type=<wire-tag> kind=<Swift.Type> bytes=<N> err=<...>`. Helper is `nonisolated static` + log-injected; 6 new tests assert the exact format.
   - Encode side: Mac `WebSocketServer.broadcast<T>` + Mac `WebSocketServer.send<T>` + iOS `WebSocketClient.send<T>` log `kind=<Swift.Type>` so a per-type encode regression is identifiable without backpressure-log spelunking.
   - **Remaining audit hits not yet converted:** `PinManifest` decode from disk in `WebSocketClient` (config layer, different blast radius). Most other `try?` in the repo are FileManager / Task.sleep / defer-close — legit silent. If a new swallow site shows up in production, mirror the helper pattern.
5. **Notification triage in-app** — surface recent push attempts + skip reasons in Mac Settings → Notifications (instead of `tail push.log`). **Untouched.**

**Tests added:** `DecodeMessageHelperTests` (6) — success path, malformed JSON, missing-key drift, type mismatch, empty payload, opaque-tag passthrough.

**When picking up:** §30 is now a meta tracker. If reliability work resumes, threads #3 (lifecycle) and #5 (in-app triage view) are the remaining open bets.

**Related:** `8517835` (push-service loud-drop seed), `843fb68` (volume KVO guard), `3431046` (keepalive-pong fix), `5b2a6a8` (#1 ship), `9f382ef` (#2 ship), `cc3bddc` + `6aca7d8` (#4 ship).

---

### 33. Mac perms feature — verify all sub-flows in production

**Status:** Partially verified (autonomous). Manual checklist below pending user.

**Pending user (state-change sub-flows + visual confirmation):**
- Revoke a perm in System Settings → phone strip flips red within 5s, gear-icon red dot, Dynamic Island shows triangle + count.
- Tap red row in iOS SettingsSheet → matching System Settings pane opens (test all three: Accessibility, Automation, Screen Recording).
- Tap Dynamic Island banner from Quip-backgrounded state → Quip launches via `quip://perms` deep link.
- Mac UI Settings → General → Permissions: Grant on a denied row → matching pane opens; flip green within 3s.
- Live Activities toggle in Quip iOS Settings: OFF kills any active perms LA + suppresses new ones; ON spawns one if degraded.

**Related:** commits `0f3a0be`, `90e8e1a`, `59cfb3a`. PR https://github.com/jboert/Quip/pull/6.

---

### 34. iPhone Quip never receives `mac_permissions` despite Mac broadcasting it

**Status:** ✅ Mitigated (root not nailed). 5s periodic re-broadcast (`QuipMacApp.swift:permsTimer`) catches missed auth-time messages. §22 (2026-05-05) added Mac-side menubar surface so perms state isn't dependent on phone receiving broadcast.

**Suspected root causes (not narrowed):** backpressure check in `WebSocketServer.broadcast(_:)` dropping for iPhone client only; NWConnection frame fragmentation differing LAN vs localhost; iOS WS task queue dropping messages received during specific moment of auth flow.

---

### 35. Cross-app paste from iPhone clipboard into Quip terminal

**Status:** ✅ Done 2026-05-06 (commit shipping with this update). Long-press the keyboard main-row button reads `UIPasteboard.general.string` and ships it to the selected window via `SendTextMessage(pressReturn: false)`. Single-tap behavior unchanged (toggle text input panel). 32 KiB ceiling via pure helper `MainiOSView.clipText(_:maxBytes:)` that trims by character (not byte) so multi-byte glyphs never split into invalid UTF-8. Haptic feedback on success/warning. Accessibility hint on the keyboard button documents the gesture for VoiceOver users. 6 ClipTextTests cover empty / at-limit / over-limit / multi-byte glyph / sub-glyph cap.

Deferred to follow-ups: dedicated paste button (vs long-press gesture), paste-with-return variant, line-by-line chunking for huge multi-line payloads, inverse direction (terminal selection → iPhone clipboard). The long-press shape ships a usable v1 without growing the main row.

---

### 38. iTerm scrollback navigation from the iPhone

**Status:** ✅ Done 2026-05-06 (commit shipping with this update). MVP shipped via two new buttons in the InlineTerminalContent panel header (chevron-up / chevron-down). Tap = scroll one page; long-press = scroll to top/bottom. Routes through existing `quick_action` channel with new action strings `scroll_page_up` / `scroll_page_down` / `scroll_top` / `scroll_bottom`. Mac handler restricted to iTerm2 (broadcasts ErrorMessage for Terminal.app / Claude Desktop). New `KeystrokeInjector.ScrollDirection` enum + `iterm2Scroll(_:to:iterm2SessionId:)` method walk window→tab→session in AppleScript and send the corresponding modifier+key via System Events: Shift+PageUp/Down for one-page, Cmd+Home/End for top/bottom — these are iTerm2's default scrollback shortcuts (bare keys go to the running program). State stays Mac-side; the existing screenshot capture loop reflects scrolled viewport on the next snapshot. 5 Iterm2ScrollKeystrokeTests lock the keycode + modifier mapping so a future refactor can't silently flip a direction or drop a modifier.

Deferred to follow-ups: pan-gesture (vs button) trigger, "scrolled up by N lines" indicator, snap-to-bottom button, no-more-scrollback edge feedback. The button shape ships a usable v1.
**Related:** `QuipiOS/QuipApp.swift:~2892` (image branch). Reopened from https://github.com/jboert/Quip/issues/7.

---

### 39. Auto-arrange phone windows on open + manual realign button

**Status:** ✅ Done (`runAutoChooser` + `chooseAutoLayout` + Realign-on-long-press of arrange button). 2026-05-06 v2 (`93b5f23`): chooser now picks `"grid"` for 4+ windows, full mode cycle is horizontal → vertical → grid → horizontal. Tests cover all chooser cases at counts 1-10.

---

### 40. Drag-to-move windows on the iPhone layout

**Status:** ✅ Done (FR-13 to FR-16 — drag-gesture in `WindowRectangle`, `phoneFrameOverrides` @AppStorage persistence, swap-on-overlap, snap-to-grid via `nearestGridIndex` + `gridFrame`). 2026-05-06: grid-mode `nearestGridIndex` test coverage added (`93b5f23`/`288b812` series). Resize-with-drag, cross-display moves, and free-drag (no snap) deferred — file as new wishlist items if needed.

---

### 41. Volume-button KVO must not clobber other-app audio

**Status:** ✅ Done on `eb-branch` — `1f5254c` (2026-04-26). `HardwareButtonHandler.startMonitoring` and `resumeAfterBackground` now call `primeRailIfNeeded(session:)`. Reads `session.outputVolume`; if it's already in (0.0625, 0.9375), saves user's actual level and leaves system volume alone. Only at rails does Quip nudge.

---

### 42. Hardening audit 2026-04-26 — backlog (🟡 GitHub-tracked)

**Status:** Filed as GitHub issues `jboert/Quip#10`–`#26` under label `audit-2026-04`. Tracker: [#26](https://github.com/jboert/Quip/issues/26).

**Grades:** iOS security C+, iOS code quality A−, Mac security C, Mac robustness B+, build/signing B−, protocol design B+, repo hygiene B+, tests B−, docs B. **Overall B−.**

**Critical (transport + sandboxing):**
- §A `#10` — Re-enable TLS pinning in `WebSocketClient.swift:312-314`. Verify Cloudflare SPKI hashes first.
- §B `#11` — Replace `NSAllowsArbitraryLoads: true` with `NSExceptionDomains` allow-list.
- §C `#12` — Enable `com.apple.security.app-sandbox`. Triggers TCC re-prompts.
- §D `#13` — `ENABLE_HARDENED_RUNTIME: true` + `DEVELOPMENT_TEAM: D2PM6R797Q`. Required for notarization.

**High:** `#14` Mac PIN → Keychain + 8+ alphanum. `#15` audit `CloudflareTunnel` Process spawn for `sh -c` injection. `#16` remove 37MB `cloudflared` binary from git, fetch+verify in build script. `#17` per-message HMAC-SHA256 over WS (HKDF from PIN + nonces).

**Medium:** `#18` Idempotency keys on `SendTextMessage` + `ImageUploadMessage` (✅ partially superseded by §27). `#19` Mac→iOS app-level heartbeat (5s). `#20` tighten message types (enum for `arrange_windows.layout`). `#21` lock `requireAuth` (`nonisolated(unsafe)`). `#22` APNs keyId/teamId/bundleId → Keychain. `#23` CI: `xcodebuild test` for QuipiOS+QuipMac, `cargo test` for QuipLinux. `#24` test gaps (auth handshake, dispatch, Bonjour).

**Low:** `#25` expand `docs/protocol.md`.

**Already shipped from this audit (`b6a8498`):** PIN values redacted from `/tmp` debug log; empty audio-session catches now `NSLog`; `.gitignore` `*.profraw` / `*.profdata`.

**Order of attack:** `#16`+`#23` (pure ops) → `#15` (cheap) → `#14`+`#22` (Keychain) → `#13` (team+hardened runtime) → `#10`+`#11` (transport) → `#12` (sandbox last). Protocol items (`#17`+`#19`+`#20`) bump version once, ship together.

---

### 43. Custom quick-buttons editor + reorderable slot row

**Status:** ✅ Done on `eb-branch` — 3 commits: `2ef5f6b` (UI tightening), `498a29d` (remove dedicated `/plan` quick button), `9283a69` (custom buttons + slot editor, v1.4.0). Quick-button row is now flat user-controlled ordered list, Apple-toolbar-style. `Settings → Quick Buttons` editor: drag handle to reorder, swipe to delete, "+" toolbar menu adds Built-in / Custom / Spacer. Persisted via `quickSlotsJSON` + `customButtonsJSON` (@AppStorage); legacy `enabledQuickButtons` CSV kept in sync for downgrade safety. `PreferencesSnapshot` extended for reinstall survival.

`QuickSlot` and `CustomPayload` use hand-rolled `Codable` (Swift's automatic synthesis fails under `SWIFT_STRICT_CONCURRENCY=minimal`). Cascade-delete prunes slot references on definition removal.

---

### 44. iOS WS resilience — NWPathMonitor + stall watchdog + Reset button

**Status:** ✅ Done on `eb-branch` — `64a8376`. Confirmed working 2026-05-03.

`NWPathMonitor` auto-reconnect on path-satisfied; stall watchdog fires every 5s, resets if `isConnecting` >25s; one-tap Reset button when `!isConnected && serverURL != nil`; diagnostic ring buffer (last 30 events) → §46 panel; keepalive miss surfaces "No pong (1/2)" / "(2/2)" to UI; `teardownDiagnostics()` cleans NWPathMonitor + watchdog on `forget()`.

**Detection times before → after:** Network blip ~immediate (NWPath kick); zombie URLSession forever → ≤30s; keepalive drop unchanged but now visible.

---

### 45. Mac CloudflareTunnel: NWPathMonitor + stall watchdog parity

**Status:** ✅ Done on `eb-branch` — `352be75`. Mirrors §44 on Mac side. NWPathMonitor restart on path-satisfied + URL-still-empty; 5s stall watchdog (>30s threshold); `connectionEvents` ring (feeds §48); `restartTunnel()` unifies recovery paths.

---

### 46. iOS Connection diagnostics panel

**Status:** ✅ Done on `eb-branch` — `6668893`. New `Section { Diagnostics }` in `SettingsSheet` → `ConnectionDiagnosticsSheet`. Two sections: Current state (Connected, Authenticated, Server, Last error) + Recent events (last 30 timestamped lines, monospaced, newest first, text-selectable, Copy button).

---

### 47. iOS image upload: HEIC encode for size

**Status:** ✅ Done on `eb-branch` — `684956b`. Pivoted from WebP (iOS 18-only encode) to HEIC (iOS 11+, what iPhone camera roll already uses). `UIImage+HEIC.heicData(quality:)` via `ImageIO + CGImageDestination + UTType.heic`. `sendPendingImageIfNeeded` tries HEIC first, falls back to PNG or JPEG-0.95.

Cuts typical photo payload 50-70% vs PNG.

---

### 48. Mac menubar: last-event indicator + tunnel state

**Status:** ✅ Done on `eb-branch` — `45346ed`. `MenuBarView` gains three-color status dot (green/yellow/red), tunnel row (green when URL resolved, yellow when resolving), last-event row (icon + relative time). `ConnectionLog` and `CloudflareTunnel` injected into MenuBarExtra environment.

---

### 49. Bundle-and-share diagnostics from Mac + iOS request path

**Status:** ✅ Done on `eb-branch` — `d0a69bc`. Mac Settings → Diagnostics tab: "Reveal in Finder" + "Bundle and share…" zips logs + system-info to `/tmp` via `/usr/bin/zip`, opens `NSSharingServicePicker`. iOS Settings → Diagnostics → Connection diagnostics → "Get Mac logs": new `RequestDiagnosticsMessage` round-trips a base64-encoded zip back as `DiagnosticsBundleMessage` (4 MiB cap). iOS surfaces `UIActivityViewController` to AirDrop to Mac.

`DiagnosticsBundle.makeZip(maxBytes:)` writes `Quip-diagnostics-YYYYMMDD-HHMMSS.zip` to `NSTemporaryDirectory`; tolerates missing log files; throws `.overSizeCap` on budget exceed.

Follow-up (`2dfccc8`): `LogRedactor` masks IPv4s (LAN/Tailscale/public — last two octets) + replaces hostname; `systemInfoText` ships salted SHA256 hash of host name instead of raw name.

---

### Boundary marker — autonomous loop halts here, awaiting user input

Tickets §50–§56 (QR pairing, iCloud KVS sync, ~~iPad layout~~ tabled, Apple Watch glance, wake-word PTT, ~~clipboard sync~~ tabled, voice macros) need user decisions, multi-device hardware testing, or new Xcode targets.

---

### 50. QR pairing — Mac shows QR, iPhone scans

**Status:** ✅ Done v1 on `eb-branch` — `a52ad4f`. Payload format: `quip://pair?url=<base64>&pin=<6digits>` (re-uses registered `quip` URL scheme). Mac Settings → Security shows 160×160 QR (CIQRCodeGenerator, errorCorrection=M) + URL + PIN for fallback typing. iPhone QR scanner callback tries `PairingPayload.decode(code)` first, falls back to legacy raw URL.

**Deferred to v2:** TTL / payload-aging; mid-pairing UX (spinner/haptic); universal-link entry from Mail/Messages.

---

### 51. iCloud KVS sync of paired backends

**Status:** Backlog — needs second device to test.

---

### 53. Apple Watch glance — per-window state + haptics

**Status:** ✅ Done v1 on `eb-branch` — `a2c977b`. New `QuipWatch` target (single watchOS app, embedded). `WatchSyncService` (WCSessionDelegate) pushes active Mac's window snapshot to wrist — live channel via `sendMessage` when reachable, falls back to `updateApplicationContext`. ContentView shows scroll list of windows: state dot (yellow=awaiting / blue=thinking / green=idle), name, claudeMode badge. Haptic on `waiting_for_input` transitions.

**Sendable quirk:** WCSessionDelegate callbacks are nonisolated; `[String: Any]` payload isn't Sendable under Swift 6 strict concurrency. Extract Data for "windows" key in nonisolated callback (Data IS Sendable), then hop to MainActor.

**xcodegen quirks:** iOS app's `path: .` source spec must `exclude: ["QuipWatch/**"]` (avoids "Multiple commands produce Quip.app/Info.plist"). Watch app `PRODUCT_NAME` must be `QuipWatch` (avoids bundle-name collision).

**Deferred to v2:** Complication via WidgetKit; slash-button send-back ("/yes" / "/no" from wrist via WCSession reverse channel) — partially obsoleted by §15 v2 Path A inline actions; per-window vs all-windows toggle.

---

### 54. Wake-word PTT — "Hey Claude" → start dictation

**Status:** 📋 Backlog. Big technical decision (which keyword-spotting stack) + hardware-test loop required.

**Stack options:**

| Option | Pros | Cons |
|--------|------|------|
| Apple `SFSpeechRecognizer` + keyword filter | Free, on-device | Not always-on; battery; false-trigger rate |
| Picovoice Porcupine | Designed for wake-word, ~1% CPU | Free tier non-commercial; paid SDK $$$ |
| `SFSpeechRecognizer` `requiresOnDeviceRecognition=true` + custom rolling buffer | On-device, free, fits `SpeechService` | Same battery; recognizer drops partials on pause (`project_sfspeech_ondevice_rollover.md`) |
| Custom Whisper-tiny streaming | Full control | Big — weeks |

**Open:** battery (always-listening 2-5%/hr; opt-in toggle? Auto-disable <20%); privacy (always-listening copy on first enable; mic indicator stays on); wake-word config (hardcoded "Hey Claude" or user-pickable); Siri conflict.

**Memory caveat:** SFSpeech on-device drops partials on pause. Lose words spoken in brief moment between wake-word detection and PTT-stream-start. Need pre-roll buffer — extend `354e2aa` ("Long-lived audio engine with 500ms pre-roll replay") rather than add new one.

---

### 56. Voice macros — "ship it" → multi-step

**Status:** Wishlist — open UX shape decision.

---

### 57. Prompt library — Mac watches a directory, iPhone pastes

**Status:** ✅ Done v1+v2 on `eb-branch` — v1 `ad4fb57`, v2 `fcd2ba1`. 15 of 25 streamdeck-claude-scripts auto-imported.

**v1:** `PromptLibrary` (DispatchSource FS observer over `~/Library/Application Support/Quip/prompts/*.txt`). `PromptLibraryMessage` (Mac→iPhone catalog) + `PastePromptMessage` (iPhone→Mac id+windowId+pressReturn). iOS `PromptLibrarySheet` under Settings → Prompts. `import-streamdeck-prompts.sh` extracts `set the clipboard to "..."` body via `osadecompile` + python regex.

**v2:** `PromptEntry` carries full `body` inline (was preview only). New `PutPromptMessage` (id, label, body) + `DeletePromptMessage` (id). iOS `PromptEditorSheet` (id locked when editing, label, multi-line `TextEditor` monospaced, byte counter). Swipe Edit/Delete + "+" toolbar. `PromptLibrary.sanitizeID` strips path separators / leading dots / shell metacharacters.

**Deferred to later v:** chains (multi-step prompts), search/filter when catalog grows past one screen.

---

## Completed

### 31. iOS terminal URLs aren't tappable

**Status:** ✅ Done. Root cause: `.foregroundStyle(.white.opacity(0.85))` on SwiftUI `Text` overrode per-run colors set by `.link` AttributedString runs AND interfered with link-tap recognition. Fix: bake foreground color into `AttributedString` itself in `linkifiedTerminalContent`; set link runs to `.cyan`; drop `.foregroundStyle` modifier.

**Related:** `d3bf4c9` (initial linkifier), `b5bb8d7` (scheme filter + tests), `03ebfc9` (gesture-routing fix).

---

### 32. `mailto:` link support in terminal content

**Status:** ✅ Done. Extended `linkifiedTerminalContent` scheme filter to accept `mailto:` substring + URLs whose `scheme` is "mailto". NSDataDetector returns bare emails as `mailto:` URLs natively. Two unit tests added.

---

### 36. Allow more vertical scrolling in iPhone `InlineTerminalContent` (issue #7)

**Status:** ⏪ Reverted. Shipped `c5416e2` as "zoom screenshot + pan around it"; reverted in `cfcfb6c` after device testing — user's actual ask is iTerm scrollback navigation (tracked as §38), not panning around current screenshot.

**Lessons:** `ContentZoomLevel.widthFraction` is dead code (verify before re-using). Raw `@AppStorage` ordinals 0/1/2 persist; case renames free, semantics changes are NOT. `GeometryReader { ScrollView { ... } }` works; reverse does not.

---

### 37. PTT in-press pause wipes prior transcription

**Status:** ✅ Done — verified on device with 3-utterance trace. Root cause: SFSpeechRecognizer on-device silently rolls over partial results mid-task when speaker pauses — no `isFinal` fires, `bestTranscription.formattedString` just restarts. `AudioWorker` committed to `accumulatedText` only on `isFinal`, so seam-stitching replaced pre-pause words with post-pause ones.

**Fix:** added `RecognizerRollover.detects(previous:current:)` + per-task `lastPartialText` high-water mark. When partial is shorter AND first token (case-insensitive) doesn't match previous high-water mark's first token, commit `lastPartialText` into `accumulatedText` before stitching.

**Diagnostic trail worth keeping:** `NSLog %{public}@` lands as `<private>` on iOS 17/18 unified-logging redaction; `os.Logger` with `privacy: .public` doesn't reach `devicectl --console` (only captures stdout). Only `print()` survived. Kept integer-only NSLogs for non-string fields.

**Related:** commit `eacca48`. Tests: `RecognizerRolloverTests` (8 cases).

---

### B1. iOS Custom Buttons editor — scrolling buggy

**Status:** ✅ Fixed 2026-05-04. Root cause: `Button { … } .buttonStyle(.plain)` rows inside `Custom Buttons` `List` section ate scroll gestures (well-known SwiftUI conflict). Replaced with `HStack { … }.contentShape(Rectangle()).onTapGesture`. `.onDelete` swipes also recover.

---

### B3. Prompts as keyboard quick-buttons

**Status:** ✅ Done v1 on `eb-branch` — `2ec3ed9`. New `QuickSlot.prompt(promptID:)` case + Codable wire format with `prompt` kind discriminator. Editor "+" menu gains "Prompt from library…" picker (visible only when catalog non-empty). Keyboard runtime: `promptQuickButton` view, tap = paste no submit, long-press = paste-and-submit. Reuses §57's `PastePromptMessage` handler — no new protocol bits.

---

### B4. Prompts pasting into wrong window

**Status:** ✅ Fixed 2026-05-04. Root cause: phone-side stale-capture — Settings → Prompts NavigationLink passed `windowId: selectedWindowId` to `PromptLibrarySheet` as a stored `String?` captured at NavigationLink construction. Once Settings was open, sheet kept firing pastes at whatever window was active when the user opened Settings.

**Fix:** converted both `SettingsSheet.selectedWindowId` and `PromptLibrarySheet.windowId` to closure resolvers (`windowIdProvider: () -> String?`). Same pattern as §B11 SpeechService weak-ref → resolver migration.

---

### B5. Per-client connection visibility on Mac + iOS

**Status:** ✅ Done v1 2026-05-04. `WebSocketServer.connectedClients: [ConnectedClientInfo]` published list — id, remote endpoint, connectedAt, lastActivity, isAuthenticated, deviceID/deviceName/deviceKind. MenuBarExtra popover replaces "N clients connected" with one row per client. Settings → Connection has new "Connected Clients" section.

iPhone: `WebSocketClient.sendSelfIdentity()` fires `DeviceIdentityMessage` after `auth_result success`. Connection Diagnostics gains "Transport" row (Cloudflare tunnel / LAN Bonjour / Tailscale CGNAT / LAN RFC1918 / Loopback).

**Deferred to v2:** Manual disconnect from Mac; show currently-active backend's deviceID in iOS Backend picker; tunnel-broadcaster clients in same list.

---

### B6. Quick Buttons "+" menu observation-chain leak

**Status:** ✅ Fixed 2026-05-04. Root cause: `addMenu` body still read `client.promptLibrary` directly, so every Mac catalog broadcast re-evaluated entire `QuickButtonsSheet` body during open Menu, dismissing or jumping it mid-tap. Switched menu's gating to `!promptLabelByID.isEmpty`.

---

### B7. Prompts as a main-row button

**Status:** ✅ Done v1 2026-05-04. New `mainRow.prompts` @AppStorage toggle (default OFF). Enabled → `doc.text.magnifyingglass` button renders in RIGHT cluster 1 next to Photo. Tap opens same MRU-sorted `PromptsQuickPickerSheet` as keyboard pill. Sheet hoisted to `MainiOSView.body` for shared presentation.

---

### B8. Live captions regressed on remote Whisper path

**Status:** ✅ Fixed 2026-05-04 — `4751272`. Root cause: remote branch in `SpeechService.startRecording` only set up `worker.startForwarding(onBuffer:)` — raw audio chunks fired to Mac's Whisper, no local recognizer for captions. `transcribedText` populated only on `session.stop` with Mac's final, leaving overlay empty during speaking.

**Fix:** Remote path now runs *display-only* on-device SFSpeech recognizer in parallel with Whisper streaming. Single mic tap fans buffers to two consumers.

---

### B9. PTT silent-fail when no window selected

**Status:** ✅ Fixed 2026-05-04 — `6d47a51`. Root cause: `MainiOSView.startRecording` gates on `selectedWindowId != nil`, silently returns when nil. Both on-screen mic Button and hardware volume-down PTT funnel through same closure. `onLayoutUpdate` only auto-picked first window when previously-selected id was stale; nil-from-cold-launch case never handled.

**Fix:** `onLayoutUpdate` now also auto-picks `windows.first` when `selectedWindowId == nil` and sends `SelectWindowMessage`. `startRecording` warning-haptic + `print()` on bail.

---

### B10. Paired backends — duplicate "Backend" rows

**Status:** ✅ Fixed 2026-05-04 — `93cc9a8`. Two failure modes: (1) `addPaired(url:)` deduped only on primary URL — duplicate appended if same URL was a *fallback* on existing row; (2) `mergeSameIDRows` was gated behind one-shot `pairedMultiURLMigrationV2Done` flag — once migration ran, future stuck duplicates accumulated forever.

**Fix:** `addPaired` matches against full `urlsInOrder` set. `mergeSameIDRows` runs unconditionally on every `loadPaired`.

---

### A1. Auto-enable Prompts main-row button on first non-empty catalog

**Status:** ✅ Done 2026-05-04. New users with no prompts get toggle off. First time Mac broadcasts non-empty `prompt_library`, `.onChange` hook in `MainiOSView` flips `mainRow.prompts = true` AND records `mainRow.prompts.autoEnabledOnce = true` (one-shot flag prevents re-flipping after explicit user-off).

---

### A4. Searchable PromptsQuickPickerSheet

**Status:** ✅ Done 2026-05-04. Stream-Deck users with 30+ prompts couldn't find specific entry past MRU window. Added `.searchable($query, placement: .navigationBarDrawer(displayMode: .always))`. Filter case-insensitive, matches `label` + `bodyPreview` + `id`. Empty result shows `No matches for "…"`.

---

### B15. iPhone accessibility hygiene — traits + image alt labels

**Status:** Partially done — main-row swept in cont-4 (`288b812`); slot-row chips + reset/disconnect/cancel-auth + prompt buttons swept in cont-5 (commit shipping with this update). Wishlist for any remaining elements not yet surfaced by the audit script (sim has to be paired + show slot row to render those elements).
**Surfaced:** 2026-05-05 QA pass via `accessibility_audit.py` on the booted simulator (32 elements, 32 issues — 1 critical, 31 warnings).

**Critical (1):** one image element on the main view has no `accessibilityLabel`. Likely the pending-image preview thumbnail or one of the window-card screenshots embedded in `WindowRectangle`. VoiceOver users hit a dead end when the element is focused.

**Warnings (31):** every interactive icon button is missing explicit `accessibilityTraits(.isButton)`. Most affected: main-row chevrons / spawn / arrange / mic / photo / prompts / keyboard / return + slot-row chip pills + Settings gear. SwiftUI's `Button { ... } label: { Image(systemName: ...) }` infers the trait at runtime in normal use, but VoiceOver / Switch Control occasionally fail to announce them as tappable when the label is icon-only and short.

**Likely shape:**
- Sweep `QuipApp.swift` for `Button { ... } label: { Image(systemName: ...) ... }` patterns, add `.accessibilityLabel("...")` (descriptive verb, e.g. "Cycle to previous window" instead of "chevron.left") + `.accessibilityAddTraits(.isButton)` belt-and-suspenders.
- Find the unlabeled image — most likely `PendingImagePreviewStrip` or the per-window screenshot inside `WindowRectangle`. Add `.accessibilityLabel("Pending image attachment, \(filename)")` / `.accessibilityLabel("Window screenshot: \(window.title)")`.
- Run `accessibility_audit.py --json` again post-fix; target should be ≤2 critical + ≤5 warnings.

**Why low priority:** no functional impact on the typical sighted user. Worth doing as a single sweep PR when next touching `QuipApp.swift` heavily; not a blocker for shipping.

**Tooling:** `python3 ios-simulator-skill/scripts/accessibility_audit.py --udid <booted> --verbose` produces the per-element list. Re-run after each batch to see the count drop.

---

### B16. Phone follows Mac frontmost window (image+text routing)

**Status:** ✅ Done 2026-05-06 (`b6ef907` Mac broadcast + `918cb5c` iOS follow + Auto pill, plus `f471415` companion fix that healed `clientSelectedWindowId` on phone reconnect). Mac broadcasts its current frontmost `ManagedWindow.id` via new `FrontmostChangedMessage` (NSWorkspace activation hook + 400ms AX focused-window poller). iOS auto-retargets `selectedWindowId` when `followFrontmost` pref is on; manual tap on a window card pins. Icon-only Auto pill in window-layout top-right (filled `cursorarrow.rays` when following / outlined `hand.point.up.left` when pinned). Layer 2 (per-window AX raise inside Claude branch) turned out to be unneeded — `WindowManager.focusWindow` already raises the specific window before keystroke fires.

---

### B17. Trace `type=unknown (4 bytes)` mystery frame

**Status:** ✅ Closed 2026-05-07 — self-resolved by `3a3a7c7` once running. Initial reading was wrong: the 4-byte payload IS a ping/pong control frame (the fix shipped 2026-05-06 11:46 in source but the running Mac binary was old; the 17:49–17:54 unknowns on May 6 came from the pre-fix binary). After the May 7 13:29:45 rebuild + ditto of `/Applications/Quip.app`, kokoro.log shows zero `type=unknown` lines despite normal traffic (47+ `type=request_content` etc per session). The §B17 diagnostic at `WebSocketServer.swift:874-888` (commit `462db63`) is standing by to dump bytes if any non-control frame ever fails JSON parse, but the receiveMessage opcode filter eats every 4-byte frame before JSON dispatch.

**Surfaced:** 2026-05-06 — kokoro.log showed `WS received: type=unknown (4 bytes)` at ~10-15s cadence per connected client. Initial hypothesis was that `3a3a7c7`'s `NWProtocolWebSocket.Metadata.opcode != .text` filter wasn't catching them, but it was — just running the old binary at the time.

**Context:** Filter at `QuipMac/Services/WebSocketServer.swift:637-642` drops .ping/.pong/.close cleanly; everything else falls through to `MessageCoder.messageType(from: data)` which returns nil for non-JSON. The log line at `WebSocketServer.swift:661` then prints `"unknown"`. Cosmetic only — the frame is silently ignored downstream because no handler matches a nil messageType. But it pollutes the log and makes real signal harder to spot.

**Hypotheses (rank by likelihood):**
1. **Empty / minimal JSON literal sent somewhere** — `null` (4 bytes), `true` (4 bytes), or `[{}]` (4 bytes) encoded somewhere on iOS or Watch and shipped via `task.send(.string(s))`. Check every `JSONEncoder().encode(...)` call site that could pass a nil/Optional/single-Bool value.
2. **Watch sync writing a stub** — `WatchSyncService.push` may emit a heartbeat / empty-list frame; check `QuipiOS/Services/WatchSyncService.swift` for any send path with a degenerate payload.
3. **iOS `sendRaw` round-trip with empty JSON** — `WebSocketClient.sendRaw` (line 520) does `String(data: data, encoding: .utf8) ?? ""`. If `data` is exactly 4 bytes of valid UTF-8 that isn't valid JSON (e.g. literal `null` body without quotes — possible if MessageCoder somewhere encodes Optional.none), it sends 4 bytes that fail Mac's parse.

**Likely shape:**
- Add a one-shot diagnostic Mac-side: log the raw bytes (hex dump or UTF-8 string preview) the FIRST time `messageType(from:) == nil` per connection, then suppress further logs for that connection. Lets the next session capture exactly what the 4-byte payload contains without flooding logs.
- Once the byte content is known, locate the iOS sender and either drop the send or wrap it in a typed message envelope so it parses correctly.

**Why low priority:** silently ignored downstream — no functional impact. Fix it as a single-PR hygiene item the next time someone is touching `WebSocketServer.receiveMessage` or `WebSocketClient.send` paths.

**Acceptance:** kokoro.log captures one `type=unknown` line per session with the raw bytes. Code change drops the empty-frame send. Subsequent sessions show zero `type=unknown` events.

---

### Bug-1. Empty-URL stalled-state contradiction (sim QA)

**Status:** ✅ Done 2026-05-06 (`f779bd3`). `WebSocketClient.disconnect()` now also clears `lastError` + `connectingStartedAt` — without this, a previous run's "Stalled Ns — resetting" watchdog message lingered in the top-bar `client.lastError` view after disconnect/forget, contradicting the empty-state "Enter tunnel URL" placeholder. Install-verified on QA sim (D853A014) at t=5s, t=40s, and t=4min — no stale watchdog text leaks. 3 WebSocketClientDisconnectTests cover the fix.

---

### G. Picker shows live per-backend reachability

**Status:** ✅ Done 2026-05-06 (`0001371`). BackendPickerSheet now reads `manager.sessions[id].reachability` for every paired-backend row dot color AND adds a per-row caption above the URL: "Connected" / "Connecting…" / "Unreachable" / "PIN required" / "Off". Pure classifier `BackendPickerSheet.classification(enabled:reachability:)` mapped from `(Bool, Reachability?) → RowStatus`. 7 BackendPickerStatusTests lock the mapping. Surfaced from user feedback that "shows recent devices, but it's not clear if they're currently connected or can be currently connected."

---

### H. PTT health banner above mic button

**Status:** ✅ Done 2026-05-06 (`0001371`). Single-line capsule above the main row, hidden by default, surfaces path-degraded states near the mic instead of leaving them buried in Settings → Diagnostics. Priority order: mid-press disconnect (red `wifi.exclamationmark`) → Whisper offline (orange `waveform.slash`, includes the `.failed` reason) → warming up / downloading (secondary, only during a press). Pure classifier `MainiOSView.classifyPTTBanner(isConnected:isRecording:whisperStatus:)`. 9 PTTBannerClassifierTests cover priority + percent rendering + idle-vs-recording gating. Surfaced from user feedback "couldn't tell what was working and what wasn't" with PTT/voice.

---

### I. Codex CLI image-paste path (per-CLI input routing)

**Status:** ✅ Done 2026-05-06 (`6186fee`). Codex CLI's interactive composer accepts pasted IMAGE BYTES via Cmd+V (per OpenAI Codex docs), not a typed absolute path the way Claude Code does. Existing image_upload handler had been typing `<savedURL.path> ` into the window — Claude attaches the image, Codex left a literal string and never attached. Fix:
- New `CLIKind: String, Codable, Sendable, CaseIterable { case claude, codex, shell }` in `Shared/MessageProtocol.swift` + optional `cliKind` field on WindowState (backward-compat).
- `TerminalStateDetector.classifyCLI(children:)` static helper sniffs process names; codex match wins over claude/node because Codex is itself a Node app. Per-window `windowCLIKind` updated every poll cycle.
- New `KeystrokeInjector.pasteImage(at:to:terminalApp:iterm2SessionId:)`: load NSImage from disk, write to NSPasteboard, activate iTerm2 + select target session via AppleScript walk, send Cmd+V via System Events. Restores the user's clipboard string after 0.6s.
- image_upload handler in QuipMacApp branches by cliKind: `.codex` → pasteImage; `.claude / .shell` (default) → existing path-typing path, unchanged.
- 8 CLIKindClassifierTests cover empty / shell / claude / bare node / codex / codex-under-node / both-present / isAIProcess. Live-verified against user's running setup: `node /usr/.../codex` + native `codex` on ttys001 → classifier returns `.codex`; `claude` on ttys002/3/5 → `.claude`.

**Hardware verification needed:** rebuild Mac + send image upload from phone to a Codex window in iTerm2 — should Cmd+V the image into Codex's composer instead of typing the path. Subsequent PTT transcript continues to use existing send_text (write text via AppleScript, unchanged).

---

## Tabled (parked, revisit on demand)

_Empty — entries previously parked here (§52 iPad, §55 Clipboard sync) were dropped 2026-05-06 by user request. Add new tabled items below as needed._
