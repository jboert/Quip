# iPhone Tab Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two actions to the iPhone's long-press context menu on window cards: "Duplicate in new window" (spawns a new iTerm2 window in the same directory) and "Close terminal…" (destructively closes the target window with a confirmation alert).

**Architecture:** Five cherry-pickable commits that add two new `Codable` message types on the wire, two new `KeystrokeInjector` AppleScript methods for iTerm2 spawn/close, two new handler cases on the Mac side, one new `@AppStorage` Settings field for the configurable spawn command, and two new enum cases + dispatcher branches on the iPhone side. No new files — every change extends an existing one.

**Tech Stack:** Swift 6 with strict concurrency minimal, SwiftUI (iOS 17+, macOS 14+), xcodegen-generated Xcode projects (edit `project.yml`, never `.xcodeproj/project.pbxproj` directly), AppleScript via `NSAppleScript` for iTerm2 automation, UserDefaults via `@AppStorage`, websocket protocol via the existing `MessageCoder` in `Shared/MessageProtocol.swift`.

**Spec:** `docs/superpowers/specs/2026-04-14-iphone-tab-management-design.md`

**Branch:** `eb-branch` (local development branch — do NOT push to `origin` without explicit user confirmation per `feedback_eb_branch_push_policy` memory).

**Testing philosophy:** This feature is a thin UI + message + AppleScript layer. Unit tests would mostly mock out the interesting parts, and the codebase has no automated test infrastructure for SwiftUI views or AppleScript generation. Each task below includes **manual verification steps on the live iPhone + Mac** instead of automated tests. The manual steps are concrete and falsifiable — not vague "try it out and see." Same testing philosophy the `/plan` button plan (`2026-04-14-plan-shortcut-button.md`) used.

---

## File Structure

No new files. Every change extends an existing one:

| File | Task | Responsibility added |
|---|---|---|
| `Shared/MessageProtocol.swift` | Task 1 | Two new `Codable, Sendable` message types |
| `QuipMac/Services/KeystrokeInjector.swift` | Task 2 | Two new public methods (`spawnWindow`, `closeWindow`) + one private helper (`escapeForShell`) |
| `QuipMac/QuipMacApp.swift` | Task 3 | Two new `case` branches in `handleIncomingMessage` |
| `QuipMac/Views/SettingsView.swift` | Task 4 | One new `@AppStorage("spawnCommand")` TextField row |
| `QuipiOS/Views/WindowRectangle.swift` | Task 5 | Two new `WindowAction` enum cases, two new context menu items, `@State` for the confirmation alert, and a `.alert` modifier |
| `QuipiOS/QuipApp.swift` | Task 5 | Two new early-return branches in `sendAction(windowId:action:)` |

Tasks 1–4 each touch exactly one file. Task 5 touches two files that must ship together — Swift's exhaustiveness checker will reject the build if the `WindowAction` enum cases added in `WindowRectangle.swift` are not matched in the `sendAction` switch in `QuipApp.swift`.

---

## Task 1: Wire protocol — new message types

**Goal:** Add `DuplicateWindowMessage` and `CloseWindowMessage` to the shared protocol file. Standalone commit — no callers yet, builds clean.

**Files:**
- Modify: `Shared/MessageProtocol.swift`

### Step 1: Read the current state of `Shared/MessageProtocol.swift`

- [ ] Read the file and confirm the existing pattern. You should see `Codable, Sendable` structs like `SelectWindowMessage`, `SendTextMessage`, `QuickActionMessage`, `STTStateMessage`, etc., each with a hardcoded `type: String` field and an `init` that sets it.

Run: `grep -n "struct .* Message:" Shared/MessageProtocol.swift`

Expected output: list of message struct definitions, one per line.

### Step 2: Locate the end of the iPhone → Mac messages section

- [ ] Read around lines 95–140 of `Shared/MessageProtocol.swift` to find where `QuickActionMessage` and `STTStateMessage` are defined. The new messages should go immediately after `STTStateMessage` (or whatever the last iPhone→Mac message is), before any Mac→iPhone message definitions start. A comment block separates directions.

### Step 3: Add the two new structs

- [ ] Insert this block at the appropriate position in `Shared/MessageProtocol.swift`, after the last existing iPhone→Mac message struct and before the Mac→iPhone section:

```swift
/// iPhone → Mac. Asks the Mac to spawn a new iTerm2 window in the same
/// working directory as the source window, running the configured command.
struct DuplicateWindowMessage: Codable, Sendable {
    let type: String
    let sourceWindowId: String

    init(sourceWindowId: String) {
        self.type = "duplicate_window"
        self.sourceWindowId = sourceWindowId
    }
}

/// iPhone → Mac. Asks the Mac to actually close a specific iTerm2 window
/// (destructive — kills any running command in that session).
struct CloseWindowMessage: Codable, Sendable {
    let type: String
    let windowId: String

    init(windowId: String) {
        self.type = "close_window"
        self.windowId = windowId
    }
}
```

### Step 4: Build QuipMac to verify the new structs compile

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  build 2>&1 | tail -5
```

**Expected output:** `** BUILD SUCCEEDED **` as the last non-blank line.

**If the build fails:** read the error. Common failure modes:
- "Expected declaration" or "Expected '}'" → a syntax error in the inserted block. Re-check braces.
- "Invalid redeclaration of 'DuplicateWindowMessage'" → a struct with that name already exists elsewhere. Search: `grep -rn "DuplicateWindowMessage" Shared/ QuipMac/ QuipiOS/`. If it's already there, the plan drifted from reality — stop and investigate.

### Step 5: Build QuipiOS to verify the same

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipiOS/QuipiOS.xcodeproj \
  -scheme QuipiOS \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build 2>&1 | tail -5
```

**Expected output:** `** BUILD SUCCEEDED **` as the last non-blank line.

Both targets must build because `Shared/MessageProtocol.swift` is included in both the Mac and iOS source globs (per `QuipMac/project.yml` and `QuipiOS/project.yml` `sources: - path: ../Shared`).

### Step 6: Verify `git status` shows only the protocol file changed

- [ ] Run: `git status`

**Expected:** exactly one modified file — `Shared/MessageProtocol.swift`. If anything else shows up (regenerated Info.plist, pbxproj, etc.), investigate before committing.

### Step 7: Commit

- [ ] Run:

```bash
git add Shared/MessageProtocol.swift
git commit -m "$(cat <<'EOF'
Taught the phone and the Mac two new little words — "duplicate_window" for when you wanna spawn a fresh iTerm window in the same folder as one you're already lookin' at, and "close_window" for when you wanna actually shut one down. Just the words for now — nobody's hollerin' 'em yet, that wire-up comes later.
EOF
)"
```

- [ ] Verify the commit landed: `git log --oneline -1`

**Expected:** top entry is the commit you just made.

- [ ] **Do NOT push.** Per `feedback_eb_branch_push_policy`, `eb-branch` is local-only. Pushing requires explicit user confirmation.

---

## Task 2: KeystrokeInjector — spawnWindow, closeWindow, escapeForShell

**Goal:** Add two new public methods to `KeystrokeInjector` and one private helper. Standalone commit — no callers yet.

**Files:**
- Modify: `QuipMac/Services/KeystrokeInjector.swift`

### Step 1: Read the current state of `KeystrokeInjector.swift`

- [ ] Read the file to confirm:
- `final class KeystrokeInjector` is annotated `@MainActor` and conforms to `Observable`.
- The existing `spawnTerminal(in:terminalApp:)` method is around line 209 — it spawns a new iTerm2 or Terminal.app window, `cd`s to a directory, runs `claude`. Your new `spawnWindow` will live next to it.
- The existing `escapeForAppleScript(_:)` helper exists as a private method. Your new `escapeForShell` will live next to it.
- The `TerminalApp` enum has cases `.iterm2` and `.terminal` with a `rawValue` that is the app's name ("iTerm2" or "Terminal").
- `InjectionResult` is a nested `Sendable` struct with `success: Bool` and `error: String?`.

Run: `grep -n "func spawn\|func escape\|InjectionResult" QuipMac/Services/KeystrokeInjector.swift`

**Expected output:** lines showing the existing `spawnTerminal` function signature, both escape helpers, and the `InjectionResult` struct.

### Step 2: Add the `escapeForShell` private helper

- [ ] Insert this method directly below the existing `escapeForAppleScript(_:)` method in `KeystrokeInjector.swift`:

```swift
/// Escape a string for safe interpolation into a shell command that's
/// itself embedded in an AppleScript `write text` or `do script` call.
/// Handles backslashes, double-quotes, dollar signs, and backticks —
/// the characters that would otherwise let a shell expansion or command
/// substitution leak into what should be a literal.
///
/// Apply this BEFORE `escapeForAppleScript` — the shell safety happens
/// at the shell level, and then the whole resulting string gets escaped
/// again for the AppleScript string literal.
private func escapeForShell(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}
```

### Step 3: Add the `spawnWindow(in:command:terminalApp:)` method

- [ ] Insert this method after the existing `spawnTerminal(in:terminalApp:)` method in `KeystrokeInjector.swift`:

```swift
/// Open a new iTerm2 window (not tab), `cd` to the given directory, and
/// run the given command. Like `spawnTerminal(in:terminalApp:)` but with
/// a configurable command instead of hardcoded `claude`. Pass an empty
/// string as `command` to land in a bare shell with no follow-on command.
///
/// Terminal.app is not supported in this method — call `spawnTerminal` for
/// that path, or wait for the Terminal.app branch to be added later (see
/// wishlist).
///
/// - Parameters:
///   - directory: Absolute path to `cd` to in the new window.
///   - command: Shell command to run after `cd`. Empty string means no command.
///   - terminalApp: Must be `.iterm2` — returns an error for `.terminal`.
/// - Returns: Result indicating success or failure.
@discardableResult
func spawnWindow(in directory: String, command: String, terminalApp: TerminalApp) -> InjectionResult {
    guard terminalApp == .iterm2 else {
        return InjectionResult(
            success: false,
            error: "spawnWindow only supports iTerm2 in v1; use spawnTerminal for Terminal.app"
        )
    }

    // Build the shell command: `cd "<dir>"` optionally followed by ` && <command>`.
    // Escape the directory and command for shell, then the whole composed string
    // gets escaped again for AppleScript string-literal safety.
    let shellDir = escapeForShell(directory)
    let shellCmd = escapeForShell(command)
    let composed: String
    if command.isEmpty {
        composed = "cd \"\(shellDir)\""
    } else {
        composed = "cd \"\(shellDir)\" && \(shellCmd)"
    }
    let scriptSafeComposed = escapeForAppleScript(composed)

    let script = """
    tell application "iTerm2"
        activate
        create window with default profile
        tell current session of current window
            write text "\(scriptSafeComposed)"
        end tell
    end tell
    """

    return executeAppleScript(script, context: "spawnWindow in \(directory), cmd=\(command)")
}
```

### Step 4: Add the `closeWindow(windowName:terminalApp:)` method

- [ ] Insert this method directly after `spawnWindow` in `KeystrokeInjector.swift`:

```swift
/// Destructively close an iTerm2 window whose title matches `windowName`.
/// Iterates iTerm2's window list and closes the FIRST match — if two
/// windows share a title, only one is closed (the one iTerm2 returns
/// first, implementation-defined order). This limitation is documented
/// on the wishlist for a proper AX-handle-based fix.
///
/// Terminal.app is not supported in v1 — returns an error.
///
/// Note on matching: iTerm2's AppleScript `id of window` returns iTerm2's
/// own internal window identifier, NOT a `CGWindowID`, as proven
/// empirically in commit `24e820f`. So we match by `name` (window title)
/// instead, which IS a real string comparison.
///
/// - Parameters:
///   - windowName: The window title to match. Passed through
///     `escapeForAppleScript` only — no shell escaping, because the
///     value is used as an AppleScript string literal, not a shell
///     fragment.
///   - terminalApp: Must be `.iterm2` — returns an error for `.terminal`.
/// - Returns: Result indicating success or failure.
@discardableResult
func closeWindow(windowName: String, terminalApp: TerminalApp) -> InjectionResult {
    guard terminalApp == .iterm2 else {
        return InjectionResult(
            success: false,
            error: "closeWindow only supports iTerm2 in v1"
        )
    }

    let escapedName = escapeForAppleScript(windowName)
    let script = """
    tell application "iTerm2"
        try
            repeat with w in windows
                if name of w is "\(escapedName)" then
                    close w
                    return
                end if
            end repeat
        end try
    end tell
    """

    return executeAppleScript(script, context: "closeWindow \(windowName)")
}
```

### Step 5: Build QuipMac

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  build 2>&1 | tail -5
```

**Expected:** `** BUILD SUCCEEDED **`.

**If the build fails:**
- "No exact matches in call to initializer" → your `executeAppleScript` call signature doesn't match. Read `executeAppleScript` definition at the bottom of the file and confirm you're passing two arguments (`source`, `context`).
- "Use of unresolved identifier 'TerminalApp'" → SourceKit noise, not a real compile error. The real Swift compiler resolves cross-file types atomically. If `xcodebuild` reports this (not just SourceKit), `TerminalApp` was renamed or moved — run `grep -rn "enum TerminalApp" QuipMac/` to find it.

### Step 6: Verify `git status`

- [ ] Run: `git status`

**Expected:** exactly one modified file — `QuipMac/Services/KeystrokeInjector.swift`.

### Step 7: Commit

- [ ] Run:

```bash
git add QuipMac/Services/KeystrokeInjector.swift
git commit -m "$(cat <<'EOF'
Added two new tools to the injector's toolbox — one that pops open a fresh iTerm window in whatever folder you point it at and runs whatever command you hand it, and one that actually slams an iTerm window shut by its title. Also put in a shell-escape helper so folder names with spaces and quote marks don't blow the whole thing up.
EOF
)"
```

- [ ] Verify: `git log --oneline -1`

- [ ] **Do NOT push.**

---

## Task 3: Mac handler — handleIncomingMessage cases

**Goal:** Wire the new message types to the new injector methods. After this commit, the Mac handles both messages end-to-end, but the phone doesn't send them yet.

**Files:**
- Modify: `QuipMac/QuipMacApp.swift`

### Step 1: Read the current state of `handleIncomingMessage`

- [ ] Run: `grep -n "case \"send_text\"\|case \"quick_action\"\|default: break\|handleIncomingMessage" QuipMac/QuipMacApp.swift`

**Expected output:** the function definition line and the existing switch cases. Note the line number of `default: break` — you'll insert the new cases immediately before it.

- [ ] Read the surrounding context (~30 lines around the `default: break`) to confirm:
- The switch statement is inside `handleIncomingMessage(_:)`.
- Existing cases (`select_window`, `send_text`, `quick_action`, etc.) follow the pattern: `if let msg = MessageCoder.decode(MessageType.self, from: data) { ... }`.
- The function uses `windowManager.windows.first(where: { $0.id == msg.windowId })` to look up the target.
- There are already `print("[Quip] ...")` diagnostic statements from commit `67898b9`.

### Step 2: Verify `terminalAppForWindow` exists

- [ ] Run: `grep -n "func terminalAppForWindow" QuipMac/QuipMacApp.swift`

**Expected:** one match. This helper maps a `ManagedWindow` to a `TerminalApp` enum value. The new cases use it to decide whether to go down the iTerm2 branch in the injector.

**If it doesn't exist under that name:** run `grep -n "func terminalApp" QuipMac/QuipMacApp.swift` to find the actual name. Use whatever it is.

### Step 3: Insert the two new cases before `default: break`

- [ ] In `QuipMac/QuipMacApp.swift`, inside `handleIncomingMessage(_:)`, immediately before the `default: break` line, insert these two cases:

```swift
case "duplicate_window":
    if let msg = MessageCoder.decode(DuplicateWindowMessage.self, from: data) {
        print("[Quip] duplicate_window: sourceWindowId=\(msg.sourceWindowId)")
        if let source = windowManager.windows.first(where: { $0.id == msg.sourceWindowId }) {
            // subtitle is documented as "Directory path or secondary info" in
            // WindowManager.swift — so it might be empty, or it might be
            // non-path text like "idle". Only treat it as a directory if it
            // looks like one. Fall back to $HOME otherwise.
            let rawSubtitle = source.subtitle
            let looksLikePath = rawSubtitle.hasPrefix("/") || rawSubtitle.hasPrefix("~")
            let dir: String
            if looksLikePath {
                dir = rawSubtitle
            } else {
                dir = NSHomeDirectory()
                if !rawSubtitle.isEmpty {
                    print("[Quip] duplicate_window: subtitle \"\(rawSubtitle)\" is not a path, falling back to $HOME")
                }
            }
            let termApp = terminalAppForWindow(source)
            let cmd = UserDefaults.standard.string(forKey: "spawnCommand") ?? "claude"
            keystrokeInjector.spawnWindow(in: dir, command: cmd, terminalApp: termApp)
            // WindowManager's auto-refresh (~1 second) picks up the new window.
        } else {
            let known = windowManager.windows.map { $0.id }
            print("[Quip] duplicate_window DROPPED: unknown source windowId=\(msg.sourceWindowId). Known: \(known)")
        }
    }

case "close_window":
    if let msg = MessageCoder.decode(CloseWindowMessage.self, from: data) {
        print("[Quip] close_window: windowId=\(msg.windowId)")
        if let window = windowManager.windows.first(where: { $0.id == msg.windowId }) {
            let termApp = terminalAppForWindow(window)
            keystrokeInjector.closeWindow(windowName: window.name, terminalApp: termApp)
            // WindowManager's auto-refresh removes the closed window from the list.
        } else {
            let known = windowManager.windows.map { $0.id }
            print("[Quip] close_window DROPPED: unknown windowId=\(msg.windowId). Known: \(known)")
        }
    }
```

### Step 4: Build QuipMac

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  build 2>&1 | tail -5
```

**Expected:** `** BUILD SUCCEEDED **`.

**Common failures:**
- "Cannot find 'DuplicateWindowMessage' in scope" → Task 1's protocol commit didn't land, or the current commit is checked out before Task 1. Run `git log --oneline -5` to confirm Task 1's commit is in the history.
- "Cannot find 'spawnWindow' / 'closeWindow' in scope" → Task 2's commit didn't land. Same check.

### Step 5: Install and verify the Mac handler end-to-end with logging

- [ ] Install the fresh build to `/Applications`:

```bash
pgrep -x Quip && osascript -e 'tell application id "com.quip.mac" to quit' 2>/dev/null
sleep 1
rm -rf /Applications/Quip.app
ditto /Users/erickbzovi/Library/Developer/Xcode/DerivedData/QuipMac-gshuzoneefuszmfaixdlgjyaogag/Build/Products/Debug/Quip.app /Applications/Quip.app
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/Quip.app
open /Applications/Quip.app
```

**If the DerivedData path differs on your machine, find it with:** `find ~/Library/Developer/Xcode/DerivedData -type d -name "Quip.app" -path "*/Debug/*"`

- [ ] Launch Console.app and filter by `process:Quip`. Leave it open — you'll check it in the next step.

- [ ] **Manual test A — unknown window lookup:** from a separate Swift test snippet OR by temporarily sending a raw `duplicate_window` JSON over the websocket (via the iPhone app's existing dev path or `wscat`), verify that an unknown `sourceWindowId` produces a `[Quip] duplicate_window DROPPED:` line in Console.app.

**If you don't have a way to inject a raw websocket message from outside the phone**, skip this test and trust the code path. Task 5 will exercise the full end-to-end path, at which point any bug here will surface.

### Step 6: Verify `git status`

- [ ] Run: `git status`

**Expected:** exactly one modified file — `QuipMac/QuipMacApp.swift`.

### Step 7: Commit

- [ ] Run:

```bash
git add QuipMac/QuipMacApp.swift
git commit -m "$(cat <<'EOF'
Wired up the Mac to listen for them two new words from the phone — when it hears "duplicate_window" it looks up the window you pointed at, grabs its folder, and tells the injector to pop open a fresh iTerm there with whatever command the Settings say to run (claude by default). When it hears "close_window" it looks up the target and tells the injector to slam it shut. Phone ain't hollerin' yet, that comes in the last commit.
EOF
)"
```

- [ ] Verify: `git log --oneline -1`

- [ ] **Do NOT push.**

---

## Task 4: Settings — spawnCommand TextField

**Goal:** Add a single `@AppStorage("spawnCommand")` TextField in the Mac Settings so the user can configure what command runs after `cd` in a newly-spawned window. Default is `claude`.

**Files:**
- Modify: `QuipMac/Views/SettingsView.swift`

### Step 1: Read the current state of SettingsView.swift

- [ ] Read the file and identify:
- The top-level struct (likely `struct SettingsView: View`).
- Which tab or section existing Connection settings live in — there's already a "Connection" tab per the exploration in the session that led up to this plan, and the new field fits naturally there.
- The existing `@AppStorage` pattern — there's already a `requirePINForLocal` key used elsewhere.

Run: `grep -n "@AppStorage\|TabView\|TabItem\|Form\|TextField" QuipMac/Views/SettingsView.swift | head -30`

**Expected output:** a handful of existing `@AppStorage` declarations, a `TabView` or `NavigationSplitView` containing tabs, and existing TextField/Toggle examples.

### Step 2: Locate the Connection tab body

- [ ] Read around the Connection tab's body. Find where existing `@AppStorage` fields are declared on the containing View struct — they typically sit at the top of the struct's `var body`. Note the indentation and pattern.

### Step 3: Add the `@AppStorage` property and the UI row

- [ ] Add this `@AppStorage` declaration to the same struct that holds the Connection tab body (probably `ConnectionTab` or similar — use whatever exists):

```swift
@AppStorage("spawnCommand") private var spawnCommand: String = "claude"
```

- [ ] Inside the Connection tab's body, in a reasonable spot (probably near the bottom, after the existing WebSocket / network mode fields), add a labeled row:

```swift
HStack(alignment: .firstTextBaseline) {
    Text("Command to run on new window:")
        .gridColumnAlignment(.trailing)
    TextField("claude", text: $spawnCommand)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 240)
}
Text("Runs after `cd <dir>`. Leave empty for a bare shell.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

**If the existing rows use `Grid` or `Form` layouts instead of `HStack`:** match the local pattern. The goal is "one row that reads as consistent with the rest of the tab" — not a specific layout type.

### Step 4: Build QuipMac

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipMac/QuipMac.xcodeproj \
  -scheme QuipMac \
  build 2>&1 | tail -5
```

**Expected:** `** BUILD SUCCEEDED **`.

### Step 5: Install and manually verify the Settings UI

- [ ] Reinstall QuipMac the same way as Task 3 Step 5.

- [ ] Open Settings in the running Quip (Cmd+,) → navigate to the Connection tab → confirm you see:
- A new row labeled "Command to run on new window:" with a TextField next to it.
- The TextField shows `claude` as its current value (the default).
- Below the row, helper text in smaller font: "Runs after `cd <dir>`. Leave empty for a bare shell."

- [ ] Change the TextField value to something else like `vim .`. Close Settings. Reopen. Confirm the value persisted.

- [ ] Reset it back to `claude` before moving on.

### Step 6: Verify `git status`

- [ ] Run: `git status`

**Expected:** exactly one modified file — `QuipMac/Views/SettingsView.swift`.

### Step 7: Commit

- [ ] Run:

```bash
git add QuipMac/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
Put a little text field in Settings under the Connection tab so you can change what the Mac runs in a fresh iTerm window when the phone asks for a duplicate. Defaults to claude like you'd expect, but you can type whatever you want in there — vim, zsh, nothin' at all if you just want a bare shell.
EOF
)"
```

- [ ] Verify: `git log --oneline -1`

- [ ] **Do NOT push.**

---

## Task 5: iPhone UI — WindowAction enum, context menu items, alert, sendAction dispatch

**Goal:** Light up the feature end-to-end. After this commit, long-pressing a window card on the iPhone shows the two new menu items and they actually do what the spec describes.

**Files:**
- Modify: `QuipiOS/Views/WindowRectangle.swift`
- Modify: `QuipiOS/QuipApp.swift`

**IMPORTANT:** Both files must be modified and committed **together**. Swift's exhaustiveness checker in `QuipApp.swift::sendAction` will reject the build if new `WindowAction` cases are added without matching switch branches. Splitting this into two sub-commits would break the build mid-sequence.

### Step 1: Read the current state of `WindowRectangle.swift`

- [ ] Read `QuipiOS/Views/WindowRectangle.swift` in full. Confirm:

- The struct `WindowRectangle: View` has a `var onAction: ((WindowAction) -> Void)? = nil` parameter.
- The `.contextMenu` block is on the top-level view modifier chain and contains existing items that all call `triggerAction(.someCase)`.
- The `triggerAction(_:)` helper calls `onSelect()` then `onAction?(action)` — this is the "route through onSelect first so the selection and the action agree" pattern from commit `1ae6c54`.
- The `enum WindowAction` definition at the bottom of the file currently has cases: `pressReturn, cancel, viewOutput, clearTerminal, restartClaude, toggleEnabled`.
- The struct does NOT currently have any `@State` properties for alerts.

Run: `grep -n "triggerAction\|WindowAction\|@State\|contextMenu\|alert" QuipiOS/Views/WindowRectangle.swift`

### Step 2: Read the current state of `QuipApp.swift::sendAction`

- [ ] Read `QuipiOS/QuipApp.swift` around the `sendAction(windowId:action:)` function (use `grep -n "func sendAction" QuipiOS/QuipApp.swift` to find the line). Confirm:

- The function takes `windowId: String` and `action: WindowAction`.
- It has a special-case early return for `.viewOutput` that calls `onRequestContent(windowId)`.
- The rest of the function is a switch statement that maps `WindowAction` to a string and sends a `QuickActionMessage`.

### Step 3: Add new `WindowAction` enum cases

- [ ] In `QuipiOS/Views/WindowRectangle.swift`, update the `WindowAction` enum to include two new cases. The full updated enum should be:

```swift
enum WindowAction {
    case pressReturn
    case cancel
    case viewOutput
    case clearTerminal
    case restartClaude
    case toggleEnabled
    case duplicate
    case closeWindow
}
```

### Step 4: Add `@State` for the confirmation alert

- [ ] In `QuipiOS/Views/WindowRectangle.swift`, add this `@State` property to the `WindowRectangle` struct alongside any other state properties it has (or at the top of the struct, below the stored properties like `window`, `isSelected`, `onSelect`, `onAction`):

```swift
@State private var showCloseConfirmation = false
```

### Step 5: Add the Duplicate menu item at the top of the context menu

- [ ] In `QuipiOS/Views/WindowRectangle.swift`, inside the `.contextMenu { }` block, add a new Button at the **very top** (before the existing "Press Return" button). The block should now start with:

```swift
.contextMenu {
    Button {
        triggerAction(.duplicate)
    } label: {
        Label("Duplicate in new window", systemImage: "rectangle.on.rectangle")
    }

    Button {
        triggerAction(.pressReturn)
    } label: {
        Label("Press Return", systemImage: "return")
    }
    // ... rest of existing items unchanged
```

### Step 6: Add the Close menu item between the Divider and Disable/Enable Window

- [ ] In the same `.contextMenu { }` block, find the existing `Divider()` line (it's between "Restart Claude" and "Disable/Enable Window" per the current code). Insert a new destructive Button immediately after the `Divider()` and before the toggle enabled button:

```swift
    Divider()

    Button(role: .destructive) {
        showCloseConfirmation = true
    } label: {
        Label("Close terminal…", systemImage: "xmark.square")
    }

    Button {
        triggerAction(.toggleEnabled)
    } label: {
        Label(
            window.enabled ? "Disable Window" : "Enable Window",
            systemImage: window.enabled ? "eye.slash" : "eye"
        )
    }
}
```

Note: the Close button does NOT call `triggerAction(.closeWindow)` directly — it sets `showCloseConfirmation = true`. The actual dispatch happens inside the alert's Close button in the next step.

### Step 7: Add the `.alert` modifier on the view

- [ ] In `QuipiOS/Views/WindowRectangle.swift`, directly after the `.contextMenu { }` block (on the same view modifier chain), add this alert modifier:

```swift
.alert("Close terminal?", isPresented: $showCloseConfirmation) {
    Button("Cancel", role: .cancel) {}
    Button("Close", role: .destructive) {
        triggerAction(.closeWindow)
    }
} message: {
    Text("This will close \(window.name) and kill any running command. You can't undo this.")
}
```

### Step 8: Update `sendAction(windowId:action:)` in `QuipApp.swift`

- [ ] In `QuipiOS/QuipApp.swift`, replace the existing `sendAction(windowId:action:)` function body with this updated version:

```swift
private func sendAction(windowId: String, action: WindowAction) {
    if action == .viewOutput {
        onRequestContent(windowId)
        return
    }

    // Duplicate and closeWindow send different message types than
    // QuickActionMessage, so they're early-return branches.
    if action == .duplicate {
        client.send(DuplicateWindowMessage(sourceWindowId: windowId))
        return
    }
    if action == .closeWindow {
        client.send(CloseWindowMessage(windowId: windowId))
        return
    }

    let str: String
    switch action {
    case .pressReturn: str = "press_return"
    case .cancel: str = "press_ctrl_c"
    case .clearTerminal: str = "clear_terminal"
    case .restartClaude: str = "restart_claude"
    case .toggleEnabled: str = "toggle_enabled"
    case .viewOutput: return // handled above
    case .duplicate: return  // handled above
    case .closeWindow: return // handled above
    }
    client.send(QuickActionMessage(windowId: windowId, action: str))
}
```

**Note:** The early-return branches for `.viewOutput`, `.duplicate`, and `.closeWindow` look redundant with their cases in the switch, but Swift requires exhaustive switches — the cases in the switch silence the exhaustiveness warning without actually executing, and the early returns at the top are where the actual dispatch happens. This is a convention the existing codebase uses for `viewOutput`.

### Step 9: Build QuipiOS

- [ ] Run:

```bash
set -o pipefail
xcodebuild -project QuipiOS/QuipiOS.xcodeproj \
  -scheme QuipiOS \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build 2>&1 | tail -10
```

**Expected:** `** BUILD SUCCEEDED **`.

**Common failures:**
- "Switch must be exhaustive" → you added an enum case without adding a switch branch for it. Re-read Step 8 and make sure all 8 cases are in the switch.
- "Cannot find 'DuplicateWindowMessage' in scope" → Task 1's commit isn't landed. Run `git log --oneline -5` to verify Task 1's commit is in the history.
- "Cannot find 'showCloseConfirmation' in scope" → the `@State` declaration from Step 4 is in the wrong scope or has a typo.
- "Consecutive declarations on a line must be separated by ';'" → SwiftUI closure syntax error. Re-read the `.alert` block at Step 7 and confirm braces and closures are properly closed.

### Step 10: Verify iPhone device reachability

- [ ] Run:

```bash
xcrun devicectl list devices 2>&1 | grep -E "connected|available.*paired" | head -5
```

**Expected:** at least one line showing an iPhone in `connected` or `available (paired)` state. Note its UDID (the second-to-last column).

**If no iPhone is reachable**, the install step below will fail. Connect the phone via USB or pair over Wi-Fi, then retry.

### Step 11: Install QuipiOS to the iPhone

- [ ] Run (replace `<UDID>` with the UDID from Step 10):

```bash
xcrun devicectl device install app --device <UDID> \
  /Users/erickbzovi/Library/Developer/Xcode/DerivedData/QuipiOS-dzhcfnwaayimqmfypagbymeudhtl/Build/Products/Debug-iphoneos/Quip.app 2>&1 | tail -10
```

**Expected:** output ends with `App installed:` block showing `bundleID: com.quip.QuipiOS`.

**If the DerivedData path differs**, find it with: `find ~/Library/Developer/Xcode/DerivedData -type d -name "Quip.app" -path "*/Debug-iphoneos/*"`.

### Step 12: Manual test A — Duplicate with a normal path

**Precondition:** QuipMac (from Task 3) is running. At least one iTerm2 window is running `claude` in a known directory without spaces — e.g., `~/Projects/Quip`.

- [ ] Force-quit Quip on the iPhone and reopen it.
- [ ] Let it connect to the Mac. Verify the iTerm2 window appears in the window list.
- [ ] Long-press that window's card. The context menu should appear with the new item **"Duplicate in new window"** at the top (with a `rectangle.on.rectangle` icon) and **"Close terminal…"** near the bottom (red text, `xmark.square` icon, ellipsis).
- [ ] Tap **Duplicate in new window**.
- [ ] Wait ~1 second. Verify on the Mac that a **new** iTerm2 window opens, runs `cd ~/Projects/Quip`, and then runs `claude`.
- [ ] Wait another second. Verify the new window appears in the iPhone's window list.

**Pass criterion:** two iTerm2 windows now exist on the Mac, both running Claude Code in `~/Projects/Quip`, both visible in the phone's window list.

**If it fails:** open Console.app filtered by `process:Quip`. Look for `[Quip] duplicate_window:` lines. If the message never appears, the phone isn't sending it (bug in Step 8). If the message appears but is followed by `DROPPED:`, the Mac's window lookup is failing. If neither appears but nothing happens, the phone's UI layer isn't firing `triggerAction(.duplicate)` (bug in Step 5 or 3).

### Step 13: Manual test B — Duplicate with a path containing spaces

- [ ] On the Mac, create a test directory with spaces: `mkdir -p "/tmp/My Test Dir"`
- [ ] In iTerm2, manually `cd "/tmp/My Test Dir"` and run `claude`.
- [ ] Wait for the phone's window list to refresh (~2 seconds). Verify the new window appears.
- [ ] Long-press that card on the phone → tap **Duplicate in new window**.
- [ ] Verify a new iTerm2 window opens, `cd`s to `/tmp/My Test Dir`, and runs `claude`.

**Pass criterion:** the `cd` lands in the spaced directory, not in `~` or a parent directory.

### Step 14: Manual test C — Duplicate with `spawnCommand = ""`

- [ ] On the Mac, open Quip Settings → Connection tab.
- [ ] Clear the "Command to run on new window" text field so it's empty. Close Settings.
- [ ] On the phone, long-press any tracked iTerm2 window → Duplicate in new window.
- [ ] Verify the new iTerm2 window opens, `cd`s to the directory, and lands in a **bare shell** — no `claude` running.
- [ ] Reset the Settings field to `claude` before continuing.

### Step 15: Manual test D — Duplicate rapidly 3 times

- [ ] Long-press any tracked iTerm2 window → Duplicate in new window. Immediately long-press again → Duplicate. Immediately long-press again → Duplicate.
- [ ] Verify **three** new iTerm2 windows open within ~3 seconds.
- [ ] Verify all three appear in the phone's window list on the next refresh.

### Step 16: Manual test E — Close with Cancel

- [ ] Long-press any iTerm2 window on the phone → tap **Close terminal…**.
- [ ] The native iOS alert should appear with title "Close terminal?", a message naming the window (e.g., "This will close /tmp/My Test Dir and kill any running command..."), a blue **Cancel** button, and a red **Close** button.
- [ ] Tap **Cancel**.
- [ ] Verify the alert dismisses and **nothing else happens** — the window stays open on the Mac, still in the phone list.

### Step 17: Manual test F — Close with confirmation

- [ ] Long-press one of the test iTerm2 windows (ideally one you're OK destroying) → tap **Close terminal…** → tap **Close** in the alert.
- [ ] Verify within ~1 second the iTerm2 window disappears from the Mac.
- [ ] Verify within ~1 second the window disappears from the phone's window list.

**Pass criterion:** the window is actually gone, not just hidden.

### Step 18: Manual test G — Close while Claude is mid-response

- [ ] In an iTerm2 window running Claude Code, type a prompt that takes a while ("Write a detailed essay about the history of...").
- [ ] While Claude is writing, long-press that window on the phone → Close terminal… → Close in the alert.
- [ ] Verify the window closes even though Claude was in the middle of a response. Claude's process is killed.

### Step 19: Manual test H — Close an already-closed window

- [ ] On the Mac, manually close an iTerm2 window by clicking its red X — don't tell the phone.
- [ ] **Before** the phone's window list refreshes (which takes ~1–2 seconds), long-press the now-stale card on the phone → Close terminal… → Close.
- [ ] Open Console.app filtered by `process:Quip`. Expected: a `[Quip] close_window DROPPED: unknown windowId=...` line.
- [ ] No crash, no error dialog, no phone-side weirdness.

### Step 20: Verify `git status`

- [ ] Run: `git status`

**Expected:** exactly two modified files — `QuipiOS/Views/WindowRectangle.swift` and `QuipiOS/QuipApp.swift`. No regenerated `Info.plist` or `pbxproj` (neither project.yml was touched).

### Step 21: Commit

- [ ] Run:

```bash
git add QuipiOS/Views/WindowRectangle.swift QuipiOS/QuipApp.swift
git commit -m "$(cat <<'EOF'
Stuck them two new items on the phone's long-press menu — "Duplicate in new window" up top and "Close terminal..." at the bottom (red). Duplicate pops open a fresh iTerm in the same folder and runs whatever the Mac Settings say to run. Close fires a native iOS alert first that names the exact window you're about to kill, so you don't smash the wrong one by accident. The whole feature's lit up end-to-end after this one.
EOF
)"
```

- [ ] Verify: `git log --oneline -5`

**Expected:** the five most recent commits are Tasks 1–5 in order.

- [ ] **Do NOT push** without user confirmation.

---

## Out-of-Scope (do NOT implement as part of this plan)

These are intentionally left unimplemented per the spec's non-goals section:

- ❌ **Terminal.app support.** `spawnWindow` and `closeWindow` return an error for `.terminal`. If you find yourself adding an iTerm2 / Terminal.app branch split, stop — that's a wishlist follow-up.
- ❌ **QuipLinux / QuipAndroid parity.** The feature is iPhone-only.
- ❌ **Smart spawn-command defaults** based on project folder detection (`package.json`, `.venv`, etc.).
- ❌ **Landscape `TerminalContentOverlay` parity.** Portrait long-press only.
- ❌ **Favorites directory picker.** Option A (duplicate) was chosen over Option B (favorites).
- ❌ **Optimistic UI** — no immediate card removal on Close confirmation. Wait for `LayoutUpdate`.
- ❌ **Undo / trash / soft-delete.** Destructive is destructive.
- ❌ **Confirmation-skip preference.** Start strict.
- ❌ **Retry logic** on spawn or close failures. Soft-fail with logs is the v1 model.

If during implementation you find yourself wanting any of the above, stop and ask the user.

---

## Commit Plan Summary

**Total commits:** 5

| # | Commit | Files | Cherry-pick safe? |
|---|---|---|---|
| 1 | Wire protocol — new message types | `Shared/MessageProtocol.swift` | Yes, standalone |
| 2 | KeystrokeInjector methods | `QuipMac/Services/KeystrokeInjector.swift` | Yes, standalone (after #1 for decoded types, but those live in a shared file already) |
| 3 | Mac handler cases | `QuipMac/QuipMacApp.swift` | Needs #1 and #2 |
| 4 | Settings spawnCommand field | `QuipMac/Views/SettingsView.swift` | Independent; ordering flexible |
| 5 | iPhone context menu + dispatcher | `QuipiOS/Views/WindowRectangle.swift` + `QuipiOS/QuipApp.swift` | Needs #1; best if #2, #3 also present so end-to-end works |

Cherry-pick order from jboert's perspective: `1 → 2 → 3 → 4 → 5`. Each commit is independently buildable; only commit 5 makes the feature user-visible.

Every commit message is blue-collar boomer voice per project `CLAUDE.md`, doubling as release-note-quality context for a reviewer.
