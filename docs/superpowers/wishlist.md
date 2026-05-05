# Quip Wishlist

Future features, improvements, and known bugs tracked for eventual implementation. Each item here is a candidate for a GitHub issue or sprint work. When you're ready to implement one, it should graduate to a spec in `docs/superpowers/specs/` and a plan in `docs/superpowers/plans/`, then land as a commit on a working branch.

**Scrub history:** 2026-05-05 — collapsed verbose ✅ Done bodies to status line + commit hash. Original context lives in git log + code; the entries here track *what shipped* not *how*. Wishlist / In Progress / Blocked items kept full. Tabled §55 (Universal Clipboard already covers it) and §52 (no iPad).

---

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

**Status:** Wishlist
**Context:** iPhone window list is currently a vertical stack of full-width cards. May want grid (more sessions at once), compact (just names+dots), or carousel (one fullscreen card, swipe between). Open: triggered how (Settings picker / segmented control / long-press / auto-by-count), per-layout info density, persistence (per-device or session-only).
**Related:** #9.

---

### 17. Keyboard-input `onSubmit` + `pressReturn: true` double-Return bug

**Status:** ✅ Not a bug — investigated 2026-04-15. SwiftUI's `onSubmit` consumes Return before text buffer; `sendTextInput()` trims newlines. Single `pressReturn: true` flag appends exactly one newline.

---

### 18. Context-aware 1/2/3 buttons — auto-appear only when Claude shows numbered prompt

**Status:** Wishlist
**Depends on:** #7
**Context:** Static 1/2/3 buttons (#8) ship in shortcut row, visible always. User wants smart variant: 1/2/3 auto-appear only when current window's Claude session presents a numbered prompt block (`❯ 1. Yes / 2. No / 3. Cancel`). Show only buttons matching option count. Disambiguation (real prompt vs prose list) is the hardest part — needs `❯` marker + last-block-before-cursor check.

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

**Status:** Wishlist
**Context:** If QuipMac crashes (10GB memory leak fixed in `6599f02`), iPhone has no recovery — user has to walk to Mac, manually relaunch, re-pair.
**Fix:** Ship `~/Library/LaunchAgents/com.quip.QuipMac.plist` LaunchAgent with `KeepAlive={"SuccessfulExit":false,"Crashed":true}` + `ThrottleInterval=30` (crash-loop guard) + `RunAtLoad=true`. Opt-in toggle in Settings (default off).
**Related:** #20.

---

### 25. iTerm2-version smoke test against AppleScript verbs

**Status:** ✅ Done v1 on `eb-branch` 2026-05-05. New `QuipMacTests/ITermVerbSmokeTests` exercises 11 read-only verbs against live iTerm2, asserts return TYPE on each. Auto-skips when iTerm2 isn't running.

Discovery: iTerm2 returns `miniaturized` Booleans as `typeTrue`/`typeFalse` rather than `typeBoolean`; assertion accepts all three.

**Related:** #13.

---

### 26. Diagnostic-capture ("share state") gesture on iPhone

**Status:** Wishlist — observability infrastructure
**Context:** When something doesn't work in Quip, relevant logs and state are on the Mac; by the time user walks over, state has often changed. Gesture (3-finger long-press on window list, or hidden tap sequence in Settings) snapshots last 200 lines of iPhone log buffer + WS state + Mac window list view + selected windowId + perms + versions + timestamp. Bundles into single JSON, share-sheet to AirDrop. Optionally fire `RequestMacDiagnosticMessage` so Mac dumps its own state into same bundle.

**Note:** §49 Bundle-and-share already shipped the Mac→iOS direction. This entry is now narrowed to the "iPhone snapshots its own state on gesture" half.

**Related:** #12, #21, #49.

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

**Status:** Wishlist (brainstorm paused 2026-04-18)

**5 threads identified:**
1. **Diagnostic tooling / observability** — extend the loud-drop logging pattern (commit `8517835` push-service prototype) across Mac/iOS/Shared services.
2. **Connection truth / status pill honesty** — surface *why* a disconnect happened (pong timeout / explicit close / network loss / auth failure), not just binary.
3. **State invariants across app lifecycle** — audit `willResignActive` / `didEnterBackground` / `willEnterForeground` / `didBecomeActive` on iOS + Mac equivalents. Known offenders: `isPTTActive`, Live Activity handles, `PreferencesSyncService.suppressUntil`, force-quit-after-install.
4. **Error-handling gaps** — repo-wide audit of `try?`, silent `if let / else { return }`, empty `catch {}`, swallowing `guard`. Convert real ones to loud logs or typed errors.
5. **Notification triage in-app** — surface recent push attempts + skip reasons in Mac Settings → Notifications (instead of `tail push.log`).

**Decisions made (paused session):** Shape A (strategy spec covering all 5 + sequencing). Top pain: silent correctness failures. Appetite: weekend.

**When picking up:** resume from Option A (#1+#4 together, deep) unless constraints shifted.

**Related:** `8517835` (push-service loud-drop seed), `843fb68` (volume KVO guard), `3431046` (keepalive-pong fix).

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

**Status:** Wishlist
**Context:** Copy from any iOS app, switch to Quip, paste into selected terminal — text piped via WS, typed into active iTerm window.
**Likely shape:** Paste button (clipboard icon) inline with text-input bar OR in QuickButton row. Tap reads `UIPasteboard.general.string`, sends via existing `SendTextMessage` with `pressReturn: false`. Long-press surfaces options (paste w/ return, raw multi-line, heredoc). Visual feedback ("Pasted N chars").
**Open:** size cap (32KB?), multi-line handling (one chunk vs line-by-line), dedicated affordance vs long-press, inverse direction (terminal selection → iPhone clipboard)?

---

### 38. iTerm scrollback navigation from the iPhone

**Status:** Wishlist (replaces misread half of #7).
**Context:** Pan up/down on iPhone terminal panel to reveal lines that scrolled off iTerm window on Mac. Today Mac captures only visible viewport; scrollback invisible to phone.
**Likely shape:** New `scroll_event` message `{ sessionId, windowId, direction, lines }`. Phone vertical drag on `InlineTerminalContent` image branch → throttled `scroll_event` per ~20pt drag travel. Mac posts `CGEventScrollWheel` or AppleScript `tell iTerm2 to scroll`. Snap-to-bottom button + "scrolled up by N lines" indicator.
**Open:** gesture (plain vertical drag vs two-finger vs scroll thumb), iTerm AppleScript vs CGEventScrollWheel, Cmd+Shift+Up/Down (iTerm's built-in), no-more-scrollback edge.
**Related:** `QuipiOS/QuipApp.swift:~2892` (image branch). Reopened from https://github.com/jboert/Quip/issues/7.

---

### 39. Auto-arrange phone windows on open + manual realign button

**Status:** Wishlist (run `/prd` to shape the chooser).
**Context:** When iPhone opens and windows arrive from Mac, cards land at Mac's raw frame fractions. ≥3 windows on wide Mac display reads as cramped/overlapping. User wants sensible default phone-side layout + "realign" button.
**Likely shape:** New default for `phoneLayoutOverride` (currently `nil`). On first non-empty windows snapshot per session, set chooser-picked value (`"horizontal"` for ≤3 wide, `"vertical"` otherwise, `"grid"` for 4+). Realign button in header.
**Open:** auto-pick on every change vs first-only; persist across launches; realign behavior (reset vs open chooser sheet); interaction with §40 drag.
**Related:** `QuipiOS/QuipApp.swift:655` (override state), `:1526` (arrange button cycle), `:2105` (`phoneLayoutFrame`).

---

### 40. Drag-to-move windows on the iPhone layout

**Status:** Wishlist (run `/prd` to lock semantics).
**Context:** Grab a card on iPhone preview, drop elsewhere. No per-window phone-side override today.
**Likely shape:** `phoneFrameOverrides: [String: WindowFrame]` (@AppStorage keyed by Mac UUID + windowId). DragGesture on `WindowRectangle`. Snap behavior: free / grid / swap-on-overlap. Visual feedback during drag.
**Open:** phone-only preview vs Mac mirror (heavier, needs `set bounds of window` + reflow); resize-with-drag too?; cross-display moves; interaction with §39.
**Related:** `QuipiOS/QuipApp.swift:2036` (`ForEach`), `:2105` (`phoneLayoutFrame`), `:2119` (`windowRect`).

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

## Tabled (parked, revisit on demand)

- §52 iPad layout — tabled 2026-05-05 by user. No iPad to test on; not a current priority.
- §55 Clipboard sync (Mac↔iPhone) — tabled 2026-05-05 by user. Apple's Universal Clipboard (Handoff) already covers when both devices share iCloud + Bluetooth + Wi-Fi. Revisit only if Quip ever needs to sync clipboards across users / devices not on the same iCloud.
