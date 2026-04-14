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

### 10. Keyboard-input `onSubmit` + `pressReturn: true` double-Return bug

**Status:** Wishlist — suspected bug, not yet reproduced
**Context:** In `QuipiOS/QuipApp.swift` around line 916, the on-screen text-input `TextField` has `.onSubmit { sendTextInput() }`, and `sendTextInput` calls `client.send(SendTextMessage(..., pressReturn: true))`. When the user hits the iPhone's on-screen Return key while the TextField is focused, `onSubmit` fires the send handler, and the handler explicitly passes `pressReturn: true`. The net effect should be a single Return on the Mac side (the `pressReturn` flag tells the Mac to append one newline after the text), but it's worth double-checking that SwiftUI's Return key isn't *also* being propagated to the TextField's text buffer and arriving as an embedded `\n`. Needs verification and, if confirmed, fix.

---

## Completed

*(none yet — move items here as they ship)*
