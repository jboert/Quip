# Quip Wishlist

Future features, improvements, and known bugs tracked for eventual implementation. Each item here is a candidate for a GitHub issue or sprint work. When you're ready to implement one, it should graduate to a spec in `docs/superpowers/specs/` and a plan in `docs/superpowers/plans/`, then land as a commit on a working branch.

**Maintenance rules:**

- Every item has a **Title**, **Status**, **Context**, and (optionally) a link to its spec/plan once one exists.
- Status values:
  - `Wishlist` — not yet brainstormed, just an idea captured.
  - `Planned` — spec + plan exist, ready to implement.
  - `In Progress` — actively being worked on. Note the branch name.
  - `Blocked` — depends on another item or an external decision.
  - `Done` — implemented. Note the commit(s). Periodically moved to the "Completed" section at the bottom.
- When converting to a GitHub issue later, the item's **Title** becomes the issue title, and its **Context** becomes the issue body. The **Status** line should be updated to link back to the issue.
- This file lives on `eb-branch` primarily but is intended to be pullable into `main` when the repo owner wants visibility.

---

## Active Wishlist

### 0. PTT reliability — C-scope timing fixes (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — 17 commits landed 2026-04-23 (`1b5cba2` → `4a89731`). Five iterations plus three bonus fixes. Tests: 120 passing in `QuipiOSTests` (was 51 before this work). iphoneos build green.

**What shipped (C-scope):**
- Iter 1 — Button hygiene: `isPTTActive` resets on `stopMonitoring` / `resumeAfterBackground`, route-change observer force-stops on AirPods/BT swap, 30s stuck-press watchdog (was 5s, bumped because short thinking pauses were tripping it). Commits: `1b5cba2`, `ff9adf0`, `01f0d3c`, `15adac6`, `a2654f5`.
- Iter 2 — Trailing flush: 300ms tap-keep-alive after `endAudio` + 2s hard-cap in `AudioWorker.stop()`, `isFlushing` reset on all completion paths (start / hard-cap with task-identity match / error branch). Commits: `cf1bb10`, `b44479b`, `9f57250`.
- Iter 3 — Long-lived engine: `AudioRingBuffer` captures 500ms pre-roll, `arm()`/`disarm()` on `AudioWorker` wired via `HardwareButtonHandler.onArm`/`onDisarm` in `QuipApp.swift`, pre-roll replayed on each `start()`, interruption observer disarms/rearms on Siri/phone-call. Commits: `b356d2a`, `354e2aa`, `75b8905`.
- Iter 4 — Seam stitching: `SeamStitcher.stitch(old:, new:)` dedups 1–3 word overlap case-insensitively between consecutive recognizer tasks (e.g. at the ~1-minute recognizer-restart boundary or mid-press silence-triggered isFinal). Replaces the blind `accumulated + " " + text` concat. Commits: `491dc3a`, `b2d0c23`.
- Iter 5 — Contextual vocab: `QuipiOS/Resources/dictation-vocab.txt` (20 terms) bundled and applied via `request.contextualStrings` on every recognition request. Commits: `c4793bd`, `4a89731`.

**Bonus fixes caught during execution:**
- **Async `stopRecording` with completion handler** (`d1c43b9`). The prior synchronous return of `transcribedText` was a pre-flush snapshot — the last spoken words captured in the 300ms trailing window never reached `SendTextMessage`. `speech.stopRecording(completion:)` now fires the completion on the worker's `finished=true` callback (or a 3s safety timeout). `QuipApp.stopRecording` defers its send into that completion.
- **Session-token guard** (`8c63cd1`). Old session's trailing-flush callback was overwriting `transcribedText` and flipping `isRecording=false` on a NEW press that started within ~300ms of release. Each `startRecording` now mints a UUID; stale callbacks fire pending completions but do not mutate current-session state.

**Iter 5 ceiling observation (device acceptance):** `SwiftUI` transcribed correctly (Apple brand in training data), but `Xcode`, `monospace`, `WebSocket` still split/dropped. `contextualStrings` nudges the on-device model, doesn't override. This is the ceiling of `requiresOnDeviceRecognition = true` and the motivation for D-scope below.

**Artifacts:**
- Spec: `docs/superpowers/specs/2026-04-23-ptt-reliability-design.md`
- Plan: `docs/superpowers/plans/2026-04-23-ptt-reliability.md`

---

### 0b. PTT recognizer swap (D-scope) — Mac Whisper local, v1 thinnest slice

**Status:** 🟡 Code landed on `eb-branch` (2026-04-24) — pending user acceptance on hardware before marking shipped.

**Spec:** `docs/superpowers/specs/2026-04-24-ptt-whisper-recognizer-design.md`
**Plan:** `docs/superpowers/plans/2026-04-24-ptt-whisper-recognizer.md`
**Commits (9):** `f1dec29` (messages) → `59cc271` (PCMChunker) → `c88fea4` (WhisperAudioSender) → `bd34ec5` (WebSocketClient) → `ddf82ca` (RemoteSpeechSession) → `52432db` (SpeechService path branching) → `c5da543` (WhisperKit SPM dep) → `a216533` (WhisperDictationService) → `37619c6` (QuipMacApp wiring)

**What shipped (v1 scope A — thinnest slice):**
- iPhone streams 100 ms PCM frames (int16 LE mono 16 kHz, base64 in a Codable envelope) over the existing Bonjour WS.
- Mac runs WhisperKit 0.18.0 with `openai_whisper-base` (~150 MB, auto-downloaded first launch) and returns one `TranscriptResultMessage` per press.
- Auto-fallback: if WS down OR `WhisperStatusMessage.state != .ready` at PTT-start → iPhone on-device `SFSpeech` path runs unchanged.
- 147 iOS tests + 165 Mac tests green end-of-task 9.

**What was deliberately NOT built (explicit v1 non-goals):**
- Settings recognizer picker (iPhone / Mac Whisper / Mac Apple Speech).
- Model-size picker (tiny / base / small / medium / large) — user asked for "most performant options available"; follow-up in §0c below.
- Per-source diagnostics panel.
- Vocab editor UI.
- Streaming partials mid-utterance (final-only on stop).
- Mid-session recognizer cross-over.
- Cloud STT.

**Pending acceptance tests (block shipped status):**
1. Happy path: WS up, 5–10 s dictation with technical vocab ("SwiftUI WebSocket monospace Xcode") — Whisper transcribes cleanly where on-device SFSpeech garbles.
2. Fallback at start: kill Mac → PTT still works via local SFSpeech.
3. Mid-session drop: start PTT, `pkill -9 Quip` on Mac → toast within 3 s, no ghost recording.
4. First-run model download: fresh Mac install → local SFSpeech handles presses until download finishes, then Whisper kicks in.

When all four pass, flip status to ✅ and delete the "pending acceptance" list.

---

### 0c. PTT recognizer Settings picker + model-size selector (follow-up to §0b)

**Status:** Wishlist
**Depends on:** §0b acceptance passing

**Context:** During the §0b brainstorm on 2026-04-24 the user explicitly asked for "the most performant options available" — meaning a Settings surface where they can pick tiny / base / small / medium / large Whisper models. v1 shipped with base hardcoded. This entry captures the follow-up.

**Scope:**
- Settings UI — recognizer source picker (iPhone on-device / Mac Whisper / Mac Apple Speech). Mac Apple Speech is the server-class `SFSpeechRecognizer` without `requiresOnDeviceRecognition` — free with macOS, no model download.
- Model-size picker when source == Mac Whisper: tiny (~40 MB) / base (~150 MB, current default) / small (~500 MB) / medium (~1.5 GB) / large (~3 GB). Bigger models = better vocab + slower inference + longer first-run download.
- Per-source diagnostics panel (last N transcripts, inference time, confidence).
- Vocab editor — live-editable companion to the current bundled `dictation-vocab.txt`. Whisper supports `promptTokens` for vocab biasing.

---

### 1. `/plan` shortcut button on iPhone

**Status:** ✅ Done (upstream) — shipped by jboert across commits `68fdb04`, `87f6e16`, `aa3ab2e`, `5fd0bf6` on `main`. The `/plan` button lives in the configurable `QuickButton` enum, appears in both portrait and landscape controls, and sends `/plan ` via `SendTextMessage` with `pressReturn: false`.

**Original context** (kept for historical reference):
A one-tap button on the iPhone remote that types `/plan ` into the currently selected terminal window on the Mac. Leaves the cursor on the same line so the user can continue typing or dictating.

**Related:** #19 (`/btw` shortcut button — shipped same session as the #13 fix).

---

### 2. Add / close terminal tabs from the iPhone remote

**Status:** ✅ Done — retroactively. Both halves shipped via larger follow-on features that subsumed this entry:
- **Open-new-tab:** `SpawnWindowMessage` via the project-directory picker — shipped under #29 on `eb-branch` (commits `5b35c71`, `24fee2d`, `2320170`). `QuipiOS/QuipApp.swift:981` fires the message when the user taps a project; `QuipMac/QuipMacApp.swift:842` handles it and auto-selects the new window.
- **Close-tab:** `CloseWindowMessage` via the per-window context menu's "Close terminal…" item with destructive alert confirmation — shipped under the duplicate/close feature (commits `44033ee → 75c2b95`). `QuipiOS/Views/WindowRectangle.swift:184` fires the message from the confirmation alert's destructive button; `QuipMac/QuipMacApp.swift:828` handles it with a windowId lookup + `ErrorMessage` broadcast on drop. The context menu also offers "Remove from Phone" (soft-delete via `toggleEnabled`) to separate "hide the terminal from the phone" from "kill the terminal session."

**Original context** (kept for historical reference):
The iPhone currently cycles through existing Claude Code terminal windows via the left/right chevron buttons but cannot create or destroy them. The user wants to open new Claude Code sessions and close existing ones directly from the phone. User asked for this explicitly as a separate feature from `/plan`.

---

### 3. Landscape layout for `/plan` shortcut button

**Status:** ✅ Done — `/plan` was already in the landscape `TerminalContentOverlay.swift` button row (shipped upstream by jboert in `5fd0bf6`). `/btw` was added alongside it in `c3d8b78` on `eb-branch` (2026-04-15).

---

### 4. Cross-platform parity for `/plan` button

**Status:** Wishlist
**Depends on:** #1
**Context:** QuipLinux and QuipAndroid do not have the `/plan` button. Once v1 lands on iOS, mirror it to the other clients. Each platform has its own UI code, so this is at least two follow-up commits — one per client.

---

### 5. `/plan` button v2 — optional auto-dictation

**Status:** Wishlist
**Depends on:** #1
**Context:** The original `/plan` ask included auto-starting voice dictation after the button tap. User scrapped this for v1 but may revisit. If revived: on button tap, send `/plan ` prefix via `SendTextMessage`, then immediately call `speech.startRecording()`, then on release send the transcribed text as a follow-up `SendTextMessage` with `pressReturn: true`. Needs thought about edge cases (what if the user cancels dictation mid-way — does `/plan ` stay typed but uncommitted?).

---

### 6. Real Claude Code plan mode via Shift+Tab cycling

**Status:** ✅ Done — shipped on `eb-branch` (2026-04-20). Builds on #7's mode detection.

**What shipped:**
- New `shift+tab` case in `KeystrokeInjector.sendKeystroke`. iTerm2 path uses the standard CSI back-tab sequence `ESC [ Z` via `write text ((character id 27) & "[Z") newline no` — concatenating the escape byte with the literal CSI tail in AppleScript. Terminal.app path uses System Events `keystroke "tab" using {shift down}`.
- Refactored the per-key table from `iTerm2CharIdFor(_) -> Int?` to `iTerm2WriteExpression(for:) -> String?` so it can return multi-character expressions; full table locked under unit tests so accidental edits don't silently break a keystroke.
- New high-level quick actions on the Mac: `set_plan_mode`, `set_auto_accept_mode`, `set_normal_mode`. Each reads `claudeModeDetector.windowModes[windowId]` and uses `ClaudeMode.shiftTabPresses(from:to:)` to compute exactly the right number of Shift+Tab presses (0…2; cycle is normal → autoAccept → plan → normal). Presses are staggered 80ms apart so Claude Code's TUI redraws between them.
- Fallback: if the mode for that window is unknown (detector hasn't seen an indicator yet), the Mac broadcasts an `ErrorMessage` toast instead of pressing blind. User then taps the manual `press_shift_tab` action to step the cycle.
- iOS QuickButton additions: `planMode` ("→Plan mode" with `wand.and.stars` icon, slash category) and `shiftTab` ("Shift+Tab" with `arrow.left.to.line` icon, keystroke category).

**Files:** `QuipMac/Services/KeystrokeInjector.swift` (new shift+tab case + refactored expression table), `Shared/MessageProtocol.swift` (`ClaudeMode.cycle` + `shiftTabPresses(from:to:)` math), `QuipMac/QuipMacApp.swift` (`cycleClaudeMode(to:for:)` helper + 4 new quick-action cases), `QuipiOS/QuipApp.swift` (2 new QuickButton enum cases with display name / label / icon / category / action).

**Tests:** `QuipMac/Tests/KeystrokeInjectorWriteExpressionTests.swift` (locks every key's AppleScript expression under unit tests — single-byte chars + Shift+Tab CSI + case insensitivity + unknown→nil), `Shared/Tests/MessageProtocolTests.swift` (4 new tests for cycle math: no-movement, forward, wrap-around, never-exceeds-cycle-length-minus-one). 116 Mac tests pass; iOS build green.

**Original context** (kept for historical reference):
Instead of typing `/plan` as a literal prefix (which only gives *plan-style* behavior via prompt text), actually put Claude Code into its built-in plan mode by pressing Shift+Tab the correct number of times. Without mode detection (#7), blind Shift+Tab presses land in the wrong mode (Normal / Auto-Accept / Plan cycle is state-dependent).

---

### 7. Read Claude Code mode from terminal content stream

**Status:** ✅ Done — shipped on `eb-branch` (2026-04-20). New `ClaudeModeDetector` service on the Mac polls each tracked window's iTerm buffer every 2s, scans the last ~40 lines for `plan mode on` / `auto-accept edits on`, and exposes the result via a new optional `claudeMode: String?` field on the `WindowState` protocol struct (raw values: `"normal"`, `"plan"`, `"autoAccept"`). On mode change, `broadcastLayout()` re-fires so iOS sees the new state within one poll cycle.

**Files:** `Shared/MessageProtocol.swift` (added `ClaudeMode` enum + `claudeMode` field with backward-compat decoder), `QuipMac/Services/ClaudeModeDetector.swift` (new), `QuipMac/Services/WindowManager.swift` (`toWindowState` accepts mode), `QuipMac/QuipMacApp.swift` (instantiate, wire `onModeChange` → `broadcastLayout`, mirror tracked-window set, prune on `syncTrackedWindows`).

**Tests:** `Shared/Tests/MessageProtocolTests.swift` (round-trip + backward-compat for `claudeMode`), `QuipMac/Tests/ClaudeModeScannerTests.swift` (scanner unit tests covering plan, autoAccept, normal-as-nil, empty, tail-window cutoff for old-prose mentions, both-strings-plan-wins, case insensitivity). 116 Mac tests pass; iOS build green.

**Unlocks:** #6 (robust Shift+Tab plan-mode switching), #18 (context-aware 1/2/3 prompt-response buttons), visible mode indicator on the iPhone status area, intelligent prompt routing decisions. iOS doesn't yet *consume* the field — that lands when #18 (or a v2 status indicator) implements it.

**Original context** (kept for historical reference):
Parse the terminal content stream to detect Claude Code's current mode indicator strings — `plan mode on`, `auto-accept edits on`, or the absence of either (= Normal mode). Exposes Claude Code's internal mode state to Quip's UI.

---

### 8. Number shortcut buttons (1 / 2 / 3) for multiple-choice answers

**Status:** ✅ Done (upstream) — shipped by jboert in commit `4e774e6` as part of the settings drawer and configurable quick-buttons picker. The buttons now live in the second shortcut row, toggled on/off via a gear-icon drawer.

**Original context** (kept for historical reference):
Claude Code occasionally asks multiple-choice questions with two or three lettered/numbered options. Quip already has `press_y` and `press_n` quick actions that iPhone buttons fire to answer yes/no prompts. User wanted three additional buttons — `1`, `2`, and `3` — to answer three-option prompts the same way.

Resolved. Keep this entry to remember the original request and to make it findable when auditing "what did the settings drawer add."

**Related:** #18 (context-aware variant — auto-appear only when Claude shows a numbered prompt), #28 (larger / higher-contrast option for these buttons in night mode).

---

### 9. Window list organized/filtered by application, iTerm2 at the top by default

**Status:** ✅ Partially done (upstream) — shipped by jboert in commit `23f1032`. Terminal windows are now automatically herded to the top of the Mac's window list and on the phone so Claude sessions aren't buried under browser windows. The folder name is now in bold colored text on both the phone tiles and the Mac sidebar, with the terminal app name tucked underneath.

**Still wishlist:** Explicit grouping by application (section headers on the phone) and per-app filtering (hide apps you don't care about). Those are UX refinements on top of the prioritization work that jboert already did.

**Related:** #16 (alternative window list arrangements) — grouping + filtering + layout are all "how the list is rendered" concerns and should be designed together in a future pass.

---

### 10. Persist last session — remember which windows were open on close/reopen

**Status:** ✅ Done (upstream) — shipped by jboert on `main` in commit `9f1b531` ("Fix push-to-talk not submitting, and persist enabled windows across Mac restarts"). QuipMac now persists the set of enabled windows across restarts. Landed in local `main` on 2026-04-15 when this eb-branch session pulled the latest upstream.

**Original context** (kept for historical reference):
When Quip (QuipMac, and probably also QuipiOS) closes and relaunches, the list of registered/enabled terminal windows starts fresh — the user loses their previously-curated set and has to re-enable each one. User wants "save the last session" behavior: on close, persist enough state that on relaunch the same windows are automatically recognized and enabled.

**Core questions to resolve during brainstorming:**
- **What gets persisted?** Minimum: the set of enabled window identities (app bundle ID + window title + maybe initial working directory). Maximum: full window state (enabled, color assignment, pinned status, layout slot, last-known PID/CGWindowID).
- **How are windows re-matched after relaunch?** Window CGWindowIDs change on every process restart, so matching has to be heuristic. Candidates: (app bundle ID, window title), (pid, window index), (working directory in title), or a combination with fallback. Near-duplicates (two iTerm2 windows both titled `~/Projects/Quip`) need a tie-breaker.
- **Where does state live?** Probably `~/Library/Application Support/Quip/session.json` on the Mac, `UserDefaults` on iOS. Do not commit to iCloud/Keychain for v1 — keep it local.
- **Invalidation policy.** If a persisted window isn't found on relaunch (e.g., the Claude Code session was closed while Quip was down), silently drop it vs. show a "couldn't reconnect to N windows" notice. Probably silent for v1.
- **iPhone-side persistence.** Should QuipiOS also remember which window was last selected, so reopening the iPhone app jumps back to the same window? Probably yes — it's a one-liner to stash `selectedWindowId` in `UserDefaults` and hydrate on launch.

**Dependencies:** None blocking. Could be implemented any time. Would pair nicely with the window-grouping feature (#9) since both touch the window list rendering on the iPhone.

**Out of scope (for v1, explicitly):** Cross-device session sync. If you open Quip on iPad A and then reopen on iPad B, there's no expectation they share state.

---

### 11. Window ID stability across QuipMac restarts

**Status:** ✅ Partially done — shipped in commit `30be68c` on `eb-branch` (2026-04-15). When the phone receives a layout update and its `selectedWindowId` is no longer in the window list (Mac restarted, window closed), it auto-selects the first available window instead of going to nil. Full stable-UUID-based window identity is still wishlist but the silent-dead-selection problem is fixed.
**Context:** Every time QuipMac is killed and relaunched, `WindowManager` re-registers all terminal windows and assigns them fresh internal IDs. The iPhone, meanwhile, still holds a `selectedWindowId` from the previous session in its local state. When the iPhone sends a `QuickActionMessage` or `SendTextMessage` with the old ID, the Mac's handler fails to find a matching window and **silently drops the message** — from the user's perspective, the button "stops working" with zero feedback.

**Fix options:**
- **(a) Stable window identity.** Generate `ManagedWindow.id` as a hash of `(app bundle ID, PID, CGWindowID)` or even `(app bundle ID, initial window title, first-seen timestamp)` so it survives Mac restarts as long as the underlying terminal window is still open. Trade-off: harder to change if the underlying window's identity shifts (e.g., iTerm2 reassigns CGWindowID on some operations).
- **(b) iPhone re-validates on reconnect.** When the iPhone receives a fresh window list after reconnecting to QuipMac, it checks whether its locally-selected windowId is still in the list; if not, it clears the selection and shows "please re-select a window."
- **(c) Server-driven reset.** On reconnect, the Mac sends a `ResetSelectionMessage` telling the iPhone to clear any selected windowId. Simple but loses state the user might want to preserve.

**Recommendation:** option (b) as v1 — cheapest fix, most user-friendly. Requires one new message handler on the iPhone and one reconnect-time check.

**Related:** #10 (session persistence) — if implemented, might subsume this item by persisting the window identity in a stable form. #20 (WebSocket heartbeat) — the heartbeat's reconnect handler is the natural trigger point for option (b)'s "iPhone re-validates on reconnect" check.

---

### 12. Silent failure diagnostics — add audible errors or UI feedback when messages are dropped

**Status:** ✅ Done — shipped in commit `30be68c` on `eb-branch` (2026-04-15). Added `ErrorMessage` to the protocol. All 4 Mac-side handlers that drop messages (`send_text`, `quick_action`, `duplicate_window`, `close_window`) now broadcast an `ErrorMessage` back to the phone. The phone shows a red capsule toast at the top that auto-dismisses after 3 seconds.
**Context:** Several handlers in `QuipMac/QuipMacApp.swift` use the `if let window = windowManager.windows.first(where: { $0.id == msg.windowId })` pattern and silently return when the lookup fails. This makes debugging hard: a button that "doesn't do anything" could be dropped at any of half a dozen stages, and without instrumentation there's no signal.

As a quick-win, commit `(TBD)` added `print` statements to the `send_text` and `quick_action` handlers so dropped messages show up in Xcode console / Console.app. But that's just observability for *developers* — the user still sees "button didn't work."

**Fix options:**
- **(a) Error broadcast message.** When the Mac drops a message, send an `ErrorMessage` back to the iPhone with a reason code. The iPhone can show a toast or temporary banner ("⚠ window no longer exists").
- **(b) Haptic/visual failure feedback.** On the iPhone, if a button tap doesn't produce an expected state change within N milliseconds, fire a distinct "failure" haptic. Requires the iPhone to have state awareness of what "success" looks like, which is harder.
- **(c) Client-side pre-flight check.** Before sending a message, the iPhone verifies the selected windowId is still in the window list it last received. If not, disable the button visually. This prevents the bug from happening in the first place.

**Recommendation:** (a) for completeness + (c) as a belt-and-suspenders measure.

**Related:** #20 (WebSocket heartbeat / dead-peer detection) — same underlying concern from a different angle. #20 surfaces dead *connections*; this entry surfaces dropped *messages* on a connection that's still live. Both are needed to fully eliminate "I tapped the button and nothing happened" as a possible state.

---

### 13. Multi-iTerm2-window keystroke targeting (real fix)

**Status:** ✅ Done — shipped in commit `2ec1ed0` on `eb-branch` (2026-04-15). Used option (a) from the original design: each iTerm2 session's stable `unique id` (UUID) is cached on `ManagedWindow.iterm2SessionId` at registration time via an AppleScript probe. All three injection functions (`sendText`, `sendKeystroke`, `readContent`) now select by `unique id of s` when a session id is supplied, falling back to `current session of front window` when nil. All ~18 call sites in `QuipMacApp.swift` thread the cached session id through. 40 Mac tests + 51 iOS tests pass. The broken `id of w is <cgWindowNumber>` pattern (which never matched because iTerm2's `id of window` is its own internal integer, not a CGWindowID) is fully replaced.

**Spec:** `docs/superpowers/specs/2026-04-15-iterm2-session-id-targeting-design.md`
**Plan:** `docs/superpowers/plans/2026-04-15-iterm2-session-id-targeting.md`

---

### 14. Gitignore generated Info.plist files to prevent fix-in-wrong-layer bugs

**Status:** ✅ Done — shipped in commit `6ca6f60` on `eb-branch` (2026-04-15). Both `QuipMac/Info.plist` and `QuipiOS/Info.plist` are now `.gitignore`'d with explicit path entries under an `# xcodegen-generated Info.plist` section; a README note near the Building section explains the rule and the `.xcodeproj` asymmetry; pre-commit drift check ran clean (no lost edits). `.xcodeproj/project.pbxproj` tracking stayed intact — the asymmetry is intentional and documented.

**Spec:** `docs/superpowers/specs/2026-04-15-gitignore-generated-info-plist-design.md`
**Plan:** `docs/superpowers/plans/2026-04-15-gitignore-generated-info-plist.md`

**Loose end:** The plan's Step 7.5 (Xcode `xcodebuild` smoke test) was skipped during execution because the subagent sandbox blocked the long-running build. File-level verification is strong (both files still on disk after `xcodegen generate`, all git checks pass), but a formal 30-second `Cmd+B` on both schemes in Xcode is still owed to tick the last testing box.

**Original context** (kept for historical reference):
`QuipiOS/Info.plist` and `QuipMac/Info.plist` are both generated outputs of `xcodegen`, produced from the `info.properties` section of each project's `project.yml`. But they were tracked in git, which created a trap: you could edit the tracked Info.plist directly, commit it, and the fix looked correct in `git diff` — until the next time anyone ran `xcodegen generate`, which silently clobbered the edit from the project.yml source of truth. This trap bit us in commit `ed68292`: an earlier fix in `f7bb347` removed `NSAllowsLocalNetworking: true` from `QuipiOS/Info.plist` directly but left the flag in `QuipiOS/project.yml`, and every subsequent xcodegen run silently re-added it and broke Tailscale. `QuipiOS/project.yml:59-65` now carries an explicit comment documenting this trap at its source of truth, and with this entry shipped the trap is now closed at the git layer too.

**Related:** #11 (silent failure diagnostics) — same flavor of bug. Both are about making drift visible.

---

### 15. Push notifications when Claude asks the user for input

**Status:** Wishlist
**Context:** When Claude Code in a terminal window asks the user a question (e.g., "Do you want me to proceed? (y/n)" or "Which file should I edit?"), the user currently has to be actively looking at either the Mac screen or the iPhone Quip app to notice. They want a **push notification on the iPhone** that fires whenever ANY registered Claude Code window transitions into a "waiting for user input" state, so they can be heads-down on something else and still get pinged.

**Prerequisites:**
- QuipMac already has a terminal state detector (`QuipMac/Services/TerminalStateDetector.swift`) that tracks per-window state. There's presumably a `waiting_for_input` or similar state. The detector's state-change events could drive notification sends.
- The iPhone needs to register for remote or local push notifications. For local pushes (no APNS), `UNUserNotificationCenter.current().add(request:)` can schedule a notification from the iPhone side upon receiving a state-change message from the Mac. For remote pushes (background delivery when Quip isn't open), the Mac would need to send via APNS which requires a dev cert and APNS HTTP/2 plumbing — significant setup.
- Entitlements: `aps-environment` for remote, none for local.

**Design choices to resolve in brainstorming:**
- **Local vs remote push**: local is dramatically simpler but only fires when Quip is open or recently backgrounded. Remote fires even when Quip is killed, but requires APNS setup. User's travel-mode use case suggests remote is better, but local is a cheap v1.
- **Which windows trigger**: all enabled windows, or only the currently-selected one? User said "any window" — so all enabled.
- **Rate limiting**: if Claude asks ten questions in 30 seconds, do we fire ten notifications or batch? Probably batch — "Claude is waiting for input on 3 windows" type summary.
- **Content**: just "Claude is waiting" vs. showing the actual prompt text. Privacy implication if notification content contains code snippets.
- **Tap behavior**: tapping the notification should open Quip and select the relevant window.

**Dependencies:** None blocking. Needs its own brainstorm session.

---

### 16. Alternative window list arrangements (grid / compact / carousel)

**Status:** Wishlist
**Context:** The iPhone's window list is currently a vertical stack of full-width cards. The user explicitly said they like this as the default, but may want alternative arrangements down the road — a grid (for seeing many sessions at once with less per-card detail), a compact list (just names and status dots, smaller than current), or a swipeable carousel (one fullscreen card at a time, swipe between sessions).

**Design questions to resolve later:**
- **Triggered how?** A picker in Settings, a segmented control at the top of the window list, a long-press on the list background, or auto-switching based on window count?
- **Information density per layout.** Grid mode probably shows less info per card (just app + status dot). Compact mode shows just name. Carousel mode shows everything including an embedded terminal preview.
- **Interaction surface area.** Long-press context menu (from tab-management feature #6) must work in all layouts — the primary interaction model stays consistent across arrangements, only the visual layout changes.
- **Persistence.** Should the chosen arrangement be remembered per-device, or is this a view toggle like Apple Mail's "Classic/Unified" that resets on launch?

**Dependencies:** None blocking. Could be built any time after the tab management feature (#6) lands so the context menu actions are present before we introduce visual variations of the card container.

**Related:** #9 (window list grouped by app with iTerm2 at top) — the two should be designed together eventually since grouping and arrangement are both "how the list is rendered" concerns.

---

### 17. Keyboard-input `onSubmit` + `pressReturn: true` double-Return bug

**Status:** ✅ Not a bug — investigated 2026-04-15. SwiftUI's `onSubmit` consumes the Return key event before it enters the text buffer, and `sendTextInput()` trims whitespace/newlines before sending. The text arrives clean at the Mac, and the single `pressReturn: true` flag appends exactly one newline. No double-Return occurs.

---

### 18. Context-aware 1/2/3 buttons — auto-appear only when Claude shows a numbered prompt

**Status:** Wishlist
**Depends on:** #7 (read Claude Code state from terminal content stream)
**Context:** The static 1/2/3 buttons from #8 ship in the configurable shortcut row — once enabled in the settings drawer, they're visible all the time even when Claude isn't currently asking a numbered question. User wants a smarter variant: the 1/2/3 buttons should automatically appear **only** when the currently selected window's Claude session is presenting a numbered multiple-choice prompt (e.g., the standard `❯ 1. Yes / 2. No / 3. Cancel` block), and disappear as soon as the prompt is dismissed or replaced. Surface only the buttons that match the option count Claude is offering — just 1+2 for a two-option prompt, 1+2+3 for three, etc.

Detection lives in the same terminal-content-parsing pipeline as #7 — once Quip can scrape Claude's state from the output stream, recognizing a numbered-prompt block is one more matcher on top.

**Design questions to resolve in brainstorming:**
- **Where do the auto-buttons render?** Floating overlay above the existing shortcut row, replace the static row temporarily, or a new dedicated "prompt response" area?
- **Cap at 3?** What if Claude shows 4+ options? Skip the feature, show 1–3 and let the user type the rest, or a scrollable strip?
- **Disambiguation.** Hardest part: telling a real numbered *prompt* apart from a numbered *list in prose* ("Here are three things to know: 1. ..."). Probably needs the cursor/selector marker (`❯`) as a positive signal plus a "this is the last block before the input cursor" check.
- **Lettered prompts (a/b/c).** Out of scope for v1 — separate follow-up if it's worth it.
- **Interaction with the static buttons from #8.** If the user has already enabled the static 1/2/3 in the settings drawer, do the auto-buttons replace them while a prompt is active, or do they double up? Probably the static buttons stay put and the auto-buttons add a distinct visual treatment (highlighted, larger, animated in) so the user knows "this is the answer to right now."

**Related:** #7 (terminal content parsing — strict prerequisite), #8 (the static 1/2/3 buttons that already exist), #28 (the auto-appearing buttons should pick up the user's size / contrast preference from #28's Settings option, not get re-styled separately).

---

### 19. `/btw` shortcut button on iPhone

**Status:** ✅ Done — shipped in commit `c3d8b78` on `eb-branch` (2026-04-15). Added `btw` case to the `QuickButton` enum with `.sendText("/btw ", pressReturn: false)` action. Also added to the landscape `TerminalContentOverlay` button row. One commit, 5 lines changed.

**Original context** (kept for historical reference):
A one-tap button on the iPhone remote that types `/btw ` into the currently selected terminal window. `/btw` is a Claude Code slash command that dispatches a subagent for side questions without polluting the main conversation context.

---

### 20. WebSocket heartbeat / dead-peer detection

**Status:** ✅ Partially done — shipped in commit `30be68c` on `eb-branch` (2026-04-15). Client keepalive tightened from 30s→10s ping interval; failed pings immediately trigger disconnect + reconnect with exponential backoff. Server already had TCP keepalives at 15s/5s/3-probe (~30s). Combined: dead connections surface within ~10-15s on the phone (down from ~30-60s). The UI already had a connect bar that shows when disconnected. Full bidirectional heartbeat with server-initiated pings is still wishlist but the main "silent dead connection" problem is dramatically reduced.

**Original context:**
When QuipMac crashes, the Mac sleeps, Tailscale drops the route, or any other "the other end is gone" event happens, the iPhone's WebSocket state still reports "connected" until the next outgoing send fails. Until then, every button tap appears to succeed (the message gets queued / sent without error) but nothing happens on the Mac. This is the root cause of the largest class of "Quip just stops working" reports — the connection looks alive, the app has no signal that it isn't, the user has no signal that it isn't, and the only recovery path is force-quit-and-relaunch on the iPhone.

**Fix:** implement a bidirectional heartbeat at the WebSocket layer. Both the iPhone and the Mac send a ping frame every ~5 seconds; if either side doesn't receive a pong within ~15 seconds, the connection is considered dead. The detecting side immediately surfaces a visible "disconnected" UI state (red banner on the iPhone, status bar update on the Mac), tears down the dead WebSocket, and enters a reconnect loop with exponential backoff (1s, 2s, 4s, 8s, 16s, cap 30s). On successful reconnect, the iPhone re-requests the current window list to resync.

**Design questions to resolve in brainstorming:**
- **Built-in WebSocket PING/PONG frames or custom application-layer message?** Built-in is cleaner — `URLSessionWebSocketTask` has `sendPing(pongReceiveHandler:)` natively, no `MessageProtocol.swift` changes required. Custom would let you piggyback diagnostic info (last-known window list version, etc.) but is more code for the same liveness outcome. Default to built-in.
- **Heartbeat cadence and timeout.** 5s/15s is the defensible default — fast enough to surface disconnects within a single button-press iteration, slow enough not to false-positive on slow Tailscale renegotiations or brief network blips. Worth tuning after seeing real data, but don't go below 3s/9s without measurement (battery + radio cost on the iPhone gets meaningful below that).
- **Background behavior on iOS.** When QuipiOS is backgrounded, iOS suspends the WebSocket within ~30 seconds regardless of what the app wants. Two options: (a) keep heartbeats running via a `beginBackgroundTask` assertion — responsive but burns the iOS background-execution budget and drains battery; (b) accept that "backgrounded for >30s ≈ disconnect on resume" and just reconnect aggressively on foregrounding — simpler, lower battery, mildly worse UX. Probably (b) for v1.
- **Visible failure UI.** A red banner on the iPhone with the message "Quip Mac unreachable — reconnecting…" plus a one-time haptic the moment the disconnect first happens. The banner is the entire point of the feature — never let "nothing happens" be a valid state. The Mac side gets a quieter status-bar update since the user isn't usually staring at QuipMac when it dies.
- **Server-side liveness on QuipMac.** The Mac side's heartbeat detector should also drive cleanup of stale per-client state in `WindowManager` so a re-pairing iPhone gets a clean slate. Probably out of scope for v1 unless multi-iPhone usage lands on the roadmap, but worth noting in the spec.

**Why this is the highest-leverage reliability fix on the entire wishlist:**
- Surfaces the root cause of the largest single class of "Quip stopped working" bugs — silent connection death — that today only gets noticed when the user happens to look at the phone and realizes their last few taps did nothing.
- Unlocks safe client-side retry policies (you cannot safely retry a message if you don't know whether the connection is alive — and dedupe-on-the-Mac would be a separate follow-up wishlist item).
- Makes every other reliability bug on the wishlist easier to triage, because "is the connection alive?" stops being an ambiguous variable in the debugging tree.
- Cheap to implement: ~50 lines of Swift on each side plus a SwiftUI overlay banner. The expensive part is the manual testing matrix (kill QuipMac, sleep the Mac, drop Tailscale, lock the iPhone screen, background QuipiOS, etc.) — but each of those is a 30-second test once you have the heartbeat in place.

**Related:** #11 (window ID stability — the heartbeat's reconnect handler is the natural trigger point for option (b)'s "iPhone re-validates window list on reconnect" check), #12 (silent failure diagnostics — heartbeats are one half of "make failures visible"; error broadcast on dropped messages is the other half), #27 (idempotent message IDs — the structural follow-up that turns "detect dead connections" into "safely retry on reconnect").

---

### 21. Automated test suite — start with `MessageProtocol.swift` round-trip tests

**Status:** ✅ Done — shipped on `eb-branch` across 4 commits on 2026-04-15: `a0f69a9` (test target infrastructure fix), `fca32f9` (duplicate compilation removal), `9f09851` (move to Shared/Tests + QuipMacTests target), `97cff43` (new test coverage).

**Spec:** `docs/superpowers/specs/2026-04-15-protocol-round-trip-tests-design.md`
**Plan:** `docs/superpowers/plans/2026-04-15-protocol-round-trip-tests.md`

**Final state:**
- Tests now run on **both** platforms: `QuipiOSTests` (51 tests: 40 MessageProtocol + 11 PTTStress) and the brand-new `QuipMacTests` (40 MessageProtocol tests).
- Shared test file at `Shared/Tests/MessageProtocolTests.swift` with 40 test methods total (28 existing + 12 new).
- New coverage: `DuplicateWindowMessage`, `CloseWindowMessage`, `OutputDeltaMessage`, `TTSAudioMessage` (each with encoding + round-trip tests), `WindowState` backward-compat (`isThinking` and `folder` default cases), `LayoutUpdate.screenAspect` round-trip, `TerminalContentMessage.screenshot` round-trip, and four new cases in `testMessageTypeExtraction`.

**Side-quest: two pre-existing latent bugs closed as a side effect of #21.** During execution we discovered the existing 28 `MessageProtocolTests` + 11 `PTTStressTests` methods had *never* been runnable via `xcodebuild test` in the current Xcode 26.4 environment, because of two bugs hiding behind each other in a fail-fast chain:

1. **`QuipiOSTests` target was missing `GENERATE_INFOPLIST_FILE: YES`**, so the test bundle had no Info.plist and `codesign` refused it. This stopped the build before Swift compilation even started — which masked the second bug.
2. **The `@testable import QuipiOS` in both test files was wrong** — the iOS app target's Swift module is `Quip`, not `QuipiOS`, because `project.yml` sets `PRODUCT_NAME: Quip`. Should have been `@testable import Quip` from day one.

Both fixes landed in `a0f69a9`. The tests were compiled and committed but had been silent-dead — nobody ran them via the command line, and when Xcode GUI ran them it used a different code-signing path that hid the Info.plist issue. This confirms the wishlist entry's own original observation that Quip has always been "manually verify by tapping buttons."

**Also fixed during #21 execution:** the `QuipiOS` and `QuipMac` application targets were sourcing everything under `Shared/`, which post-#21 would have picked up `Shared/Tests/MessageProtocolTests.swift` and tried to compile it into the main app (which doesn't have XCTest). Added `excludes: ["Tests/**"]` to both app targets' `../Shared` source path. Landed in `9f09851`.

**Not yet done (follow-ups on the original "where to grow from there" section):**
- Handler-level tests with fake `KeystrokeInjector` and fake `WindowManager`
- iPhone-side ViewModel tests for `QuipApp.swift::sendAction`
- Cross-platform JSON key compatibility checks (currently only `testSortedKeysEncoding` covers a subset)

These should become their own wishlist items if/when they become priority. Leaving the original follow-up text below for reference.

**Original context** (kept for historical reference):
Every commit in this repo to date has been "build, install on physical device, manually verify by tapping buttons." That works for solo development but compounds: every new message type added to `Shared/MessageProtocol.swift` is an opportunity to ship the iPhone side without the matching Mac side (or vice versa) and silently drop messages until a feature breaks. Swift's exhaustive-switch checker catches some cases at compile time but not all — a JSON encoding/decoding round-trip mismatch (forgot a `CodingKey`, used non-standard naming) won't fail the build, only fail at runtime.

**Cheapest entry point:** unit tests that round-trip every message struct in `MessageProtocol.swift`. Encode an instance, decode it, assert structural equality. Roughly 30 minutes of work; catches an entire class of "I added a message on one side and forgot the other" bugs forever. Run on every Mac and iPhone build.

**Where to grow from there:**
- **Handler-level tests** with a fake `KeystrokeInjector` and fake `WindowManager`. Verifies `handleIncomingMessage(...)` dispatches correctly without iTerm or AppleScript or a physical iPhone. Catches every silent failure where a new message type was added to the protocol but the dispatch switch wasn't extended.
- **iPhone-side ViewModel tests** for `QuipApp.swift::sendAction`. Same shape — fake the WebSocket client, assert the right message type goes out for each `WindowAction`.
- **Integration tests stay manual.** Anything that touches AppleScript, Accessibility, or a real iPhone is hostile to CI and probably not worth automating until the codebase is much larger.

**Why this is structurally hard despite being the largest gap:** the interesting bugs in this codebase are at process boundaries (Mac ↔ iPhone, Quip ↔ iTerm, Quip ↔ macOS Accessibility), and unit tests of pure functions don't catch them. The pragmatic move is to test what you *can* test cheaply (protocol, handlers, view models) and accept that seam tests stay manual — but get a runbook (#26).

**Related:** #26 (diagnostic capture — same "make manual tests cheap to repeat / cheap to capture" theme).

---

### 22. Startup self-test for required macOS permissions

**Status:** Wishlist — high-priority reliability infrastructure
**Context:** QuipMac requires three macOS permissions: **Accessibility** (for `KeystrokeInjector`'s System Events keystroke injection), **Automation/AppleScript** (for `tell application "iTerm2"` window control), and **Local Network** (for the WebSocket discovery mechanism). macOS can revoke any of these at any time — after a system update, after a privacy panel reset, after a beta install, after Quip is rebuilt with a new bundle ID — and the app gets *no notification*. From the user's perspective, "everything was working yesterday" suddenly turns into silently dropped commands.

**Fix:** at QuipMac launch (and again after waking from sleep), probe each permission with a cheap dry-run:
- Accessibility: `AXIsProcessTrustedWithOptions([:])` returns false if not granted.
- Automation: try a no-op AppleScript like `tell application "iTerm2" to count windows` and catch `errAEEventNotPermitted (-1743)`.
- Local Network: try a 1-byte UDP send and catch `EPERM` if the entitlement was revoked.

If any probe fails, surface a **red status bar item** with the message "Quip can't reach <permission> — fix in System Settings → Privacy & Security" and a button that opens the relevant pane directly via `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` (and equivalents).

**Why this is high-leverage:** the failure mode it eliminates is the most demoralizing class of Quip bug — "it was working, now it isn't, no error, no log, no signal" — because the failure isn't in Quip's code at all, it's in OS-level permissions Quip depends on. Every other reliability fix on the wishlist assumes permissions are intact. Currently nothing checks.

**Related:** #12 (silent failure diagnostics — same "make failures visible" theme), #20 (WebSocket heartbeat — both detect external-state failures Quip itself can't fix, and both surface them visibly).

---

### 23. Race conditions in the just-shipped duplicate/close feature

**Status:** Wishlist — surfaced from review of recently-merged code
**Context:** The duplicate/close feature shipped in commits `44033ee → e37a9e9 → 564af08 → d9de9a6 → 75c2b95` (Tasks 1–5 of the iPhone tab management plan). The `KeystrokeInjector.spawnWindow` and `closeWindow` paths involve several async steps: AppleScript to iTerm, polling for the new window's CGWindowID, registering the window in `WindowManager`, broadcasting the new window list to the iPhone. Several plausible race conditions exist:

- **Spawn-then-immediately-close.** User taps Duplicate, then before the spawn AppleScript has finished running `claude` in the new window, taps Close on the *original*. The close runs, but `WindowManager` doesn't yet know about the (still-spawning) new window. The new window finishes spawning a moment later and shows up in the next broadcast. Probably benign but worth verifying that no zombie iTerm process is left behind.
- **Duplicate the same source three times in 2 seconds.** Each spawn races for a CGWindowID on the same iTerm2 process. iTerm2's window enumeration order isn't guaranteed under fast spawns — possible that one of the three new windows is missed entirely until the next refresh, or that two get confusingly similar identities briefly.
- **Close a window during a `pressReturn` keystroke that's targeting it.** If a quick action and Close fire in the same long-press flow, the keystroke could land in the wrong window because by the time `KeystrokeInjector` looks up the target, it's gone. Currently the lookup should silently no-op, but verify.

**Fix approach:** a stress-test pass with a manual matrix (three rapid duplicates, spawn-then-close, close mid-keystroke) before this code matures past two weeks old. If any of the races show real symptoms, capture them in their own wishlist items.

**Out of scope:** building automated tests for these races — see #21 about why integration tests stay manual.

**Related:** #13 (multi-iTerm2-window keystroke targeting — same "AppleScript window addressing is fragile under concurrency" theme).

---

### 24. Crash recovery for QuipMac via launchd LaunchAgent

**Status:** Wishlist
**Context:** If QuipMac crashes — and it does occasionally, per the ten-gigabyte memory leak fixed in commit `6599f02` — the iPhone has no recovery path. The user has to notice the phone has gone silent, walk to the Mac, manually relaunch Quip, and re-pair. There's no auto-restart.

**Fix:** ship a `~/Library/LaunchAgents/com.quip.QuipMac.plist` LaunchAgent with `KeepAlive=true` and `RunAtLoad=true`. macOS launchd will restart QuipMac within seconds of any crash, and it'll start automatically at login. The plist can be installed by Quip itself on first run (with a one-time user permission dialog) so it doesn't require manual setup.

**Design questions to resolve in brainstorming:**
- **Crash-loop guard.** If QuipMac is crashing immediately on launch (corrupted state, broken update, etc.), `KeepAlive=true` will respawn it forever and burn CPU. Use `KeepAlive={"SuccessfulExit":false,"Crashed":true}` plus `ThrottleInterval=30` so a crash-looping process gets a 30-second cooldown between attempts.
- **Opt-in vs default.** Some users won't want a background process auto-launched on every login. Make this an opt-in toggle in Settings ("Restart Quip if it crashes"), default off.
- **Signal-aware shutdown.** If the user explicitly quits QuipMac via Cmd+Q, launchd shouldn't restart it. The LaunchAgent's `KeepAlive` setting can distinguish clean exits from crashes via the `SuccessfulExit:false` discriminator.

**Related:** #20 (WebSocket heartbeat — together they form "if the Mac dies, the phone notices within 15s and the Mac restarts within 30s, total recovery time well under a minute without user intervention").

---

### 25. iTerm2-version smoke test against AppleScript verbs Quip depends on

**Status:** Wishlist — fragility check
**Context:** Most of QuipMac's interop with iTerm2 is via AppleScript verbs (`tell application "iTerm2"`, `current session`, `write text`, window IDs, session unique IDs). Any iTerm2 update can rename a verb, change a return type, shift session ID semantics, or remove a property — and Quip's calls will start failing silently. This is exactly the failure mode that bit commit `4006db4`'s window-by-CGWindowID matching attempt: iTerm2's `id of window` returns iTerm2's own internal integer, not a CGWindowID, and the assumption was wrong from the start.

**Fix:** ship a smoke-test target (separate Xcode scheme, runs in seconds) that exercises every AppleScript verb Quip depends on against the currently-installed iTerm2 and asserts the return shapes:
- `count windows of application "iTerm2"` returns an integer
- `get id of first window of application "iTerm2"` returns an integer (not a string, not a record)
- `get name of current session of first window of application "iTerm2"` returns a string
- `get unique id of current session of first window of application "iTerm2"` returns a string-formatted UUID
- ...and so on for every verb in `KeystrokeInjector.spawnWindow`, `closeWindow`, the keystroke path, and the window enumeration path.

Run this smoke test before every release of QuipMac, and (eventually) gate releases on it passing. The cost is one Xcode scheme and ~50 lines of test harness; the benefit is that every iTerm2 update gets caught in seconds instead of weeks of silent breakage.

**Why this matters more than it sounds:** iTerm2 is updated frequently (multiple beta releases per month), and the verbs QuipMac relies on aren't part of any "stable AppleScript API contract" — they're whatever the iTerm2 author shipped this version. The codebase has already lost time to one verb-shape mismatch (`4006db4`). A 50-line smoke test would have caught that in seconds.

**Related:** #13 (multi-iTerm2-window keystroke targeting — same brittleness root cause; the smoke test would catch the kind of shape mismatch that broke `4006db4`).

---

### 26. Diagnostic-capture ("share state") gesture on the iPhone

**Status:** Wishlist — observability infrastructure
**Context:** Today, when something doesn't work in Quip, the user notices on the phone but the relevant logs and state are on the Mac. By the time the user walks to the Mac, opens Console.app, filters by `process:Quip`, and finds the moment the failure happened, the state has often already changed. There's no way to capture "what Quip looked like at the moment the bug happened" as a single artifact.

**Fix:** add a **diagnostic-capture gesture** to the iPhone (probably three-finger long-press on the window list, or a hidden tap sequence in the Settings drawer) that snapshots:
- Last 200 lines of the iPhone's local log buffer
- Current WebSocket connection state (alive / dead / reconnecting, last successful message time)
- Current view of the Mac's window list (as the iPhone last saw it)
- Selected window ID
- Permission status the iPhone thinks the Mac has (from the last connection handshake)
- Quip iOS version, Mac version
- Timestamp

Bundle into a single JSON blob, save to `Documents/diagnostics/`, present a share sheet to AirDrop the file to the Mac. Optionally also fire a `RequestMacDiagnosticMessage` over the WebSocket so the Mac dumps its own state into the same bundle.

**Why this is force-multiplier infrastructure:** turns every bug report from "it didn't work" into "it didn't work and here's exactly what the system looked like." Direct enabler for #12 (silent failure diagnostics — the user can capture the moment of failure even when no error message was shown). Also unlocks the "send me a Quip diagnostic dump" loop with the repo owner during cross-machine debugging.

**Related:** #12 (silent failure diagnostics — this is the user-facing capture half; #12's recommendations are the developer-facing observability half), #21 (automated tests — diagnostic captures from real bug reports become test fixtures).

---

### 27. Idempotent message IDs + Mac-side dedupe table for safe retries

**Status:** Wishlist
**Depends on:** #20 (WebSocket heartbeat / dead-peer detection)
**Context:** Today, every message the iPhone sends to the Mac is fire-and-forget. There's no message ID, no acknowledgement, no dedupe. If the user double-taps a button (or if a network blip causes the iPhone to retry a send), the Mac will execute the action twice — duplicate spawns two iTerm windows, close fires two close commands, quick actions fire keystrokes twice. Today this is hidden because the iPhone never *intentionally* retries, but as soon as #20 (heartbeats) lands and retry-on-reconnect becomes possible, this becomes a real bug.

**Fix:** introduce a `messageId: UUID` field on every iPhone-originated message in `MessageProtocol.swift`. The Mac maintains a **dedupe table** of the last 100 message IDs (TTL 30 seconds). When a message arrives:
- New ID → process the message, add to table.
- Duplicate ID → ack with the original result, do nothing.

The table is in-memory only (lost on QuipMac restart, which is fine — by then the iPhone's retry window has long since passed).

**Design questions to resolve in brainstorming:**
- **Ack-required vs ack-optional.** Strict: every Mac-side handler returns an `AckMessage(messageId, result)` and the iPhone matches retries against pending messages it hasn't acked yet — the most correct version, unlocks at-least-once retry semantics. Lighter: just ID + dedupe, no ack — works for "user double-tapped" but doesn't unlock automatic retry-on-reconnect.
- **Table size and TTL.** 100 messages / 30 seconds is enough to cover any plausible "network blip caused a retry" window without bloating memory.
- **Backwards compatibility.** Old iPhone clients that don't send `messageId` should still work — treat missing-ID messages as "always process, never dedupe."

**Why this is required for #20 to be safely useful:** as soon as the iPhone has a heartbeat-driven reconnect loop, the natural next step is "if a send fails because the connection just died, queue it and retry on reconnect." But you can't safely retry a `duplicate_window` without the dedupe table — the message might have actually reached the Mac before the connection died, and the retry would create a second window. So #27 is the structural prerequisite that turns #20 from "detect dead connections" into "actually recover gracefully from them."

**Related:** #20 (WebSocket heartbeat — strict prerequisite; #27 has no value without #20).

---

### 28. Larger / higher-contrast option for the shortcut row buttons (esp. night mode)

**Status:** ✅ Partially done — contrast fix shipped in `eb-branch` (2026-04-15). Bumped the shortcut row button font from 9pt to 11pt (icons 11→13pt), weight from `.medium` to `.semibold`, text opacity from 0.7→0.9, background opacity from 0.1→0.15, and padding from 7×5→9×7. Much more visible in dark mode now. The full Settings-based size picker (Small/Medium/Large) is still wishlist for a future pass.

**Original context:**
The 1, 2, 3 quick-action buttons (added in jboert's commit `4e774e6`, tracked under #8) are reported to be too small to see comfortably, **particularly in night mode**. The user wants a way to make them larger — but without violating the compact UI rule that the rest of the layout follows by default. The night-mode angle is the most acute: in the dark UI scheme the buttons have lower visual contrast against the background, so even the tap target being correctly sized doesn't help if you can't see where to tap in dim ambient light.

**Two related but distinct fixes worth keeping on the table in brainstorming, because they address different real problems:**

1. **A button size option in Settings.** A toggle or three-way picker (Small / Medium / Large) in the existing Settings drawer (the one from commit `4e774e6`) that resizes the configurable shortcut row buttons. Default stays Small to honor the existing compact UI rule. Users opt in to larger buttons when they need them. This addresses the "I can't tap accurately" version of the problem — fat fingers, bumpy car ride, gloves on, one-handed reach.

2. **Higher contrast button styling in night mode.** The night-mode visibility issue is most likely driven by *contrast* more than *size*. iOS's dark mode tends to use subtle borders and low-saturation backgrounds, which makes small UI elements visually fade into the chrome around them. A higher-contrast button style specific to dark mode (brighter background, thicker border, more luminous glyph) would address the visibility complaint without resizing anything — and respect compact UI as a side effect. This addresses the "I can't see where to tap" version of the problem — low light, aging eyes, blue-light-filter-on, sunglasses.

**Why both belong in the same entry but ship as separate options:** size and contrast solve different accessibility needs and shouldn't be conflated. A user who has trouble seeing in dim light isn't necessarily helped by larger buttons (they still have low contrast, just bigger). A user who needs bigger tap targets isn't necessarily helped by higher contrast (they can see fine, they just need more area to hit). v1 should ship at least the contrast fix (cheapest, fixes the immediate complaint, doesn't disturb layout); the size picker is a follow-up that's more intrusive and needs more design.

**Design questions to resolve in brainstorming:**
- **Scope.** Does this apply to just the 1/2/3 row, or to the entire shortcut row jboert added in `4e774e6`, or to *every* button in the iPhone UI? The user reported it about the 1/2/3 specifically but the same problem likely applies to other small icon buttons (the chevrons, the keyboard toggle, the gear icon).
- **Setting placement.** New row in the existing Settings drawer, or a new "Accessibility" tab? Probably a row for v1 — don't introduce a new tab until there are multiple accessibility settings to put in it (Dynamic Type support, VoiceOver labels, reduce-motion, etc., would be the trigger).
- **Persistence.** `@AppStorage` same as `spawnCommand` from commit `d9de9a6`.
- **Light vs dark mode interaction.** Does the size picker apply to both modes equally, or should "Large" only auto-engage in dark mode? Auto-adapt is more delightful but more surprising — the user might not understand why their button suddenly got bigger when they walked into a dark room.
- **Dynamic Type.** iOS has a system-wide font size accessibility slider. Should Quip respect it (so the user configures size in one place — the system Settings — instead of duplicating the control inside Quip)? This is the most iOS-native option but requires the buttons to use scalable text/icon sizes today, which may not be the case. Worth investigating at spec time.

**Compatible with the existing compact UI rule:** the *default* behavior stays tight (small buttons, current layout). This entry adds an opt-in escape valve for users who need larger or higher-contrast buttons — it doesn't override the default. Worth flagging in the spec so future readers don't read this entry as overturning the compact UI preference.

**Related:** #8 (the 1/2/3 buttons in question — same row this would resize / restyle), #18 (context-aware 1/2/3 buttons — if those auto-show during a Claude prompt, they should also pick up the user's size + contrast preference automatically, not get re-styled separately).

---

### 29. Launch iTerm2 window from iPhone — project directory picker

**Status:** ✅ Done — shipped across commits `5b35c71`, `24fee2d`, `2320170` on `eb-branch` (2026-04-15). Implemented as a project-directory-based picker (simpler than the originally-specced iTerm2 profile approach). Mac broadcasts subdirectories of configured project roots to the iPhone via `ProjectDirectoriesMessage`. iPhone shows a "+" button (40pt, between chevrons and Push to Talk) that opens a sheet listing projects by folder name. Tapping one sends `SpawnWindowMessage`; Mac spawns iTerm in that dir with the configured spawn command, auto-enables the new window, broadcasts the updated layout, and auto-selects it on the phone.
**Depends on:** Partial plumbing exists from the recently-shipped Duplicate feature (commits `44033ee → 75c2b95` + jboert's `5e8a9db`), which already knows how to `spawn new iTerm2 window in a directory running <configurable command>`.
**Related:** #2 (add / close terminal tabs from the iPhone remote) — this entry sharpens #2 from *"open a new session"* to *"open a new session **in a specific project**"*. Could ship as a concrete implementation of #2's open-a-tab half, with #2 narrowing to just the close-a-tab half afterward.

**Context:** The user wants to pull up a specific project on the Mac from the iPhone app at any time, **even when Quip has zero existing Claude Code windows open**. This shifts Quip's usage model from *"remote control for already-running sessions"* to *"on-demand session spawner"* — a meaningful expansion in what the iPhone client can do.

**Design seed (user's pick at brainstorm time):** Use **iTerm2 profiles** as the canonical project list. The user already maintains named profiles in iTerm2's Preferences → Profiles panel, each with its own `Working Directory` and optional startup `Command`. Quip reads that list via AppleScript and presents each profile as a tappable item on the phone. Tap a profile → Mac runs `tell application "iTerm2" to create window with profile "<name>"` → iTerm2 spawns a window using whatever that profile has configured (cwd, startup command, color scheme, everything).

**Why iTerm2 profiles is the right source (versus the alternatives considered):**
- Zero config duplication — the user already curates this list in iTerm2 itself. Quip doesn't invent a new settings surface.
- Leverages iTerm2 features users already understand. A profile like `"Quip + claude"` can auto-run `claude`, a `"Quip + vim"` profile can auto-run `vim`, a bare shell profile can just open a shell — **per-project startup command comes free**.
- Works at any time because it doesn't depend on any existing window state — it only depends on the profile list, which is static configuration.
- Alternatives rejected: (a) a manually-curated list in iPhone Settings — boring, duplicates what iTerm2 already has. (b) auto-scanning `~/.claude/projects/` — works but picks up everything the user ever ran Claude against, including stale ones. (c) scanning `~/Projects/` — too generic, picks up folders that aren't Claude projects.

**Implementation sketch** (rough; for a real spec, brainstorm later):

1. **Protocol:** three new message types in `Shared/MessageProtocol.swift`:
   - `RequestProfileListMessage` — phone asks Mac for its current iTerm2 profile list.
   - `ProfileListMessage(profiles: [ProfileInfo])` — Mac → phone response, where `ProfileInfo` probably carries at least `{ name: String, workingDirectory: String?, command: String? }`. Fields beyond `name` are nice-to-have for UI display and optional for v1.
   - `LaunchProfileMessage(profileName: String)` — phone → Mac tap handler.

2. **Mac-side handlers** in `QuipMacApp.swift` (or `KeystrokeInjector` — whichever owns the existing Duplicate/Close AppleScript path):
   - On `RequestProfileListMessage`: run `tell application "iTerm2" to get profiles` (or `get names of profiles` depending on what iTerm2's current AppleScript dictionary exposes — verify at spec time), serialize into `[ProfileInfo]`, send back.
   - On `LaunchProfileMessage`: run `tell application "iTerm2" to create window with profile "<name>"`. Catch the error that iTerm2 throws if the profile was deleted between list-fetch and launch, and return a failure message to the phone rather than silently dropping.
   - Mac should proactively broadcast profile-list updates on startup + whenever the iTerm2 profile set changes. Change detection is hard without iTerm2 notifications — probably simpler to refetch on a timer or on-demand when the phone's UI pulls to refresh.

3. **iPhone UI surface** (design decision — pick one during brainstorming):
   - **New "Launch" button in the portrait control row.** Tap to open a modal sheet listing profiles. Fits the existing shortcut-button pattern.
   - **New entry in the Settings drawer gear menu.** Tuck it away as an overflow feature. Less discoverable but respects the compact-UI rule.
   - **Long-press gesture on empty space in the window list.** Cool but undiscoverable without a tutorial.
   - **A dedicated "projects" tab or segmented control** above the window list. Bigger footprint but gives the feature room to grow (could later include "recently launched," pinning, sorting).
   - User's instinct preferred during the /btw side conversation: leans toward making it discoverable and first-class, but exact surface left to brainstorm time.

4. **Respect the compact UI rule.** Whatever surface is chosen, default state should be tight. New controls use icons, fit into existing rows, prefer expansion toggles over fixed growth.

**Design questions to resolve in brainstorming:**
- **Profile list freshness.** How does the phone know when the iTerm2 profile set changed? Poll on pull-to-refresh? Refetch on every WebSocket reconnect? Have the Mac watch iTerm2's preferences file and push updates? The simplest answer is "refetch on pull-to-refresh and on reconnect" — only as fresh as the user's next interaction, which is probably fine for the kind of change frequency real-world iTerm2 profile lists exhibit (months between edits).
- **"Currently open" indicator.** If a profile has already been launched and has an active window, should the phone show a badge/indicator to avoid double-launching? Or is double-launching legitimate (two claude sessions on the same project)? Probably legitimate — don't prevent it. But maybe visually dim launched profiles as a hint.
- **Profile with no working directory or no startup command.** iTerm2 profiles can be minimal. If a profile has neither a working dir nor a startup command, launching it just opens a bare shell in the default home directory. Should Quip filter those out of the list, or show them as "Bare shell: <name>"? Probably show them but label them so the user knows what they'll get.
- **Profile ordering.** iTerm2 presents profiles in a user-configured order in its own UI. The AppleScript dictionary may or may not preserve that order when enumerating. If order isn't preserved, Quip needs its own sort (alphabetical? last-used? pinned?). Needs a quick experiment.
- **Cross-platform parity.** QuipLinux has its own terminal-spawning mechanism (ydotool/wtype on Wayland, xdotool on X11) that's not tied to iTerm2 at all. Should this feature exist on Linux at all, or is it iTerm2-only? If Linux parity is wanted, the "profile list" abstraction needs a Linux equivalent (maybe read `~/.config/quip/projects.toml` or similar). Probably **iTerm2-only for v1**, cross-platform as a follow-up.
- **Discoverability.** A tap-to-launch menu is the kind of feature users need to *know about* to use. First-launch tip? Marker in Settings drawer? Easily-missable if tucked away. Balance against compact UI.

**Non-goals (explicit) for the v1 this entry describes:**
- NOT a replacement for the existing Duplicate feature. Duplicate is `spawn a new window in the same folder as the active one`; this is `spawn a new window in a specific curated project`. Both should coexist.
- NOT cross-platform — iTerm2 only. QuipLinux and QuipAndroid stay unchanged for v1.
- NOT a full project manager — no creating profiles from the phone, no editing, no deletion. Read-only consumer of iTerm2's configured list.
- NOT a remote project launcher — only works when the phone is already paired with the Mac.

---

### 30. Reliability & UX hardening pass (5-thread backlog)

**Status:** Wishlist (brainstorm paused mid-flight on 2026-04-18 — backlogged)

**Context:** Brainstorming session started to explore what would make the app feel more trustworthy. User identified *silent correctness failures* (the app doesn't do what was asked, and nothing tells you it failed) as the #1 pain driver, and picked a weekend-budget appetite. Five threads were surfaced before the session was paused:

**Threads in scope:**

1. **Diagnostic tooling / observability.** CLAUDE.md already lists 7 distinct root causes for a single symptom (photo upload spinning forever). Silent `continue`, silent `try?`, and `guard let ... else { return }` paths cripple triage. The push-notification service just got loud-drop logging (commit `8517835`) as a prototype of the pattern — extend that discipline across the rest of the codebase. Inventory candidate files: `QuipMac/Services/*`, `QuipiOS/Services/*`, `Shared/*`.

2. **Connection truth / status pill honesty.** Commit `3431046` fixed the "pill was lyin'" keepalive-without-pong bug. Next round: surface *why* a disconnect happened, not just the binary. E.g., when the phone flips to "Not connected", it should say whether it was pong timeout, explicit close frame, network loss, or auth failure. Review probe cadence.

3. **State invariants across app lifecycle.** Audit what state persists across `willResignActive` / `didEnterBackground` / `willEnterForeground` / `didBecomeActive` on iOS and the equivalent on Mac. Known offenders: `isPTTActive` isn't reset on `HardwareButtonHandler.stopMonitoring`; Live Activity handles can outlive their activities if user dismisses from Dynamic Island long-press; `PreferencesSyncService.suppressUntil` uses a fixed 2s window that races with network latency; force-quit-after-install is required because `devicectl install` replaces the bundle but doesn't kill the process. Each is a one-line or few-line fix once identified.

4. **Error-handling gaps (silent failures).** Repo-wide audit of `try?`, `if let ... { } else { return }` with no log, empty `catch { }` blocks, and `guard` statements that swallow failures. Triage each: some are legitimately "don't care" (framework quirks), others are real bugs-in-waiting. Convert the real ones to either loud logs or typed errors.

5. **Notification triage in-app (originally bucketed as UX).** Today you have to `tail ~/Library/Logs/Quip/push.log` on the Mac to see why a push didn't fire. Surface recent push attempts + skip reasons in Mac Settings → Notifications. With the weekend budget, a stripped-down version is feasible: a `List` in SettingsView that reads the last N lines from `LogPaths.pushPath`. Anything fancier (structured events, iOS-side mirror) defers to a later iteration.

**Decisions already made in the paused session:**

- Shape picked: **A** — strategy-level spec covering all 5 threads + their sequencing, with separate implementation plans when each is executed. (B = one thread first, C = monster spec were alternatives.)
- Top pain: **A = silent correctness failures.**
- Appetite: **A = weekend / few evenings.** No new shared infrastructure. Ruthless audit + fix the worst offenders only.

**Paused at:** proposing concrete weekend shapes. Three options were on the table when user chose to backlog:

- **A. #1 + #4 together, deep** — observability + silent-error-handling share the same methodology (grep → triage → log or fix). One audit pass yields two threads. #3 gets a short appendix checklist. #2 and #5 defer to a second weekend.
- **B. Just #1 alone** — tightest single-weekend scope.
- **C. Shallow sweep across all 5** — one targeted fix per thread, 2-3 hours each. Maximum coverage, surface-level depth, high risk of "looks done but isn't."

**When picking this up:** resume brainstorming from that choice. Recommended starting point is **A** (#1 + #4 together) unless the user's constraints have shifted. If scope creeps beyond a weekend at brainstorming time, consider promoting to a multi-weekend plan with #1+#4 shipped first and the rest queued.

**Related:** commits `8517835` (push-service loud-drop logs as the pattern seed), `843fb68` (volume KVO guard — lifecycle-state example of thread #3), `3431046` (keepalive-pong fix — example of thread #2).

---

### 35. Cross-app paste from iPhone clipboard into Quip terminal

**Status:** Wishlist
**Context:** User wants to copy text from any iOS app (Safari, Mail, Messages, Notes, ChatGPT, etc.), switch to Quip, and paste it into the currently selected terminal — text gets piped to the Mac via WebSocket and typed into the active iTerm window. Today the iPhone has a text-input field for typed/dictated input but no obvious paste affordance.

**Likely shape:**
- A paste button (clipboard icon) inline next to the existing text-input bar OR in the QuickButton row.
- Tapping reads `UIPasteboard.general.string`, sends it via the existing `SendTextMessage` (no new protocol needed), with `pressReturn: false` so the user can review before submitting.
- Long-press on the paste button could surface options (paste with return, paste raw multi-line, paste as `cat << EOF` heredoc for multi-line code blocks).
- Visual feedback on tap: brief "Pasted N chars" toast or button flash.

**Open questions for /prd time:**
- Paste size cap — iOS clipboard can hold MBs; cap at e.g. 32KB for terminal sanity?
- Multi-line paste handling — does Mac inject as one chunk via `write text`, or line-by-line?
- Dedicated UI affordance vs. invoke via long-press on the existing input bar?
- Do we want the inverse direction too (copy terminal selection → iPhone clipboard)?

**Related:** Existing `SendTextMessage` protocol path (`Shared/MessageProtocol.swift`); existing `keystrokeInjector.sendText` on Mac side; existing dictation/text-input UI in `portraitControls`.

---

### 34. iPhone Quip never receives `mac_permissions` despite Mac broadcasting it

**Status:** In Progress (debugging stuck) — eb-branch local
**Context:** During the autonomous burn-down of #33 we discovered the iPhone Quip app's "Mac Permissions" SettingsSheet section is permanently stuck on "Waiting for Mac…". Captured iOS device console (`xcrun devicectl device process launch --console`) shows iOS receives `auth_result`, `layout_update`, and `project_directories` over WebSocket every ~2s — but **never** receives `mac_permissions`. A parallel Node.js fake-iOS-client (`/tmp/perms-watcher.js` style) connecting to the same Mac WebSocket with the same PIN consistently receives `mac_permissions acc=true ae=true sr=true` within ~22ms of auth. So the broadcast IS going out (proven via Node) but the iPhone specifically isn't seeing it.

**What's been verified:**
- Build binary HAS `case "mac_permissions":` in `WebSocketClient.swift:498` (confirmed via `nm` + `strings` on the installed `Quip.debug.dylib`).
- iOS dispatch trace (NSLog at top of `handleMessage`) — never fires for `mac_permissions`. `[ws-trace] received type=mac_permissions` would appear if iOS even saw the type. It doesn't.
- iOS receives other broadcast types fine (`layout_update`, `project_directories` flow constantly from the same `webSocketServer.broadcast(_:)` Mac-side function).
- Mac's `broadcastPermissions(force:true)` fires on every `onClientAuthenticated` callback. Both Node and iPhone clients should be in the `clients[]` array at that moment, both auth'd. Yet only Node sees the message.

**Suspected root causes (not yet narrowed):**
1. Backpressure check in Mac's `broadcast(_:)` (`pendingBytes + payloadSize > maxPendingBytes` at `WebSocketServer.swift:~250`) silently drops the broadcast for the iPhone client only — possible if a stale TTS audio chunk or screenshot send completion never fires for the iPhone connection, accumulating `pendingBytes` past 2MB. But layout_update would also be dropped under that theory and it isn't.
2. NWConnection-level frame fragmentation specific to LAN clients (iPhone is on `192.168.4.34` over WiFi; Node listener is on `localhost`). Apple's WebSocket implementation may handle frame ordering / queueing differently for the two transports.
3. The iOS app's WebSocket task queue silently drops messages received during a specific moment of the auth flow — perhaps `mac_permissions` arrives in the same TCP receive buffer as `auth_result` and gets eaten during the "first message marks connected" branch in `receiveNext()` (`WebSocketClient.swift:373-388`).

**Diagnostic infrastructure built (uncommitted, removed before commit):**
- `/tmp/perms-watcher.js` — long-lived Node WebSocket fake-client that prints every `mac_permissions` it receives.
- `/tmp/quip-content-probe.js` — one-shot probe that auths + requests terminal_content for a given window name.
- NSLog `[ws-trace]` at top of `handleMessage` and `[mac_perms-debug]` in dispatch + handler.

**Next steps when resuming:**
1. Add per-client logging on Mac side inside `webSocketServer.broadcast(_:)` — log payload type + per-client decision (auth'd? skipped due to pendingBytes? sent? completion fired?). Write to `/tmp/quip-broadcast.log`. This makes the broadcast path observable from the Mac terminal without requiring iOS console capture.
2. Run with both Node listener and iPhone connected, verify which clients get which messages.
3. If pendingBytes is the culprit, investigate why the iPhone connection accumulates without completion.
4. If it's NWConnection-specific, file an Apple Feedback or work around with explicit per-message delivery confirmation.

**Workaround idea worth trying first:** add a periodic mac_permissions re-broadcast every 30s with `force=true` (not just on snapshot change). If the iPhone misses the auth-time broadcast for any reason, the next periodic one would catch it.

**Related:** Discovered while burning down #33's autonomous half. Mac binary on disk at `/Applications/Quip.app` (CDHash `c2d7ce61...`). Latest iOS bundle on phone (databaseSequenceNumber 7612) has `[ws-trace]` instrumentation removed.

---

### 33. Mac perms feature — verify all sub-flows in production

**Status:** Partially verified (autonomous). Manual checklist below pending user.

**Autonomously verified (this session):** Connected a fake-iOS-client (Node WebSocket) to the Mac, authed with the saved PIN, observed that Mac broadcasts `mac_permissions accessibility=true appleEvents=true screenRecording=true` within ~22ms of auth — the auth-time `force=true` broadcast path is correct, the on-disk Mac binary is sending what Phase 1 designed.

**Pending user (state-change sub-flows + visual confirmation):**
- Revoke a perm in System Settings → phone strip flips red within 5s, gear-icon red dot appears, Dynamic Island shows triangle + count
- Tap a red row in iOS SettingsSheet → matching System Settings pane opens on Mac (test all three: Accessibility, Automation, Screen Recording)
- Tap Dynamic Island banner from Quip-backgrounded state → Quip launches via `quip://perms` deep link → SettingsSheet opens on the Mac Permissions section
- Mac UI Settings → General → Permissions: tap Grant on a denied row → matching pane opens; flip green within 3s of granting (TimelineView refresh)
- Live Activities toggle in Quip iOS Settings: turning OFF kills any active perms LA + suppresses new ones; turning ON spawns one if degraded

Skipped autonomous TCC revoke (would force user re-grant — explicitly painful per their saved feedback). Trusting the broadcast pipe verification + Phase 1's prior all-green test until the manual run-through.

**Related:** commits `0f3a0be`, `90e8e1a`, `59cfb3a`. PR https://github.com/jboert/Quip/pull/6.

---

## Completed

### 37. PTT in-press pause wipes prior transcription

**Status:** ✅ Done — verified on device with 3-utterance trace.

Root cause: SFSpeechRecognizer on-device silently rolls over partial results mid-task when the speaker pauses — no `isFinal` fires, `bestTranscription.formattedString` just restarts. `AudioWorker` committed to `accumulatedText` only on `isFinal`, so `SeamStitcher.stitch(old: "", new: "Second")` replaced the pre-pause words with just the post-pause ones.

Captured from device console (print→stdout via `devicectl --console`) on 2026-04-24 15:40:

```
text='First sentence' accum='' combined='First sentence'
text='First sentence' accum='' combined='First sentence'    ← pause
text='Second'         accum='' combined='Second'            ← rollover
text='Second sentence' accum='' combined='Second sentence'
```

Fix: added `RecognizerRollover.detects(previous:current:)` + per-task `lastPartialText` high-water mark. When a partial is shorter AND its first token (case-insensitive) doesn't match the previous high-water mark's first token, commit `lastPartialText` into `accumulatedText` before stitching. Reset `lastPartialText` on task restart + session start.

Device verify — 3 utterances × 2 pauses: "First sentence" + pause + "Second sentence" + pause + "First sentence" → phone shows "First sentence Second sentence First sentence". ✓

**Diagnostic trail worth keeping:** `NSLog %{public}@` was still landing as `<private>` on this device (iOS 17/18 unified-logging redaction), and `os.Logger` with `privacy: .public` didn't reach `devicectl --console` because that only captures stdout. Only `print()` survived the chain. Kept the integer-only NSLogs in SpeechService + WebSocketClient (path flags, guard-failure tags, transcript arrival) since they provably reached the capture without leaking string content.

**Related:** commit `eacca48`. Tests: `QuipiOS/Tests/RecognizerRolloverTests.swift` (8 cases — observed sequence, refinement, identical, empty previous/current, same-first-token-shorter, different-first-token-longer, case-insensitive).

---

### 36. Allow more vertical scrolling in iPhone `InlineTerminalContent` (issue #7) — rolled back, scope mismatch

**Status:** ⏪ Reverted. Shipped `c5416e2` as "zoom the screenshot + pan around it," reverted in `cfcfb6c` after device testing. User's actual ask is **iTerm scrollback navigation** — see lines that scrolled off the top on the Mac — not panning around the current screenshot. The zoom-and-pan mechanic solved a problem the user didn't have ("it just lets me move the window around... I don't want to do that"). Issue #7 reopened with corrected scope; the real implementation is tracked as §38 below.

Lessons worth keeping in the next attempt:
- `ContentZoomLevel.widthFraction` is still dead code — nothing reads it. If zoom gets repurposed in the future, re-verify before assuming it's wired.
- Raw @AppStorage values 0/1/2 are persisted; case renames are free, semantics changes are NOT (old values still point at the same ordinal).
- `GeometryReader { ScrollView { ... } }` works; `ScrollView { GeometryReader { ... } }` does not (GR has no intrinsic height inside a ScrollView).

**Related:** commits `c5416e2` (fix), `542aff9` (wishlist Done — now stale), `cfcfb6c` (revert). Issue https://github.com/jboert/Quip/issues/7.

---

### 38. iTerm scrollback navigation from the iPhone

**Status:** Wishlist (replaces the misread half of #7).
**Context:** User wants to pan up/down on the iPhone terminal panel to reveal lines that have already scrolled off the visible iTerm window on the Mac — not to pan around a zoomed screenshot. Today the Mac captures only the visible viewport of the selected window; anything in iTerm's scrollback is invisible to the phone.

**Likely shape:**
- New `scroll_event` message in `Shared/MessageProtocol.swift`: `{ sessionId, windowId, direction: .up|.down, lines: Int }`.
- Phone: vertical drag on `InlineTerminalContent` image branch → throttled `scroll_event` per ~20pt of drag travel. Release = stop. Momentum scroll optional. Keep the existing swipe-to-cycle-windows gesture (currently guarded by 2:1 horizontal-to-vertical dx/dy ratio) intact — a pure-vertical drag is unambiguous scroll.
- Mac: on `scroll_event`, post `CGEventScrollWheel` targeted at the iTerm window (or AppleScript `tell iTerm2 to scroll` if available — AppleScript is more reliable across iTerm versions, CG is lower-level). Scroll by `lines × 1 line`. Screenshot loop already re-captures every 2s, so the new viewport flows back naturally; could also force a capture on scroll_event for snap responsiveness.
- Add a small "scrolled up by N lines" indicator on phone + a snap-to-bottom button (arrow-down icon in header) so users can get back to the live prompt with one tap.

**Open questions for /prd time:**
- Gesture: plain vertical drag (competes with swipe-cycle's perpendicular guard) vs explicit two-finger drag vs dedicated scroll thumb on the right edge of the panel?
- iTerm vs CGEventScrollWheel: iTerm AppleScript exposes `scroll horizontally by N lines` but not a clean "up N lines" verb; may need to send scroll-wheel CGEvents.
- Keyboard: should Cmd+Shift+Up / Cmd+Shift+Down (iTerm's built-in scrollback bindings) work instead? Simpler, but they're window-relative, so need focus on the right window.
- How to handle the "no more scrollback" edge — do we report back? Or let phone just stop showing new content?
- Parity: landscape `TerminalContentOverlay` is currently a stub, but a future full-screen variant should wire the same gesture.

**Related:** `QuipiOS/QuipApp.swift:~2892` (image branch — where the gesture attaches), `QuipiOS/Services/WebSocketClient.swift` + `Shared/MessageProtocol.swift` (new message), Mac-side `keystrokeInjector` / whatever owns CGEvent posting. Reopened from https://github.com/jboert/Quip/issues/7.

---

### 31. iOS terminal URLs aren't tappable

**Status:** ✅ Done — root cause was `.foregroundStyle(.white.opacity(0.85))` on the SwiftUI `Text` overriding the per-run colors set by the `.link` AttributedString runs AND interfering with link-tap recognition. Fix: bake the foreground color into the `AttributedString` itself in `linkifiedTerminalContent` (`attr.foregroundColor = .white.opacity(0.85)`), set link runs to `.cyan` for visual differentiation, and drop the `.foregroundStyle` modifier from the `Text` view.

Diagnosed autonomously via a Node.js fake-iOS-client (`/tmp/quip-content-probe.js`) that auths to the Mac WebSocket, requests terminal content, dumps the raw bytes, and a standalone Swift script (`/tmp/test-linkifier.swift`) that runs the exact `linkifiedTerminalContent` logic against those bytes. That confirmed `raw=6 kept=2` — the linkifier was working correctly all along; the bug was further down the SwiftUI render chain. The earlier "Case B" report was a misread caused by the user testing when no http(s) URLs happened to be in the visible iTerm buffer at that moment.

**Related:** commits `d3bf4c9` (initial linkifier), `b5bb8d7` (scheme filter + tests), `03ebfc9` (the gesture-routing fix).

### 32. `mailto:` link support in terminal content

**Status:** ✅ Done — extended the scheme filter in `linkifiedTerminalContent` to accept `mailto:` substring matches AND any URL whose `scheme` is "mailto" (NSDataDetector returns bare emails like `noreply@anthropic.com` as `mailto:noreply@anthropic.com` URLs natively, so both cases are covered). Two new unit tests: bare-email-as-mailto + explicit-mailto-uri. Tap pops the system Mail compose sheet via the standard URL handler.

---

### 39. Auto-arrange phone windows on open + manual realign button

**Status:** Wishlist (run `/prd` to shape the chooser before coding).
**Context:** When the iPhone Quip app opens and the windows list arrives from the Mac, cards land at the Mac's raw frame fractions. With ≥3 windows on a wide Mac display, the phone preview reads as cramped/overlapping rectangles even though the Mac arrangement is fine. User wants a sensible default phone-side layout to kick in automatically, plus a button to re-run it ("realign") whenever the auto-pick stops feeling right.

**Likely shape:**
- New default for `phoneLayoutOverride` (currently `nil` = use Mac's frames). On first non-empty windows snapshot per session, set it to a chooser-picked value (`"horizontal"` for ≤3 windows wide-orientation, `"vertical"` otherwise — exact heuristic TBD).
- Add a "realign" button in the header — distinct from the existing arrange tri-state cycle button. Realign re-invokes the chooser; cycle keeps its current "step through modes" behavior. Or unify them — open question.
- Persist last-used override per device count? Or reset every cold launch? `/prd` decides.
- Likely needs a third layout mode: `"grid"` for 4+ windows (today only `horizontal` and `vertical` are wired in `phoneLayoutFrame` at QuipiOS/QuipApp.swift:2105).

**Open questions for /prd:**
- Auto-pick on every windows-list change, or only first one per session? (Latter avoids flicker when Mac side adds a window mid-session.)
- Should the override be remembered across launches (`@AppStorage`) or always re-derived?
- Does "realign" reset to the chooser pick, or open a chooser sheet (horizontal / vertical / grid / off)?
- Interaction with §40 (drag-to-move): does realigning wipe per-window manual positions?

**Related:** `QuipiOS/QuipApp.swift:655` (`phoneLayoutOverride` state), `:1526` (existing arrange-button cycle), `:2105` (`phoneLayoutFrame` chooser).

---

### 40. Drag-to-move windows on the iPhone layout

**Status:** Wishlist (run `/prd` to lock semantics — phone-only vs Mac-mirror — before coding).
**Context:** User wants to grab a window card on the iPhone preview and drop it somewhere else. Today every card's position comes from `phoneLayoutFrame` (auto-arrange override) or `window.frame` (Mac's raw frame). There's no per-window phone-side override, no drag gesture on `WindowRectangle`, no conflict resolution between dragged positions and auto-arrange.

**Likely shape:**
- New `@State` (or `@AppStorage` keyed by Mac UUID + windowId) `phoneFrameOverrides: [String: WindowFrame]`. Drag-end writes here; lookup in `windowLayout` ForEach checks it before `phoneLayoutFrame` and Mac frame.
- DragGesture on the `WindowRectangle` view at QuipiOS/QuipApp.swift:2039. Translate fingertip delta into normalized fraction of the host-screen rect.
- Snap behavior: free-drop, snap-to-grid (1/2 / 1/3 thirds), or swap-with-target-on-overlap. Last is most "discoverable for resizing the layout" but most code.
- Visual feedback during drag: lift shadow, ghost the original position, target highlight if swap mode.
- Coexistence with §39 auto-arrange: dragging clears the override mode (so user gets the manual frame instead of the auto pick) — or auto-arrange treats overridden windows as fixed and arranges the rest around them. Open Q.
- Mac mirroring: does dragging on the phone also reposition the Mac window via AppleScript, or is this purely a phone-side preview tweak? `/prd` call.

**Open questions for /prd:**
- Phone-only preview, or mirror to Mac (heavier; needs Mac-side `set bounds of window` + reflow)?
- Snap mode: free / grid / swap?
- Resize-with-drag too, or just move? (Today Mac sets size; phone never resizes anything.)
- How does this interact with §39's "realign" button — does realign wipe overrides or honor them?
- What about cross-display moves on the Mac? Phone has no notion of multiple displays in the layout view.

**Related:** `QuipiOS/QuipApp.swift:2036` (`ForEach` placing `WindowRectangle`), `:2105` (`phoneLayoutFrame`), `:2119` (`windowRect` — coord conversion); `Shared/MessageProtocol.swift` (would need a new `set_window_frame` message if Mac mirroring is in scope).

---

### 41. Volume-button KVO must not clobber other-app audio (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `1f5254c` (2026-04-26). Bug: opening Quip while YouTube/Spotify/etc. was playing slammed system volume to 0.5, "shooting up" any app with a lower-set volume.

**What shipped:** `HardwareButtonHandler.startMonitoring` and `resumeAfterBackground` now call `primeRailIfNeeded(session:)` instead of unconditionally `setVolume(0.5)`. The helper reads `session.outputVolume`; if it's already in (0.0625, 0.9375) — i.e. button-press detection has headroom both directions — `savedVolume` is set to the user's actual level and the system volume is left alone. Only at the rails (≤0.0625 or ≥0.9375) does Quip nudge to the rail value so KVO can see motion.

**Acceptance test:** Play YouTube at ~30 % volume, foreground Quip → volume stays at 30 %. Press volume up/down → cycle/PTT works, returns to 30 % after.

**Related:** `QuipiOS/Services/HardwareButtonHandler.swift:62-81,158-176`.

---

### 42. Hardening audit 2026-04-26 — backlog (🟡 GitHub-tracked)

**Status:** Filed as GitHub issues `jboert/Quip#10`–`#26` under label `audit-2026-04`. This wishlist entry is the index — the per-item detail lives in the issues. Tracker: [#26](https://github.com/jboert/Quip/issues/26).

**Grades:** iOS security C+, iOS code quality A−, Mac security C, Mac robustness B+, build/signing B−, protocol design B+, repo hygiene B+, tests B−, docs B. **Overall B−.**

**Critical (transport + sandboxing):**
- §A `#10` — Re-enable TLS pinning in `WebSocketClient.swift:312-314`. Verify Cloudflare SPKI hashes first.
- §B `#11` — Replace `NSAllowsArbitraryLoads: true` (`QuipiOS/project.yml:79`) with `NSExceptionDomains` allow-list (trycloudflare.com + `NSAllowsLocalNetworking`).
- §C `#12` — Enable `com.apple.security.app-sandbox` in `QuipMac.entitlements`. Will trigger TCC re-prompts (Accessibility, Screen Recording) — schedule for a maintenance window.
- §D `#13` — `ENABLE_HARDENED_RUNTIME: true` + `DEVELOPMENT_TEAM: D2PM6R797Q` in `QuipMac/project.yml`. Without these, notarization is impossible.

**High (credentials + protocol):**
- `#14` — Migrate Mac PIN from UserDefaults plaintext to Keychain (`PINManager.swift`); raise to 8+ alphanumeric.
- `#15` — Audit `CloudflareTunnel.swift:80` Process spawn for `sh -c` shell injection; switch to argv array.
- `#16` — Remove the 37 MB `cloudflared` Mach-O binary from git; fetch + checksum-verify in build script.
- `#17` — Add per-message HMAC-SHA256 over WS (HKDF from PIN + nonces). Closes the post-auth-trust gap.

**Medium (correctness + ops):**
- `#18` — Idempotency keys (`requestId: UUID`) on `SendTextMessage` + `ImageUploadMessage`. Reconnect retries currently double-paste.
- `#19` — Mac→iOS app-level heartbeat (5 s). Today only iOS pings; Mac crash leaves iOS in stale "connected" for ~13 s.
- `#20` — Tighten message types: `arrange_windows.layout` → enum; consistent `(try? c.decode(...)) ?? nil` for optional fields.
- `#21` — Lock `requireAuth` in `WebSocketServer.swift:27` (currently `nonisolated(unsafe)` — main writes, network queue reads).
- `#22` — Move APNs `keyId` / `teamId` / `bundleId` from UserDefaults to Keychain (private key already there).
- `#23` — Add CI: `xcodebuild test` for QuipiOS + QuipMac, `cargo test` for QuipLinux.
- `#24` — Test gaps: WebSocket auth handshake, Mac message-handler dispatch, Bonjour discovery.

**Low:**
- `#25` — Expand `docs/protocol.md`: heartbeat, idempotency, Bonjour TXT, error envelope, "adding a new message" checklist.

**Already shipped from this audit (commit `b6a8498`, eb-branch):**
- `WebSocketServer.swift:375` — PIN values redacted from `/tmp` debug log (lengths only).
- `HardwareButtonHandler.swift:76,174` — empty audio-session catches now `NSLog` the error.
- `.gitignore` — `*.profraw` / `*.profdata` ignored.

**Wins worth not breaking:**
- `ImageUploadHandler.swift:13-71` — symlink resolution + prefix check + atomic write.
- `WebSocketServer.swift:87,262-265` — two-layer 16 MiB cap (NWProtocolWebSocket + app-level guard).
- iOS concurrency discipline: `@MainActor`, consistent `[weak self]`, `@ObservationIgnored` on background buffers.

**Order of attack (suggested):**
1. `#16` (cloudflared binary) and `#23` (CI) — pure ops, no runtime risk.
2. `#15` (shell-injection check) — cheap investigation, may close as no-op.
3. `#14` + `#22` (Keychain migrations) — one-shot, reversible.
4. `#13` (team + hardened runtime) — flips one knob, blocks notarization until done.
5. `#10` + `#11` together (transport hardening) — verify pins first, ship as one PR.
6. `#12` (sandbox) — last because it's the TCC-prompting one.
7. Protocol items (`#17`, `#18`, `#19`, `#20`) — bump protocol version once, ship together.

---

### 43. Custom quick-buttons editor + reorderable slot row (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commits `2ef5f6b` (UI tightening: same-letter slash grouping `/c…`, Notifications dropdown, keystroke-pill collision fix), `498a29d` (remove dedicated `/plan` quick button), `9283a69` (custom buttons + slot editor, v1.4.0). Installed on iPhone 17 Pro Max.

**What shipped:**
- Quick-button row goes from fixed 3-cluster layout (slash | answers | keystrokes) to a flat user-controlled ordered list, Apple-toolbar-style.
- `Settings → Quick Buttons` editor: drag handle to reorder, swipe to delete, "+" toolbar menu adds Built-in / Custom / Spacer.
- Custom-button form: label + optional SF Symbol + payload (Slash / Raw text / Keystroke) + auto-submit toggle.
- Spacers (12pt fixed) for grouping between slots; user can stack multiples for wider gaps.
- Same-letter slash grouping (`/c…` Menu pill) now spans built-ins + custom slash buttons.

**Persistence:**
- `quickSlotsJSON` (@AppStorage) — JSON-encoded `[QuickSlot]`, source of truth for the row.
- `customButtonsJSON` (@AppStorage) — JSON-encoded `[CustomButton]` definitions referenced by UUID.
- Legacy `enabledQuickButtons` CSV kept in sync with the slot list's built-ins for downgrade safety.
- One-shot CSV→JSON migration on first launch in v1.4.0 — preserves existing order, auto-inserts spacers at category transitions so the upgraded row matches the old auto-cluster layout.
- `PreferencesSnapshot` extended with `quickSlotsJSON` + `customButtonsJSON` so the slot list and definitions survive reinstall via the existing Mac WebSocket + iCloud KVS sync path.

**Implementation notes:**
- `QuickSlot` and `CustomPayload` use hand-rolled `Codable` because Swift's automatic synthesis fails for these enums under our build settings (`SWIFT_STRICT_CONCURRENCY=minimal`). Wire format is `kind` discriminator + per-case payload fields — adding a new case won't break decoding of older JSON.
- Cascade-delete: removing a custom definition prunes any slots referencing its UUID in the same persist cycle.
- The dedicated `/plan` built-in quick button was removed (`498a29d`) in favor of users defining their own custom button if they want one. `Shift+Tab` remains as a manual mode-cycle.

**Acceptance test:** Settings → Quick Buttons → "+" → Custom Button → label "/btw", payload Slash `/btw `, auto-submit off → Save → row shows `/btw` pill → tap fires the slash text into Claude. Drag a Spacer between two pills → 12pt gap appears in the row. Reinstall the app via `devicectl` → editor reopens with the same slots + custom defs.

**Related:** `QuipiOS/QuipApp.swift` (QuickSlot, CustomButton, QuickButtonsSheet, CustomButtonForm), `QuipiOS/Services/PreferencesSyncService.swift`, `Shared/MessageProtocol.swift:502+`.

---

### 44. iOS WS resilience — NWPathMonitor + stall watchdog + Reset button (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `64a8376`. Installed on iPhone 17 Pro Max. Confirmed working by user 2026-05-03.

**What shipped (`QuipiOS/Services/WebSocketClient.swift`, `BackendConnectionManager.swift`, `QuipApp.swift`):**

1. **`NWPathMonitor` auto-reconnect.** When the OS reports the network path becomes satisfied (WiFi roam, VPN flap, brief offline → back online), if we're disconnected and not intentionally torn down, the client cancels its pending exponential-backoff sleep, resets `reconnectDelay` to 1s, and calls `establishConnection()` immediately. `URLSessionWebSocketTask` does not surface OS-level path events, so the client previously sat in its 10s backoff sleep until the user nudged it.

2. **Stall watchdog (`stuckWatchdogTask`).** Wakes every 5s. If `isConnecting == true` for more than 25s (`stuckThresholdSec`) without progress, sets `lastError = "Stalled <n>s — resetting"` and force-runs `handleDisconnect()` to start over. Belt-and-suspenders for the rare case where `URLSession`'s pingHandler never fires *and* the 8s `connectionTimeoutTask` somehow doesn't trip — the previous code had no escape hatch from that zombie state.

3. **One-tap Reset button.** Connection bar gains an `arrow.clockwise.circle` button next to the X, visible only when `!client.isConnected && client.serverURL != nil`. Tap = `disconnect() + connect(serverURL)`. Replaces the "force-quit Quip from app switcher" recovery path.

4. **Diagnostic ring buffer (`connectionEvents: [String]`, last 30 entries).** Every lifecycle transition (connect, ping success/fail, keepalive miss, disconnect, watchdog trip, NWPath state change) appends a timestamped line. Exposed via `recentConnectionEvents` for an in-app diag panel — UI not built yet, ring buffer is in place.

5. **Keepalive miss surfaces to UI.** Each missed pong now sets `lastError = "No pong (1/2)"` then `(2/2)` so the existing red text under the status bar acts as a live socket-health indicator. No new UI plumbing.

6. **`teardownDiagnostics()`** — `BackendConnectionManager.forget()` now calls this to cancel the `NWPathMonitor` and stop the watchdog `Task` cleanly when a paired backend is removed, preventing per-pruned-backend leaks of background subscribers.

**Worst-case detection times before → after:**
- Network blip / WiFi roam: until next user action → ~immediate (NWPath kick).
- Zombie URLSession (no callback): forever → ≤30s (watchdog 5s tick + 25s threshold).
- Keepalive one-sided drop: ~26s → ~26s (unchanged; previously silent, now visible via "No pong (n/2)").
- App foreground after suspend: ~2s probe (unchanged; existing `resumeFromBackground`).

**Acceptance test:**
- Toggle WiFi off then on with the Quip app open → bar should auto-reconnect within ~1s of WiFi returning, no manual Reset tap needed.
- `pkill Quip` on the Mac with the iPhone connected → bar shows `No pong (1/2)`, then `(2/2)`, then begins reconnect attempts. After Mac restart, NWPath is unaffected so reconnect waits on the normal exponential backoff.
- If the bar is ever stuck on "Connecting…" >25s, watchdog should auto-tear-down and re-establish; the new Reset button is the manual override.

**Open follow-ups:**
- Build an in-app "Connection diagnostics" panel that renders `client.recentConnectionEvents` (last 30 timestamped lifecycle lines). Likely under Settings → Network. Useful for users who ask "what happened just now?" without needing a Mac for log capture.
- Add a Mac-side counterpart for the Cloudflare tunnel — same NWPathMonitor + watchdog idea on `CloudflareTunnel.swift`.

**Related:** `QuipiOS/Services/WebSocketClient.swift` (init, startPathMonitor, startStuckWatchdog, logEvent, teardownDiagnostics), `QuipiOS/Services/BackendConnectionManager.swift` (forget), `QuipiOS/QuipApp.swift` (connection-bar Reset button).

---

### 45. Mac CloudflareTunnel: NWPathMonitor + stall watchdog parity (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `352be75`. Built clean against macOS scheme.

**Why:** Mirror the iOS WS resilience (§44 / `64a8376`) onto the Mac's tunnel. Same root failure: a network-path flap (Wi-Fi roam, ethernet unplug, VPN flap) leaves cloudflared running but with stranded edge connections. The fixed timers (1s URL poll, 60s health check, 3s post-death restart) catch process death only — they don't notice "alive but no edge."

**What shipped (`QuipMac/Services/CloudflareTunnel.swift`):**

1. `NWPathMonitor` — on path-satisfied, if `isRunning && publicURL.isEmpty`, force a tunnel restart instead of waiting for the next minute-long health-check tick.
2. `stuckWatchdogTimer` — 5s tick. If the in-flight `start()` has been running >30s without resolving `publicURL`, kill cloudflared and restart. Edge resolution should take 1-3s in steady state; 30s means something is wedged.
3. `connectionEvents` ring (last 30 timestamped lifecycle lines, exposed as `recentConnectionEvents`). Feeds §48 (menubar last-event indicator).
4. `restartTunnel()` helper unifies path-monitor and watchdog recovery paths; `teardownDiagnostics()` lets `stop()` clean both subscribers.
5. `logEvent()` is `internal` (not `private`) so tests can drive the ring buffer without spinning up cloudflared.

**Acceptance test:** Toggle Wi-Fi off then on with Quip Mac running → menubar tunnel row should show "resolving…" briefly, then green + URL within ~1s of network coming back. Without this commit, the same toggle would leave the tunnel dead until the next 60s health check or process death.

**Related:** `QuipMac/Services/CloudflareTunnel.swift:32-40,140-260` (new fields + helpers + lifecycle).

---

### 46. iOS Connection diagnostics panel (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `6668893`.

**Why:** `WebSocketClient.recentConnectionEvents` (added in §44) was being collected but had no UI. Users still had to plug into a Mac and tail device logs to see what happened during a stuck-on-Connecting state.

**What shipped (`QuipiOS/QuipApp.swift`):**
- New `Section { Diagnostics }` in `SettingsSheet` with a `NavigationLink` to `ConnectionDiagnosticsSheet`. Inline summary shows live event count.
- `ConnectionDiagnosticsSheet` view with two sections: Current state (Connected, Authenticated, Server, Last error — color-coded), and Recent events (last 30 timestamped lines, monospaced, newest first, text-selectable, with a Copy button that dumps the buffer to the pasteboard).

**Acceptance test:** Open Settings → Diagnostics → Connection diagnostics → see ≥3 events from app launch. Toggle Wi-Fi off → re-open → see "network path unsatisfied" and "will reconnect in Ns" entries. Tap Copy → paste into Notes → verify formatted timestamp + message lines.

**Related:** `QuipiOS/QuipApp.swift:4214-4232` (Settings link), `QuipiOS/QuipApp.swift:5135-5210+` (`ConnectionDiagnosticsSheet`).

---

### 47. iOS image upload: HEIC encode for size (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `684956b`. Tests pass on iPhone 17 Pro simulator.

**Why:** Image uploads were always PNG (lossless, fat) or JPEG-0.95 (lossy, no alpha). Switching to HEIC at quality 0.85 cuts a typical photo payload by 50-70% — same Mac decode path (`ImageUploadHandler.swift:16,40,67` already accepts HEIC via the magic-byte sniff), so no protocol bump.

**Pivot from WebP:** WebP encode via `CGImageDestination` wasn't shipped until iOS 18; project targets iOS 17. HEIC encode has been available since iOS 11 and is what the iPhone camera roll already uses by default.

**What shipped:**
- New `QuipiOS/Services/UIImage+HEIC.swift` — `heicData(quality:)` extension using `ImageIO + CGImageDestination + UTType.heic`. Returns nil on platforms or color spaces the encoder can't represent.
- `QuipiOS/QuipApp.swift:1986-2008` — `sendPendingImageIfNeeded` tries HEIC first, falls back to PNG (declared image/png) or JPEG-0.95 in that order.
- New tests in `QuipiOS/Tests/UIImageHEICTests.swift`: HEIC produces valid `ftyp` magic at offset 4; HEIC@0.85 beats JPEG@0.95 on a noisy gradient.

**Acceptance test:** Pick a 4032×3024 photo from camera roll → tap send → spinner clears noticeably faster than before; on the Mac, the dropped file in `~/Library/Caches/Quip/uploads/` is `.heic` and ~50% the size of the equivalent JPEG.

**Related:** `QuipiOS/Services/UIImage+HEIC.swift`, `QuipiOS/QuipApp.swift:1986-2008`, `QuipiOS/Tests/UIImageHEICTests.swift`.

---

### 48. Mac menubar: last-event indicator + tunnel state (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `45346ed`.

**Why:** `MenuBarExtra` showed only the client-count string. Two more rows (Cloudflare tunnel health and the latest `ConnectionLog` event) plus a three-color status dot make the popover answer "is anything alive right now" at a glance, no Settings drill-down.

**What shipped:**
- `QuipMac/Views/MenuBarView.swift` — three-color statusIndicator dot (green/yellow/red), tunnel row (green when URL resolved, yellow when resolving), last-event row (icon + relative time via `RelativeDateTimeFormatter`).
- `QuipMac/QuipMacApp.swift` — `ConnectionLog` and `CloudflareTunnel` now injected into the `MenuBarExtra` environment block (previously Settings-only).

**Acceptance test:** With Quip Mac running and phone connected → menubar dot is green, popover shows "Active", tunnel row shows green + truncated subdomain, last-event row shows "authSucceeded · just now". Disconnect phone → popover updates within ~1s to show "Listening" + last-event "disconnected · just now".

**Related:** `QuipMac/Views/MenuBarView.swift:6-14,52-90,116+`, `QuipMac/QuipMacApp.swift:94-102`.

---

### 49. Bundle-and-share diagnostics from Mac + iOS request path (✅ Done, eb-branch)

**Status:** ✅ Done on `eb-branch` — commit `d0a69bc`. All 3 `DiagnosticsBundleTests` pass on macOS host.

**Why:** When a user reports a bug, the cycle was "tail this for me, then this one, then this one." This collapses it to one tap.

**What shipped:**

Mac side — Settings → Diagnostics tab (8th tab, stethoscope icon):
- "Reveal in Finder" opens `~/Library/Logs/Quip/`.
- "Bundle and share…" zips the three logs (`websocket.log`, `push.log`, `kokoro.log`) plus `system-info.txt` to `/tmp` via `/usr/bin/zip`, then opens `NSSharingServicePicker` (AirDrop, Mail, Messages, Save).

iOS side — Settings → Diagnostics → Connection diagnostics → "Get Mac logs" button:
- Sends new `RequestDiagnosticsMessage`.
- Mac handler `handleRequestDiagnostics()` calls `DiagnosticsBundle.makeZip(maxBytes: 4 MiB)`, base64-encodes, ships back as `DiagnosticsBundleMessage`.
- iOS receives, writes the zip to Documents, surfaces a Share button → `UIActivityViewController` → AirDrop to Mac becomes the one-tap "send Erick the logs" path.

New shared types in `Shared/MessageProtocol.swift`:
- `RequestDiagnosticsMessage` (type=`request_diagnostics`, empty body).
- `DiagnosticsBundleMessage` (type=`diagnostics_bundle`, filename, sizeBytes, base64 data, optional errorReason for oversize-cap rejections).

New helper `QuipMac/Services/DiagnosticsBundle.swift`:
- `makeZip(maxBytes:)` writes `Quip-diagnostics-YYYYMMDD-HHMMSS.zip` to `NSTemporaryDirectory`. Tolerates missing log files. Throws `.overSizeCap` when bundle exceeds the WS-path budget.
- `systemInfoText()` pinned in tests so future refactors don't drop fields (App version, macOS, Architecture, Uptime).
- `presentSharePicker(zipURL:anchor:)` wraps `NSSharingServicePicker`.

iOS `DiagnosticsShareSheet` `UIViewControllerRepresentable` wraps `UIActivityViewController` for the SwiftUI sheet.

**Acceptance test (Mac):** Settings → Diagnostics → Bundle and share… → AirDrop sheet appears → drop on another device → unzips to 3 `.log` files + `system-info.txt`.

**Acceptance test (iOS):** Settings → Diagnostics → Connection diagnostics → Get Mac logs → status shows "Bundle ready (NN KB)" → tap Share → `UIActivityViewController` lists AirDrop / Mail / Messages.

**TODO (deferred):** Redact tunnel URLs / device tokens before share. Comment marker in `DiagnosticsBundle.swift`; current data is already in the user's own home dir, so the leak is share-action-only.

**Related:** `QuipMac/Services/DiagnosticsBundle.swift`, `QuipMac/Views/SettingsView.swift:46-49,978+` (DiagnosticsTab), `QuipMac/QuipMacApp.swift:894-895,1077+` (handler), `Shared/MessageProtocol.swift:430-470` (new types), `QuipiOS/Services/WebSocketClient.swift:202-205,710-715` (onDiagnosticsBundle wiring), `QuipiOS/QuipApp.swift:5135-5260+` (Get Mac logs UI).

---

### Boundary marker — autonomous loop halts here, awaiting user input

Tickets §50–§56 (QR pairing, iCloud KVS sync, iPad layout, Apple Watch glance, wake-word PTT, clipboard sync, voice macros) all need user decisions, multi-device hardware testing, or new Xcode targets — see plan file at `~/.claude/plans/plan-to-do-eacn-glowing-oasis.md` for the full open-questions list per ticket.
