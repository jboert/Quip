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
**Unlocks:** #6 (robust Shift+Tab plan-mode switching), visible mode indicator on the iPhone status area, intelligent prompt routing decisions.

---

### 8. Number shortcut buttons (1 / 2 / 3) for multiple-choice answers

**Status:** Wishlist
**Context:** Claude Code occasionally asks multiple-choice questions with two or three lettered/numbered options. Quip already has `press_y` and `press_n` quick actions (see `QuipMac/QuipMacApp.swift` `handleQuickAction` cases around lines 524–531) that iPhone buttons fire to answer yes/no prompts. User wants three additional buttons — `1`, `2`, and `3` — to answer three-option prompts the same way. Each button would:
- Send a `QuickActionMessage(action: "press_1")` (etc.) from the iPhone.
- The Mac's `handleQuickAction` would add three new cases that call `keystrokeInjector.sendText("1", to: wid, pressReturn: true, ...)` / `"2"` / `"3"`.
- On the iPhone, three new buttons in the shortcut area — either in `portraitControls` as a dedicated row, or tucked into the existing long-press context menu on window cards (which is where Y/N currently live per `WindowRectangle.swift:109–150`).

UX placement is TBD — needs a brainstorming pass to decide whether these go in the main control row (always visible but consumes space) or a sub-panel (hidden but one extra tap to reach).

Dependencies: whichever window-targeting bug fix lands first — because these will use the same injection path as the Return button and should benefit from the fix automatically.

---

### 9. Window list organized/filtered by application, iTerm2 at the top by default

**Status:** Wishlist
**Context:** The iPhone currently shows a flat list of all detected terminal windows in whatever order `WindowManager` delivers them. User wants the window list to be:
- **Grouped by application** — all iTerm2 windows together, all Terminal.app windows together, etc. Probably as section headers in the SwiftUI list.
- **Filterable** — ability to hide windows from apps the user doesn't care about, or show only one app at a time. Could be a segmented picker at the top of the list, or a context-menu toggle per app.
- **Defaulted to iTerm2 at the top** — since iTerm2 is the user's primary terminal, its section should appear first without them having to change anything. Other terminal apps appear below in whatever order makes sense.

Implementation touches:
- `QuipiOS/QuipApp.swift` — window list rendering, add sectioning / filtering UI.
- Possibly `QuipMac/Services/WindowManager.swift` — if the Mac should send pre-sorted or pre-grouped windows rather than having the iPhone sort them client-side. Client-side is probably simpler (keeps the protocol flat).
- Decide whether the sort order is configurable in Settings or hardcoded to "iTerm2 first." Start hardcoded for v1; add a setting later if other users complain.

No dependencies. Can be built any time after the current round of shortcut-button bug fixes lands.

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

### 13. Keyboard-input `onSubmit` + `pressReturn: true` double-Return bug

**Status:** Wishlist — suspected bug, not yet reproduced
**Context:** In `QuipiOS/QuipApp.swift` around line 916, the on-screen text-input `TextField` has `.onSubmit { sendTextInput() }`, and `sendTextInput` calls `client.send(SendTextMessage(..., pressReturn: true))`. When the user hits the iPhone's on-screen Return key while the TextField is focused, `onSubmit` fires the send handler, and the handler explicitly passes `pressReturn: true`. The net effect should be a single Return on the Mac side (the `pressReturn` flag tells the Mac to append one newline after the text), but it's worth double-checking that SwiftUI's Return key isn't *also* being propagated to the TextField's text buffer and arriving as an embedded `\n`. Needs verification and, if confirmed, fix.

---

## Completed

*(none yet — move items here as they ship)*
