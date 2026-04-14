# /plan Shortcut Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-tap `/plan` shortcut button to the iPhone remote's portrait control row that types the literal text `/plan ` (five characters plus trailing space, no Return press) into the currently selected terminal window on the Mac, leaving the cursor on the same line.

**Architecture:** One new SwiftUI `Button` added to the existing `portraitControls` `HStack` in `QuipiOS/QuipApp.swift`. On tap, the button constructs a `SendTextMessage(windowId:, text: "/plan ", pressReturn: false)` and hands it to the existing `client.send(...)` pipeline. No protocol changes, no Mac-side changes — the Mac's existing `handleSendText()` path already types arbitrary `SendTextMessage` text into the target Terminal.app / iTerm2 window via AppleScript. Every piece of plumbing this feature needs already exists; the only thing being added is a new button that invokes it.

**Tech Stack:** SwiftUI (iOS 17+), existing `SendTextMessage` type in `Shared/MessageProtocol.swift`, existing `client.send(_:)` websocket send path, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-04-14-plan-shortcut-button-design.md`

**Branch:** `eb-branch` (local development branch — do NOT push to `origin` without explicit user confirmation per `feedback_eb_branch_push_policy` memory).

---

## File Structure

Exactly one file is modified:

- **Modify:** `QuipiOS/QuipApp.swift` — add a new `Button` inside the `HStack` of the `portraitControls` computed property (currently lines 757–834). No new files, no project structure changes, no `project.yml` edits, no `xcodegen generate` run needed. `QuipApp.swift` is already tracked as a source file by the existing `sources: - path: .` glob in `QuipiOS/project.yml`, so a SwiftUI code addition inside it requires no pbxproj regeneration.

No test files. No shared protocol files. No Mac-side files.

### Why no tests

This is a pure thin-wrapper UI addition: a button that, on tap, calls an already-tested send path (`client.send(_:)`) with an already-tested message type (`SendTextMessage`). The only logic the new button introduces is the literal string `"/plan "` and the boolean `false` for `pressReturn`. There is no conditional logic, no data transformation, no state mutation beyond what SwiftUI does automatically when a button is tapped. A unit test would have to mock the `client` and assert "when the button is tapped, `client.send` was called with a `SendTextMessage` containing `text == "/plan "` and `pressReturn == false`" — which is literally the same level of detail as the implementation itself and provides no additional safety. Manual on-device verification is the test here, and the manual steps are enumerated in Task 1 Step 5 below.

---

## Task 1: Add the /plan shortcut button

**Files:**
- Modify: `QuipiOS/QuipApp.swift:820-833` (append new button after the existing "Press Return" button in the `portraitControls` `HStack`)

### Step 1: Read the current state of `portraitControls`

- [ ] Read `QuipiOS/QuipApp.swift` lines 750–837 to confirm the `portraitControls` `HStack` still looks like what the plan was written against.

Specifically verify:
- The `HStack(spacing: 10)` contains these buttons in order: Previous window (chevron.left), Next window (chevron.right), Push to talk (mic.fill / stop.fill), View output (text.alignleft), Press Return (return icon).
- The Press Return button uses `client.send(QuickActionMessage(windowId: wid, action: "press_return"))`.
- The HStack is wrapped in a `VStack(spacing: 8)` with `.padding(.vertical, 8)` at the end.
- `selectedWindowId` is an optional String that tracks which window is currently selected.
- `client` is the websocket client object exposed to the view.

**If any of the above has changed:** the button code in Step 3 may need minor adjustments (different variable name for the client, different disabled-state logic). Stop and reconcile before proceeding.

### Step 2: Verify `SendTextMessage` exists and matches the expected shape

- [ ] Read `Shared/MessageProtocol.swift` to confirm `SendTextMessage` is defined as:

```swift
struct SendTextMessage: Codable, Sendable {
    let type: String      // always "send_text"
    let windowId: String
    let text: String
    let pressReturn: Bool
}
```

**If the init signature is different** (e.g., missing the hardcoded `type`, using different parameter labels, taking extra fields), adapt the construction site in Step 3 to match. The plan code below assumes the common case where `SendTextMessage(windowId:text:pressReturn:)` is the correct initializer.

### Step 3: Add the new `/plan` button after the "Press Return" button

- [ ] In `QuipiOS/QuipApp.swift`, inside the `portraitControls` `HStack`, after the existing "Press Return" button (which currently ends at line 833 with `.disabled(selectedWindowId == nil)`), insert the following code:

```swift
                // /plan shortcut
                Button {
                    if let wid = selectedWindowId {
                        client.send(SendTextMessage(windowId: wid, text: "/plan ", pressReturn: false))
                    }
                } label: {
                    Text("/plan")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selectedWindowId != nil ? colors.textPrimary : colors.textFaint)
                        .frame(width: 56, height: 56)
                        .background(colors.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(selectedWindowId == nil)
```

**Why these specific styling choices:**
- `Text("/plan")` instead of an SF Symbol, because the user explicitly asked for a "keyboard key that has /plan" — they want the literal characters visible on the button face, not an icon that loosely means "plan."
- `.font(.system(size: 14, weight: .semibold, design: .monospaced))` — monospaced to make the slash character render cleanly alongside the letters, size 14 to fit all five characters inside a 56×56 frame without truncation or awkward wrapping, semibold to match the visual weight of the neighboring icon buttons which render at 20pt medium.
- `.frame(width: 56, height: 56)` — exactly matches the other icon buttons (Prev window, Next window, View output, Press Return) in the row. The Push-to-Talk button is intentionally different (full width) because it's the primary action; the new /plan button is a secondary shortcut and should visually group with the other 56-square buttons.
- `colors.textPrimary` / `colors.textFaint` / `colors.surface` — pulled from the same `colors` object the neighboring buttons use, so the button automatically tracks whatever theme/color scheme is active.
- `.disabled(selectedWindowId == nil)` — matches View Output and Press Return behavior. When no window is selected, the button should be non-interactive and visually faded.

**Where exactly to insert:** Immediately after line 833 (`.disabled(selectedWindowId == nil)` of the Press Return button) and immediately before the closing brace of the `HStack` (currently line 834). So the final order of buttons in the `HStack` becomes: Previous window → Next window → Push to Talk → View output → Press Return → **/plan**.

### Step 4: Build QuipiOS to catch any syntax or type errors

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipiOS/QuipiOS.xcodeproj \
  -scheme QuipiOS \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build 2>&1 | tail -20
```

**Expected output:** Last line reads `** BUILD SUCCEEDED **`.

**If the build fails:** read the error. Common failure modes:
- "Cannot find 'SendTextMessage' in scope" → the `Shared/` directory isn't imported into the iPhone target. Check `QuipiOS/project.yml` `sources` includes `- path: ../Shared`.
- "Extra argument 'text' in call" or similar → the `SendTextMessage` init signature differs from what Step 2 verified. Re-read the actual definition and adjust the call site.
- "Cannot find 'client' in scope" → the view's surrounding context doesn't expose a `client` property. Check the computed property's enclosing type for the correct name; it may be `webSocketClient`, `ws`, or something else.
- SwiftUI type-inference timeout → if the `HStack` has grown too large for Swift's type checker, wrap the new button in a computed property or an `@ViewBuilder` helper and call it from the HStack. This is a common SwiftUI failure mode when a view body gets too dense.

Fix the build error and re-run Step 4 until it succeeds. Do not proceed to Step 5 with a failing build.

### Step 5: Install on the connected iPhone and manually verify

- [ ] First, confirm the iPhone is still connected:

```bash
xcrun devicectl list devices 2>&1 | grep -E "connected.*iPhone"
```

**Expected:** at least one line showing an iPhone in `connected` state. Note its UDID (the 8-4-4-hex identifier in the second-to-last column). If no connected iPhone, tell the user and stop — the remaining verification steps require a physical device.

- [ ] Install the rebuilt `.app` to the iPhone:

```bash
xcrun devicectl device install app \
  --device <UDID-from-previous-step> \
  /Users/erickbzovi/Library/Developer/Xcode/DerivedData/QuipiOS-dzhcfnwaayimqmfypagbymeudhtl/Build/Products/Debug-iphoneos/Quip.app 2>&1 | tail -10
```

**Expected:** output ends with an `App installed:` block showing `bundleID: com.quip.QuipiOS` and a new `installationURL`.

**If the DerivedData path differs on the executing machine,** find the actual path with:

```bash
find ~/Library/Developer/Xcode/DerivedData -name "Quip.app" -path "*/Debug-iphoneos/*" 2>/dev/null
```

and substitute it into the install command.

- [ ] **Manual test A — button disabled with no window selected:**
  1. Launch Quip on the iPhone.
  2. Before connecting to the Mac (or after disconnecting), confirm the `/plan` button in the portrait control row appears greyed out.
  3. Tap it. Nothing should happen. No haptic, no network message.
  4. **Pass criterion:** button is visibly faded and non-interactive when `selectedWindowId` is nil.

- [ ] **Manual test B — button types `/plan ` into the selected terminal:**
  1. Connect Quip to QuipMac (ensure QuipMac is running with at least one Claude Code terminal window registered as a target).
  2. On the iPhone, select a target window (tap a window card so it highlights).
  3. On the Mac, visually position the Claude Code terminal so you can see the cursor.
  4. On the iPhone, tap the `/plan` button.
  5. **Pass criterion:** within ~200ms, the six characters `/plan ` appear in the Claude Code terminal (slash, p, l, a, n, space), and the cursor rests immediately after the trailing space. Return is NOT pressed — the prompt should still be on the same input line.

- [ ] **Manual test C — tap then type additional text:**
  1. Continuing from Test B with `/plan ` already in the terminal prompt.
  2. On the iPhone, tap the Push-to-Talk button, say "write a function that sums two numbers," release.
  3. **Pass criterion:** the dictated text appends cleanly to `/plan `, producing a full prompt like `/plan write a function that sums two numbers` with no dropped or mangled characters. The Return key is still not pressed until you either tap the iPhone's "Press Return" button or hit Return on the Mac keyboard.

- [ ] **Manual test D — repeat-tap idempotency:**
  1. Clear the Claude Code prompt (Ctrl+C or delete the existing input).
  2. On the iPhone, tap the `/plan` button 5 times rapidly.
  3. **Pass criterion:** the Claude Code prompt now contains `/plan /plan /plan /plan /plan ` (five copies, each separated by their trailing space). No dropped characters, no race conditions, no crashes. This is not a "correct usage" test — it's a stress test to prove that rapid taps don't interact badly with the existing `SendTextMessage` pipeline.

**If any of A–D fail:** debug before committing. The most likely failure modes:
- Text appears but with a stray newline → `pressReturn: false` was sent as `true`; re-check the button's action closure.
- Button doesn't appear on the iPhone at all → the code was inserted outside the `HStack` by accident; re-read `QuipApp.swift` at the insertion point and confirm the button is a direct child of the `HStack`.
- Text appears on the wrong terminal window → the `selectedWindowId` binding isn't what you think; check QuipMac logs for the incoming `SendTextMessage` and its `windowId` field.

### Step 6: Commit

- [ ] Confirm only the expected file is modified:

```bash
git status
```

**Expected:** only `QuipiOS/QuipApp.swift` shows as modified. If any other files appear (regenerated `Info.plist`, `project.pbxproj`, etc.), something unexpected happened — most likely `xcodegen generate` was run when it didn't need to be. Investigate before proceeding.

- [ ] Review the diff one more time to confirm the change is only the new button:

```bash
git diff QuipiOS/QuipApp.swift
```

- [ ] Commit. Message is in the project's blue-collar boomer voice per `CLAUDE.md`:

```bash
git add QuipiOS/QuipApp.swift
git commit -m "$(cat <<'EOF'
Stuck a /plan button on the phone so I can just tap it 'stead of typin' them five letters every time. Puts the slash and the word and a space right where the cursor's at and leaves it there so you can keep goin'.
EOF
)"
```

- [ ] **Do NOT push.** Per `feedback_eb_branch_push_policy`, `eb-branch` is local-only. Pushing requires explicit user confirmation. If the user later asks to push, run `git push` separately.

- [ ] Confirm the commit landed:

```bash
git log --oneline -3
```

**Expected:** the new commit is the top entry on `eb-branch`.

---

## Out-of-Scope (intentional non-goals, do NOT implement as part of this plan)

These were explicitly scrapped by the user or called out in the spec as follow-ups for a different commit:

- ❌ Auto-starting voice dictation after the tap. This was an earlier iteration the user rejected.
- ❌ Entering Claude Code's real plan mode via Shift+Tab cycling. Rejected as too complex and drift-prone.
- ❌ A custom `~/.claude/commands/plan.md` slash command template. Rejected as unnecessary; the button just types the text literally.
- ❌ A landscape-orientation version of the button. Portrait-only for v1; the user said this can be a follow-up if they want it.
- ❌ A QuipMac / QuipLinux / QuipAndroid parity version of the button. iPhone-only for v1.
- ❌ State tracking of Claude Code's current mode. Explicitly out of scope.
- ❌ Any changes to `Shared/MessageProtocol.swift`, `QuipMac/`, or any file outside `QuipiOS/QuipApp.swift`.

If during implementation you find yourself wanting to edit any of the above, stop and ask the user instead.

---

## Commit Plan Summary

**Total commits:** 1

**Commit 1:** `QuipiOS/QuipApp.swift` — new `/plan` button in `portraitControls`. Voice-authored message in the project's blue-collar boomer style. Lands on `eb-branch` local only. Does not push.

Each commit is self-contained, buildable, and independently meaningful when read from `git log`, per `feedback_commit_discipline` memory.
