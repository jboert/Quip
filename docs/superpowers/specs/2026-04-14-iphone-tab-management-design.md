# iPhone Tab Management — Open/Close iTerm2 Windows from the Remote

Add iPhone-initiated spawning and closing of iTerm2 windows via a long-press context menu on window cards. The phone never types a directory path; new windows inherit the directory from the window you long-pressed.

## Overview

Currently, the iPhone remote can only control iTerm2 windows that were already open on the Mac before Quip started tracking them. If the user wants a new Claude Code session while on the road, they have no way to start one from the phone. If they want to close a session, they can only stop tracking it in Quip (via the Mac-side UI), not actually close the terminal.

This spec adds two actions to the existing long-press context menu on every window card:

1. **Duplicate in new window** — spawns a new iTerm2 window in the same directory as the long-pressed source, running a configured command (default `claude`). Zero typing on the phone.
2. **Close terminal…** — actually closes the underlying iTerm2 window, killing any running command. Fires a native iOS confirmation alert first.

**User intent**: "I'm on the road and I need another Claude Code session / I'm done with this one and want to reclaim the screen space."

## Scope Constraint: Windows, Not Tabs

Quip's `WindowManager` identifies trackable entities by `CGWindowID`, and iTerm2 tabs inside the same window share a single `CGWindowID`. Therefore, new sessions spawned from the phone must open as **new iTerm2 windows**, not as new tabs inside an existing window — otherwise they won't appear as separate targets in the phone's window list. The feature is colloquially named "tab management," but the implementation always creates windows.

## Scope Constraint: Window List Layout Unchanged

The iPhone's existing window-list layout — **vertical cards stacked top-to-bottom** — is preserved. This feature adds context menu items to each existing card; it does NOT introduce a new grid view, horizontal scroller, or any other arrangement. Alternative arrangements (grid, compact, carousel) are a separate follow-up feature captured as a wishlist item for later brainstorming. Keeping the layout stable during this feature means the only visual change is the addition of two menu items inside an already-existing long-press menu.

## Protocol Changes

Two new message types added to `Shared/MessageProtocol.swift`, following the existing `Codable, Sendable` struct pattern:

```swift
/// iPhone → Mac. Asks the Mac to spawn a new iTerm2 window in the same
/// working directory as the source window, running the configured command.
struct DuplicateWindowMessage: Codable, Sendable {
    let type: String       // always "duplicate_window"
    let sourceWindowId: String

    init(sourceWindowId: String) {
        self.type = "duplicate_window"
        self.sourceWindowId = sourceWindowId
    }
}

/// iPhone → Mac. Asks the Mac to actually close a specific iTerm2 window
/// (destructive — kills any running command in that session).
struct CloseWindowMessage: Codable, Sendable {
    let type: String       // always "close_window"
    let windowId: String

    init(windowId: String) {
        self.type = "close_window"
        self.windowId = windowId
    }
}
```

**No response messages.** Both actions are observable via the existing `LayoutUpdate` broadcast that Quip's `WindowManager` already sends whenever the window list changes. After a successful spawn, the new window appears in the next `LayoutUpdate`; after a successful close, the target window disappears. This avoids adding acknowledgement plumbing.

**Failure handling** is intentionally soft: if the Mac can't find the source or target window (stale `windowId`), the handler logs the drop via the `[Quip]` diagnostic pattern from commit `67898b9` and silently returns. The phone sees no change and the user re-taps if needed.

**Backwards compatibility**: old Mac builds hit the `default: break` case in `handleIncomingMessage` and silently ignore the new message types. The diagnostic logging added in commit `67898b9` surfaces unknown types in Console.app, so mismatched builds are visible.

## iPhone Changes

Single file: `QuipiOS/Views/WindowRectangle.swift`. The existing `.contextMenu` block (lines 109–150 per earlier exploration) is extended with two new items and one alert modifier.

### Context menu additions

**At the top of the menu** (primary affordance, visually distinct with an SF Symbol icon):

```swift
Button {
    client.send(DuplicateWindowMessage(sourceWindowId: window.id))
} label: {
    Label("Duplicate in new window", systemImage: "rectangle.on.rectangle")
}
```

**At the bottom of the menu**, separated by a `Divider()` and marked destructive:

```swift
Divider()
Button(role: .destructive) {
    showCloseConfirmation = true
} label: {
    Label("Close terminal…", systemImage: "xmark.square")
}
```

The ellipsis (`…`) and `role: .destructive` (red text) signal "dangerous action, confirmation required."

### Confirmation alert

New `@State private var showCloseConfirmation = false` on `WindowRectangle`. Attached via `.alert` modifier:

```swift
.alert("Close terminal?", isPresented: $showCloseConfirmation) {
    Button("Cancel", role: .cancel) {}
    Button("Close", role: .destructive) {
        client.send(CloseWindowMessage(windowId: window.id))
    }
} message: {
    Text("This will close \(window.name) and kill any running command. You can't undo this.")
}
```

The alert message names the specific window by its title so the user knows exactly what they're about to kill.

### Explicit non-goals on the iPhone side

- No top-level toolbar buttons — the compact UI rule (per `feedback_compact_ui.md` in memory) says new controls should live in existing rows or menus, not new chrome.
- No optimistic UI — the phone doesn't immediately remove a card when Close is confirmed. It waits for the authoritative `LayoutUpdate` from the Mac. Slower (~500ms) but always consistent with server state.
- No undo / trash / soft-delete. Destructive is destructive.
- No landscape (`TerminalContentOverlay`) version of these actions in v1 — portrait context menu only. Follow-up wishlist item.

## Mac Changes

### A. `@AppStorage("spawnCommand")` setting

Added to `QuipMac/Views/SettingsView.swift`:

```swift
@AppStorage("spawnCommand") private var spawnCommand: String = "claude"
```

- UI: single `TextField("claude", text: $spawnCommand)` labeled "Command to run on new window", with help text "Runs after `cd <dir>`. Leave empty for a bare shell."
- Default: `claude`.
- Storage: `UserDefaults`, survives app restarts.
- No validation — free-form shell string, user's responsibility.

### B. Two new cases in `handleIncomingMessage`

Added to `QuipMac/QuipMacApp.swift::handleIncomingMessage` following the same logging pattern as commit `67898b9`:

```swift
case "duplicate_window":
    if let msg = MessageCoder.decode(DuplicateWindowMessage.self, from: data) {
        print("[Quip] duplicate_window: sourceWindowId=\(msg.sourceWindowId)")
        if let source = windowManager.windows.first(where: { $0.id == msg.sourceWindowId }) {
            // subtitle is documented as "Directory path or secondary info" — so
            // it might be empty, or it might be non-path text like "idle". Only
            // treat it as a directory if it looks like one.
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
        } else {
            let known = windowManager.windows.map { $0.id }
            print("[Quip] close_window DROPPED: unknown windowId=\(msg.windowId). Known: \(known)")
        }
    }
```

Note that `closeWindow` takes a **window title** (`window.name`), not a `CGWindowID`. This is because iTerm2's AppleScript `id of window` doesn't return a `CGWindowID` — it returns iTerm2's own internal window identifier, as proven empirically in the session leading to commit `24e820f`. Matching by title is less elegant but actually works. Documented risk: if two iTerm2 windows share a title, the close closes the first match (wishlist item for proper AX-handle-based resolution).

### C. Two new `KeystrokeInjector` methods

Added to `QuipMac/Services/KeystrokeInjector.swift`:

#### `spawnWindow(in:command:terminalApp:)`

Generalization of the existing `spawnTerminal(in:terminalApp:)` that takes a configurable command. The existing `spawnTerminal` stays unchanged for backwards compatibility with any other callers.

**iTerm2 branch** — creates a new window (not tab) and writes the composed `cd && command` line to its current session:

```applescript
tell application "iTerm2"
    activate
    create window with default profile
    tell current session of current window
        write text "<composed command>"
    end tell
end tell
```

Where `<composed command>` is built in Swift before script generation:
- If `command` is empty → `cd "<escaped dir>"`
- Otherwise → `cd "<escaped dir>" && <escaped command>`

**Terminal.app branch** — out of scope for v1 (wishlist item). If called with `.terminal`, returns an error result.

#### `closeWindow(windowName:terminalApp:)`

**iTerm2 branch** — iterates iTerm2's windows, matches by title, closes the first match:

```applescript
tell application "iTerm2"
    try
        repeat with w in windows
            if name of w is "<escaped window name>" then
                close w
                return
            end if
        end repeat
    end try
end tell
```

The `<escaped window name>` placeholder runs the raw `ManagedWindow.name` through **`escapeForAppleScript` only** (NOT `escapeForShell`), because it's an AppleScript string literal, not a shell fragment. No `cd` or shell interpretation happens here.

**Terminal.app branch** — out of scope for v1, returns an error result.

### D. New `escapeForShell` helper

Added to `KeystrokeInjector.swift` alongside the existing `escapeForAppleScript`:

```swift
/// Escape a string for safe interpolation into a shell command that's
/// itself embedded in an AppleScript `write text` or `do script` call.
/// Handles backslashes, double-quotes, dollar signs, and backticks.
private func escapeForShell(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
}
```

The composed `cd "..." && command` string is passed through **both** `escapeForShell` (for shell metacharacter safety) **and** `escapeForAppleScript` (for AppleScript string-literal safety) before being interpolated into the AppleScript source.

### E. No changes to `WindowManager`

The existing auto-refresh loop picks up new windows and drops closed ones within ~1 second. No new tracking logic required.

## Edge Cases

1. **Source window has empty `subtitle`** — fall back to `NSHomeDirectory()`. Log a warning.
1a. **Source window `subtitle` is not a directory path** — `ManagedWindow.subtitle` is documented as "Directory path *or secondary info*" in `WindowManager.swift`, so the field might hold something like `"idle"`, a process name, or other non-path text. Validate by checking if the value begins with `/` or `~` (absolute path or tilde-home path); if it doesn't match, fall back to `NSHomeDirectory()` the same way the empty case does. Log the unexpected value so a future fix can handle it properly.
2. **Directory contains spaces or special characters** — `escapeForShell` + `escapeForAppleScript` double-pass. Example: `~/My Projects/foo bar` survives both layers of quoting.
3. **Configured command contains spaces or flags** — same escaping path. `spawnCommand = "claude --resume"` works.
4. **Close fired on an already-dead window** — Mac-side window lookup returns nil. Handler logs `[Quip] close_window DROPPED: unknown windowId=...`. User sees no change. Effectively a no-op.
5. **Close matches multiple iTerm2 windows with the same title** — first match wins. Documented risk; wishlist item for proper handle-based resolution.
6. **Rapid repeated Duplicate taps** — no debouncing. Each tap produces a new window.
7. **Duplicate fails to spawn** — most likely cause is iTerm2 being force-killed. `spawnWindow` activates iTerm2 first, which launches it if not running. If the AppleScript fails, `executeAppleScript` already logs the error via the `[KeystrokeInjector]` prefix.
8. **Stale directory from source window** — if the user `cd`'d inside the source iTerm2 window *after* Quip last refreshed its `subtitle`, the new window opens in the cached directory, not the current one. Accepted limitation; wishlist item for live subtitle reads.

## Out of Scope (v1)

- **Terminal.app support** — iTerm2 only. The `spawnWindow` and `closeWindow` methods return an error when called with `.terminal`.
- **QuipLinux and QuipAndroid** — iPhone client only.
- **Smart spawn-command defaults based on project folder** (e.g., detecting `package.json`, `.venv`, `.claude/sessions/` and suggesting an appropriate command) — this was explicitly flagged as a wishlist follow-up; user wants the foundation first, smart defaults later.
- **Tab-in-same-window spawning** — architectural constraint, explained above.
- **Favorites directory picker** — the user picked "duplicate" in Q1 over a favorites list; favorites are a wishlist follow-up if needed.
- **Confirmation-skip preference** ("don't ask me again" on Close) — start strict, tune later.
- **Landscape context-menu parity** — the landscape `TerminalContentOverlay` doesn't have these actions in v1. Wishlist follow-up once portrait is proven.
- **Undo / soft-delete / recent-close list** — matches the destructive model.

## Testing

Manual only. The feature is a thin UI + message + AppleScript layer; unit tests would mostly mock out the interesting parts.

**Manual test matrix:**

1. **Duplicate with a normal path** (no spaces): confirm a new iTerm2 window appears, is `cd`'d to the right directory, and runs `claude`.
2. **Duplicate with a path containing spaces**: rename a test directory to `~/My Test Dir`, duplicate the Quip-tracked window for it, verify `cd` lands in the right place.
3. **Duplicate with `spawnCommand = ""` (empty)**: verify the new window lands in a bare shell at the correct directory, no `claude`.
4. **Duplicate with `spawnCommand = "vim ."`**: verify vim opens in the target directory.
5. **Duplicate rapidly 3 times**: verify 3 new windows appear.
6. **Close a window, tap Cancel on the alert**: nothing happens.
7. **Close a window, tap Close on the alert**: window disappears from Mac and from the phone's list within ~1 second.
8. **Close a window while Claude is mid-response**: confirm the alert warns about killing a running command; confirm closing actually kills Claude as expected.
9. **Close a window, then immediately try to close it again**: second attempt should log `[Quip] close_window DROPPED: unknown windowId=...` and do nothing gracefully.

## Commit Plan

Split into five cherry-pickable commits so jboert can review and pull each layer independently:

**Commit 1** — `Shared/MessageProtocol.swift` only. New `DuplicateWindowMessage` and `CloseWindowMessage` structs. Compiles, no callers yet. Safe cherry-pick target.

**Commit 2** — `QuipMac/Services/KeystrokeInjector.swift`. New `spawnWindow(in:command:terminalApp:)` and `closeWindow(windowName:terminalApp:)` methods plus the `escapeForShell` helper. Standalone, no upstream callers yet. Builds successfully.

**Commit 3** — `QuipMac/QuipMacApp.swift`. New `duplicate_window` and `close_window` cases in `handleIncomingMessage`. After this commit, the Mac handles both new messages end-to-end, but the phone doesn't send them yet.

**Commit 4** — `QuipMac/Views/SettingsView.swift`. The `spawnCommand` text field in the Settings UI. Independent from the spawn logic (the default `"claude"` is already baked into commit 3's fallback), so this commit is purely a UI addition.

**Commit 5** — `QuipiOS/Views/WindowRectangle.swift`. Two new context-menu items and the confirmation alert. Feature lights up end-to-end after this commit.

Five commits, cherry-pick order: 1 → 2 → 3 → 4 → 5.

Each commit gets a blue-collar-voice message that doubles as a release note, per project convention.

## Wishlist Items to Add When Committing

- **Smart spawn-command defaults based on project folder detection** (detect `package.json`, `.venv`, `.claude/sessions/`, etc. and suggest appropriate commands automatically).
- **Terminal.app support for `spawnWindow` and `closeWindow`**.
- **Favorites directory picker** — configurable project list on the Mac, iPhone picks from it when not duplicating.
- **Landscape parity** — mirror the context menu actions into `TerminalContentOverlay`.
- **Proper window-handle-based close resolution** — use AX APIs instead of title matching to handle the multi-window-same-title case robustly.
- **Live `subtitle` reads** — refresh a window's directory from iTerm2's current working directory before spawning, so stale directory caching doesn't matter.
