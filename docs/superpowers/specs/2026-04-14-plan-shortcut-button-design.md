# /plan Shortcut Button

A one-tap iPhone button that types `/plan ` into the target Claude Code terminal window.

## Overview

Add a shortcut button to the iPhone remote's portrait control row. Tapping it sends the literal text `/plan ` (trailing space, no newline) to the currently selected terminal window on the Mac, leaving the cursor on the same line so the user can immediately continue typing, pasting, or dictating the rest of their prompt.

This spec is deliberately narrow. What the user explicitly asked for:

- A keyboard-style shortcut button labeled `/plan`.
- One tap types `/plan ` into Claude Code.

What the user explicitly scrapped (and is NOT in this spec):

- Auto-starting voice dictation after the tap.
- Entering Claude Code's real plan mode via Shift+Tab cycling.
- Creating a custom `~/.claude/commands/plan.md` slash command file.
- Any kind of state tracking of Claude Code's current mode.

## Protocol Changes

None. The button uses the existing `SendTextMessage` already defined in `Shared/MessageProtocol.swift`:

```json
{
  "type": "send_text",
  "windowId": "<active-window-id>",
  "text": "/plan ",
  "pressReturn": false
}
```

`pressReturn: false` is the critical field — we want the characters typed but no Return pressed, so the user stays on the same line and can keep composing.

## iPhone Changes

Single file: `QuipiOS/QuipApp.swift`, inside the `portraitControls` view property (around lines 757–834 where the existing shortcut buttons — window cycling, push-to-talk, view output, press return — live).

- A new SwiftUI `Button` added to the existing row. Placement: adjacent to the "Press Return" / "View Output" / mic button cluster. Exact position decided during implementation based on visual balance.
- Label: the literal text `/plan`, same font and sizing as the neighboring text-label buttons. No icon.
- Tap action: builds a `SendTextMessage(windowId: selectedWindowId, text: "/plan ", pressReturn: false)` and hands it to the existing websocket send path the other shortcut buttons already use.
- Disabled state: greyed out and non-interactive when no window is currently selected — matches the behavior of the sibling shortcut buttons.
- Haptic: the same subtle tap feedback the other shortcut buttons emit. No new haptic style.

## Mac Changes

None. The existing `handleSendText()` path in `QuipMac/QuipMacApp.swift` already types incoming `SendTextMessage` text into the target Terminal.app / iTerm2 window via AppleScript. A six-character payload like `/plan ` flows through that path untouched.

## Out of Scope (Explicit Non-Goals)

- **Landscape layout.** This button lives in `portraitControls` only. A landscape mirror can be a follow-up commit if desired.
- **Other platforms.** QuipLinux and QuipAndroid are not touched. If cross-platform parity is wanted, each gets its own follow-up commit.
- **Discoverability features.** No onboarding tip, no tooltip, no settings toggle to show/hide the button. It's always visible once the commit lands.
- **/plan semantics.** What Claude Code does when it sees `/plan ` followed by the user's next input is Claude Code's concern, not Quip's. This spec only guarantees the six characters get typed.

## Testing

- **Manual, no window selected:** button should be greyed out and non-interactive.
- **Manual, window selected:** tap the button — confirm the characters `/plan ` appear in the target terminal window on the Mac, cursor positioned after the trailing space.
- **Manual, tap-then-type:** tap the button, then type or dictate more text on the iPhone. The new text should append cleanly to `/plan ` with no dropped or mangled characters.
- **Manual, tap-then-press-Return:** after tapping `/plan`, tap the existing "Press Return" shortcut. Claude Code should fire whatever it does with the literal string `/plan ` as a prompt.
- **No unit tests.** The feature is a thin UI wrapper over an existing, already-tested send path. There is no new logic worth isolating in a test.

## Commit Plan

**One commit on `eb-branch`.** Files touched: `QuipiOS/QuipApp.swift` only.

`xcodegen` does not need to run — `QuipApp.swift` is already tracked as a source file by the existing `project.yml` `sources` glob, so adding SwiftUI code inside it doesn't change the `.xcodeproj`.

Draft commit message (blue-collar boomer voice, release-note quality):

> Stuck a /plan button on the phone so I can just tap it 'stead of typin' them five letters every time. Puts the slash and the word and a space right where the cursor's at and leaves it there so you can keep goin'.

## Risks and Known Unknowns

- **Visual space in `portraitControls` may be tight.** If the row is already full, the new button either (a) pushes something to a second row, (b) replaces nothing and causes layout overflow, or (c) requires a brief re-layout pass. Implementation plan will check the actual row width before committing to placement.
- **Button label length.** `/plan` is five characters; the existing buttons use short labels or icons. If the label looks awkward at the current button size, implementation may adjust font/padding or switch to a shorter alternative like a SF Symbol + tooltip. This is a pure styling decision, not a spec-level concern.
- **Cross-platform drift.** Because QuipLinux and QuipAndroid are explicitly out of scope, users on those clients won't have this shortcut. That's accepted for v1.
