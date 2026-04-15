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

### 1. `/plan` shortcut button on iPhone

**Status:** Planned (implementation paused behind keyboard-button bug fixes)
**Context:** A one-tap button on the iPhone remote that types `/plan ` into the currently selected terminal window on the Mac. Leaves the cursor on the same line so the user can continue typing or dictating. Explicitly v1: no voice auto-start, no Claude Code mode switching, no landscape mirror, no cross-platform parity.
**Spec:** `docs/superpowers/specs/2026-04-14-plan-shortcut-button-design.md`
**Plan:** `docs/superpowers/plans/2026-04-14-plan-shortcut-button.md`
**Blocked on:** Keyboard/shortcut button bug-fix work — the user wants those vetted before new buttons land.

**Related:** #19 (`/btw` shortcut button — same pattern, different command literal; once #1 lands, #19 should be one commit by reusing the same button component).

---

### 2. Add / close terminal tabs from the iPhone remote

**Status:** Wishlist
**Context:** The iPhone currently cycles through existing Claude Code terminal windows via the left/right chevron buttons but cannot create or destroy them. The user wants to open new Claude Code sessions and close existing ones directly from the phone. Implementation will need:
- New message types in `Shared/MessageProtocol.swift` (e.g., `OpenWindowMessage`, `CloseWindowMessage`).
- Mac-side AppleScript for spawning a new Terminal.app / iTerm2 window running `claude`, and a close-window handler.
- iPhone UI affordances — probably `+` and `×` buttons attached to the window list, or a pair of new shortcut buttons in `portraitControls`.
- A decision about what "close a tab" means when a Claude Code session has unsaved state.

User asked for this explicitly as a separate feature from `/plan`.

---

### 3. Landscape layout for `/plan` shortcut button

**Status:** Wishlist
**Depends on:** #1
**Context:** The `/plan` v1 spec explicitly excluded landscape orientation. Follow-up commit to mirror the button into `landscapeControls` once the portrait version is shipping cleanly.

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

**Status:** Wishlist (explicitly scrapped from `/plan` v1)
**Context:** Instead of typing `/plan` as a literal prefix (which only gives *plan-style* behavior via prompt text), actually put Claude Code into its built-in plan mode by pressing Shift+Tab the correct number of times. Requires:
- Adding `shift_tab` case to `KeystrokeInjector.sendKeystroke` — today's injector supports Return, Ctrl+C, Ctrl+D, Escape, Tab, but not Shift+Tab.
- Either tracking Claude Code's current mode in Quip locally, OR reading the mode indicator from terminal content (see #7) to know how many Shift+Tab presses to send.
- A user-visible fallback / manual override when detection fails.

Known risk: without mode detection, blind Shift+Tab presses can land in the wrong mode (Normal / Auto-Accept / Plan cycle is state-dependent).

---

### 7. Read Claude Code mode from terminal content stream

**Status:** Wishlist
**Context:** Parse the terminal content stream (already flowing via `TerminalContentMessage` / `OutputDeltaMessage` on the existing websocket protocol) to detect Claude Code's current mode indicator strings — `plan mode on`, `auto-accept edits on`, or the absence of either (= Normal mode). Exposes Claude Code's internal mode state to Quip's UI.
**Unlocks:** #6 (robust Shift+Tab plan-mode switching), #18 (context-aware 1/2/3 prompt-response buttons), visible mode indicator on the iPhone status area, intelligent prompt routing decisions.

---

### 8. Number shortcut buttons (1 / 2 / 3) for multiple-choice answers

**Status:** ✅ Done (upstream) — shipped by jboert in commit `4e774e6` as part of the settings drawer and configurable quick-buttons picker. The buttons now live in the second shortcut row, toggled on/off via a gear-icon drawer.

**Original context** (kept for historical reference):
Claude Code occasionally asks multiple-choice questions with two or three lettered/numbered options. Quip already has `press_y` and `press_n` quick actions that iPhone buttons fire to answer yes/no prompts. User wanted three additional buttons — `1`, `2`, and `3` — to answer three-option prompts the same way.

Resolved. Keep this entry to remember the original request and to make it findable when auditing "what did the settings drawer add."

**Related:** #18 (context-aware variant — auto-appear only when Claude shows a numbered prompt).

---

### 9. Window list organized/filtered by application, iTerm2 at the top by default

**Status:** ✅ Partially done (upstream) — shipped by jboert in commit `23f1032`. Terminal windows are now automatically herded to the top of the Mac's window list and on the phone so Claude sessions aren't buried under browser windows. The folder name is now in bold colored text on both the phone tiles and the Mac sidebar, with the terminal app name tucked underneath.

**Still wishlist:** Explicit grouping by application (section headers on the phone) and per-app filtering (hide apps you don't care about). Those are UX refinements on top of the prioritization work that jboert already did.

**Related:** #16 (alternative window list arrangements) — grouping + filtering + layout are all "how the list is rendered" concerns and should be designed together in a future pass.

---

### 10. Persist last session — remember which windows were open on close/reopen

**Status:** Wishlist
**Context:** When Quip (QuipMac, and probably also QuipiOS) closes and relaunches, the list of registered/enabled terminal windows starts fresh — the user loses their previously-curated set and has to re-enable each one. User wants "save the last session" behavior: on close, persist enough state that on relaunch the same windows are automatically recognized and enabled.

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

**Status:** Wishlist — tech debt surfaced during debugging session
**Context:** Every time QuipMac is killed and relaunched, `WindowManager` re-registers all terminal windows and assigns them fresh internal IDs. The iPhone, meanwhile, still holds a `selectedWindowId` from the previous session in its local state. When the iPhone sends a `QuickActionMessage` or `SendTextMessage` with the old ID, the Mac's handler fails to find a matching window and **silently drops the message** — from the user's perspective, the button "stops working" with zero feedback.

**Fix options:**
- **(a) Stable window identity.** Generate `ManagedWindow.id` as a hash of `(app bundle ID, PID, CGWindowID)` or even `(app bundle ID, initial window title, first-seen timestamp)` so it survives Mac restarts as long as the underlying terminal window is still open. Trade-off: harder to change if the underlying window's identity shifts (e.g., iTerm2 reassigns CGWindowID on some operations).
- **(b) iPhone re-validates on reconnect.** When the iPhone receives a fresh window list after reconnecting to QuipMac, it checks whether its locally-selected windowId is still in the list; if not, it clears the selection and shows "please re-select a window."
- **(c) Server-driven reset.** On reconnect, the Mac sends a `ResetSelectionMessage` telling the iPhone to clear any selected windowId. Simple but loses state the user might want to preserve.

**Recommendation:** option (b) as v1 — cheapest fix, most user-friendly. Requires one new message handler on the iPhone and one reconnect-time check.

**Related:** #10 (session persistence) — if implemented, might subsume this item by persisting the window identity in a stable form.

---

### 12. Silent failure diagnostics — add audible errors or UI feedback when messages are dropped

**Status:** Wishlist — tech debt surfaced during debugging session
**Context:** Several handlers in `QuipMac/QuipMacApp.swift` use the `if let window = windowManager.windows.first(where: { $0.id == msg.windowId })` pattern and silently return when the lookup fails. This makes debugging hard: a button that "doesn't do anything" could be dropped at any of half a dozen stages, and without instrumentation there's no signal.

As a quick-win, commit `(TBD)` added `print` statements to the `send_text` and `quick_action` handlers so dropped messages show up in Xcode console / Console.app. But that's just observability for *developers* — the user still sees "button didn't work."

**Fix options:**
- **(a) Error broadcast message.** When the Mac drops a message, send an `ErrorMessage` back to the iPhone with a reason code. The iPhone can show a toast or temporary banner ("⚠ window no longer exists").
- **(b) Haptic/visual failure feedback.** On the iPhone, if a button tap doesn't produce an expected state change within N milliseconds, fire a distinct "failure" haptic. Requires the iPhone to have state awareness of what "success" looks like, which is harder.
- **(c) Client-side pre-flight check.** Before sending a message, the iPhone verifies the selected windowId is still in the window list it last received. If not, disable the button visually. This prevents the bug from happening in the first place.

**Recommendation:** (a) for completeness + (c) as a belt-and-suspenders measure.

---

### 13. Multi-iTerm2-window keystroke targeting (real fix)

**Status:** Wishlist — partial fix attempted, had to be reverted
**Context:** When the user has multiple iTerm2 windows open and selects one on the iPhone, `sendKeystroke` (for Return, Ctrl+C, Tab, Escape, backspace, etc.) currently fires the keystroke at whatever iTerm2 window is **already frontmost**, not necessarily the one the user selected on the phone. This is because:

- `sendKeystroke` injects via System Events (`key code N`), which targets the OS-level focused window — not a specific AppleScript-addressable window.
- Commit `4006db4` tried to fix this by having the AppleScript iterate iTerm2's windows and `select` the one whose `id` matched the CGWindowID. **That never worked** — iTerm2's AppleScript `id of window` returns iTerm2's own internal window identifier (small integers like `447`, `1159`, `1154`), not a CGWindowID (typically >10000). The repeat loop silently never matched.
- Commit `465d5b5` reverted that attempt and restored the original behavior: rely on `windowManager.focusWindow(wid)` (AX-based raise) + a hard 100ms delay + System Events keystroke. This lands the keystroke in whatever window `focusWindow` managed to raise — which is usually correct for the simple one-window case but can race when windows are stacked at near-identical positions.

**Fix options to explore:**
- **(a) Match by iTerm2 `unique id` of session.** Each iTerm2 session has a stable unique ID accessible via AppleScript (`tell current session of window N to get unique id`). If Quip's `WindowManager` could read and cache session unique IDs at registration time, the keystroke script could select by session ID instead of window ID. Requires one-time lookup per session and storage in `ManagedWindow`.
- **(b) Bypass System Events entirely via AX APIs.** Use `AXUIElementCreateApplication` + iterate AX windows + find the one whose `kAXDocumentAttribute` or `kAXTitleAttribute` matches, then post keystrokes via `CGEventPost` with a target PID. This is how `ydotool` works on Linux, and there's a macOS equivalent using `CGEventCreateKeyboardEvent` + `CGEventPostToPSN`.
- **(c) Use iTerm2's `write text` verb for all injection.** iTerm2's AppleScript `write text` targets a specific session by address and doesn't depend on window focus. The trick is that `write text` only handles text — for special keys (Return, Ctrl+C, Tab, backspace, etc.) we'd need to send escape sequences. Return is `write text "" newline yes`. Ctrl+C is `write text (ASCII character 3)`. Backspace is `write text (ASCII character 8)` or `(ASCII character 127)`. This would be a huge rewrite of `sendKeystroke` to detect whether the target is iTerm2 and use native verbs instead of System Events.

**Recommendation:** (c) long-term, (a) as an interim fix. (b) is the most robust but requires significant C-level code and is the largest change.

**Reproduce:** Open two iTerm2 windows, select one from the iPhone, tap Return. Often the Return lands in the OTHER window.

**Current workaround:** Only have one iTerm2 window with Claude Code running at a time. Suboptimal but makes the issue invisible.

---

### 14. Gitignore generated Info.plist files to prevent fix-in-wrong-layer bugs

**Status:** Wishlist — tech debt surfaced during debugging session
**Context:** `QuipiOS/Info.plist` and `QuipMac/Info.plist` are both **generated outputs** of `xcodegen`, produced from the `info.properties` section of each project's `project.yml`. But they're currently **tracked in git**, which creates a trap: you can edit the tracked Info.plist directly, commit it, and the fix looks correct in `git diff` — until the next time anyone runs `xcodegen generate`, which silently clobbers the edit from the project.yml source of truth.

This exact trap bit us in commit `ed68292`: an earlier fix in `f7bb347` patched `NSAllowsLocalNetworking: true` out of `QuipiOS/Info.plist` but left the flag in `QuipiOS/project.yml`. Every time xcodegen ran in this session (for signing changes, version marker, etc.), the flag got re-added to Info.plist from project.yml, silently breaking Tailscale connectivity from the iPhone until the user hit the bug again.

**Fix options:**
- **(a) Gitignore both Info.plist files and force all edits through project.yml.** Simple, hard trap-proofing. Requires removing them from git history (or at least stopping tracking them) and updating any tooling that expects them to exist at clone time. Downside: a fresh clone needs to run `xcodegen generate` before opening in Xcode, which adds a step for anyone who doesn't already have xcodegen installed.
- **(b) Add a pre-commit hook that fails if someone stages an Info.plist change without a matching project.yml change.** More surgical but harder to enforce across contributors. Requires hook tooling.
- **(c) Add a CI check that runs `xcodegen generate` and diffs the resulting Info.plist against the committed one, failing the build if they differ.** Makes drift visible but doesn't prevent it.

**Recommendation:** (a). Simplest, most bulletproof. Same tradeoff we already accept for `.xcodeproj` files (which ARE partially generated by xcodegen and tracked — though the generator's intent is that you commit them so clean-clone works without running xcodegen).

Actually wait — `.xcodeproj/project.pbxproj` is also generated by xcodegen and it's tracked. The convention in this repo is to commit xcodegen outputs. So option (a) is inconsistent with the existing convention for `.xcodeproj`. Either we untrack both (Info.plist AND .xcodeproj) and require xcodegen at clone time, or we keep both tracked and rely on discipline. Worth discussing with the repo owner before landing.

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

**Status:** Wishlist — suspected bug, not yet reproduced
**Context:** In `QuipiOS/QuipApp.swift` around line 916, the on-screen text-input `TextField` has `.onSubmit { sendTextInput() }`, and `sendTextInput` calls `client.send(SendTextMessage(..., pressReturn: true))`. When the user hits the iPhone's on-screen Return key while the TextField is focused, `onSubmit` fires the send handler, and the handler explicitly passes `pressReturn: true`. The net effect should be a single Return on the Mac side (the `pressReturn` flag tells the Mac to append one newline after the text), but it's worth double-checking that SwiftUI's Return key isn't *also* being propagated to the TextField's text buffer and arriving as an embedded `\n`. Needs verification and, if confirmed, fix.

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

**Related:** #7 (terminal content parsing — strict prerequisite), #8 (the static 1/2/3 buttons that already exist).

---

### 19. `/btw` shortcut button on iPhone

**Status:** Wishlist
**Depends on:** #1 (the `/plan` button — same pattern, same code paths)
**Blocked on:** Same as #1 — keyboard/shortcut button bug-fix work the user wants vetted before new buttons land.
**Context:** A one-tap button on the iPhone remote that types `/btw ` into the currently selected terminal window on the Mac, leaving the cursor on the same line so the user can continue typing or dictating. Mirrors the `/plan` button (#1) exactly — same `SendTextMessage` plumbing, same "no auto-dictate / no landscape / no cross-platform parity" v1 scope. Different command literal, otherwise identical.

`/btw` is a registered Claude Code slash command — confirmed from the in-app autocomplete dropdown, which lists it with the description **"Ask a quick side question without interrupting the main conversation."** The user uses it heavily across multiple projects: subagent log files named `agent-aside_question-*.jsonl` appear under `~/.claude/projects/` for at least 8 different projects (Quip, drive-ins, fintechadventures, msu, national-parks, DesertDiaryAZ, hub, credit-unions). Strong inference: `/btw` dispatches a subagent named `aside_question` that handles the side question on an isolated context, leaving the main conversation unpolluted by tangential tokens.

The defining source file for `/btw` wasn't findable during this session — checked `~/.claude/commands/` (didn't exist), `<project>/.claude/commands/`, and every `commands/` directory under `~/.claude/plugins/marketplaces/` and `~/.claude/plugins/cache/`, plus full-text grep for the description string. Whoever graduates this to a spec should track down the source location (most likely candidates: a plugin in a non-obvious path, an MCP server providing custom commands, or a Claude Code feature shipped after April 2026 that registers commands programmatically). Knowing where `/btw` lives matters less for the button itself — the button just types the literal characters and lets Claude Code on the other end resolve the command however it normally does — and more for understanding what the side-question subagent has access to (tools, context, etc.) when designing the v2 dictation flow.

**Note for whoever graduates this to a spec:** with both `/plan` and `/btw` planned as standalone shortcut buttons, the canonical "two hardcoded buttons is becoming a pattern" smell is visible. Worth flagging in brainstorm whether the right v2 shape is "configurable list of slash-command shortcuts the user can edit in Settings" rather than another hardcoded button. Don't restructure #1 or #19 preemptively — let the brainstorm decide. But the option exists and shouldn't get lost.

**Related:** #1 (`/plan` button — direct sibling), #4 (cross-platform parity — once `/btw` lands on iOS, mirror to QuipLinux/QuipAndroid same as `/plan`).

---

## Completed

*(none yet — move items here as they ship)*
