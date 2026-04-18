# iTerm2 Session `unique id` Targeting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Mac-side `KeystrokeInjector` so iPhone-originated keystrokes, text, and content reads target the correct iTerm2 window when multiple are open — by caching each iTerm2 session's stable `unique id` (UUID) on `ManagedWindow` at registration time and using it to address AppleScript commands to a specific session, instead of the broken `id of w is <cgWindowNumber>` match that never fires.

**Architecture:** Add an optional `iterm2SessionId: String?` field to the Mac-side `ManagedWindow` struct. After `applyWindowSnapshot` builds the window list, run an AppleScript probe that returns `[(windowTitle, sessionUUID)]` for every current iTerm2 session, then match each iTerm2 `ManagedWindow` entry to its session by window title (the only reliable cross-reference given that `id of w` isn't a CGWindowID). Extend `sendText` / `sendKeystroke` / `readContent` in `KeystrokeInjector` with an optional `iterm2SessionId` parameter and rewrite their iTerm2 AppleScript branches to select by `unique id of s` when a session id is supplied. Thread the cached session id from `ManagedWindow` through every `QuipMacApp.swift` call site that invokes those three functions. No protocol changes, no iOS changes.

**Tech Stack:** Swift 6, AppleScript via `NSAppleScript`, XCTest, XcodeGen, `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-04-15-iterm2-session-id-targeting-design.md`

**Worktree note:** Execute directly on `eb-branch`. Work is scoped to 4 files and lands as a single commit.

**Do NOT push.** Per `eb-branch` push policy, the commit stays local unless the user explicitly confirms a push.

**Empirical baseline (verified during brainstorming):** `screencapture -l 1159` (where `1159` was iTerm2's `id of w` for a real iTerm2 window) failed with "could not create image from window". That confirms `id of w` is NOT a CGWindowID. Session `unique id` returns UUID strings like `"7998FEE3-6F7C-4CF4-9637-9C58B7A5439D"`. Window titles are unique in practice (e.g. `⠂ resume-keeping-in-touch-slice` vs `Default (-zsh) — Mac-Studio23.local:~/Projects/credit-unions  — 110✕60`).

---

## Task 1: Pre-flight state verification

**Purpose:** Confirm the working tree is clean, existing tests pass, base SHA is recorded, and the two iTerm2 windows required for the manual verification step exist.

**Files:**
- Read-only inspection

- [ ] **Step 1.1: Verify working tree is clean**

Run:
```bash
git status
```

Expected: `nothing to commit, working tree clean`. If not clean, stop and clean up first.

- [ ] **Step 1.2: Capture base SHA**

Run:
```bash
git rev-parse HEAD
```

Record the SHA as `BASE_SHA` — this is the pre-fix starting point that the post-commit diff will reference.

- [ ] **Step 1.3: Verify QuipMacTests baseline is green**

Run:
```bash
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "Test Suite|TEST SUCCEEDED|TEST FAILED|error:" | tail -10
```

Expected: `** TEST SUCCEEDED **` and 40 MessageProtocol tests passing. If any test fails, STOP — the baseline is broken and we shouldn't layer more changes on top.

- [ ] **Step 1.4: Verify ≥ 2 iTerm2 windows are open (for manual test later)**

Run:
```bash
osascript -e 'tell application "iTerm2" to count windows'
```

Expected: a number ≥ 2. If it's 0 or 1, open another iTerm2 window manually before proceeding to Task 10's manual test matrix — the whole point of this fix is multi-window, so a single-window verification proves nothing.

- [ ] **Step 1.5: Record current iTerm2 window metadata for reference**

Run:
```bash
osascript -e 'tell application "iTerm2"
    repeat with w in windows
        log "-- window --"
        log ("id: " & (id of w as string))
        log ("name: " & (name of w as string))
        tell current session of w
            log ("unique id: " & (unique id as string))
        end tell
    end repeat
end tell' 2>&1
```

Expected: for each open iTerm2 window, a small-integer `id`, a distinctive `name`, and a UUID-format `unique id`. Note the values — you'll compare them against the post-fix state in Task 10.

---

## Task 2: Add `iterm2SessionId` field to `ManagedWindow`

**Purpose:** Add the new optional field to the struct, default to nil, non-breaking for existing callers.

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift`

- [ ] **Step 2.1: Edit `ManagedWindow` struct definition (explicit find-and-replace)**

Use the Edit tool with this replacement in `QuipMac/Services/WindowManager.swift`:

**Find** (exactly this 13-line block — the current struct header through `bounds`):

```swift
struct ManagedWindow: Identifiable, Sendable {
    let id: String                // Unique identifier (bundleId + windowNumber)
    let name: String              // Window title
    let app: String               // Application name
    var subtitle: String          // Directory path or secondary info
    let bundleId: String          // Application bundle identifier
    let icon: NSImage?            // App icon (non-Sendable but only used on MainActor)
    var isEnabled: Bool           // Whether this window participates in layouts
    var assignedColor: String     // Hex color from palette
    let pid: pid_t                // Process ID
    let windowNumber: CGWindowID  // CG window number
    var bounds: CGRect            // Current window frame
```

**Replace with** (14 lines — adds the new field after `bounds`):

```swift
struct ManagedWindow: Identifiable, Sendable {
    let id: String                // Unique identifier (bundleId + windowNumber)
    let name: String              // Window title
    let app: String               // Application name
    var subtitle: String          // Directory path or secondary info
    let bundleId: String          // Application bundle identifier
    let icon: NSImage?            // App icon (non-Sendable but only used on MainActor)
    var isEnabled: Bool           // Whether this window participates in layouts
    var assignedColor: String     // Hex color from palette
    let pid: pid_t                // Process ID
    let windowNumber: CGWindowID  // CG window number
    var bounds: CGRect            // Current window frame
    var iterm2SessionId: String?  // iTerm2 session UUID (only populated for iTerm2 windows where probe succeeded)
```

- [ ] **Step 2.2: Verify the edit compiled (syntax-only via swiftc)**

Compilation will happen as part of the broader Mac build in Task 9. For now, just visually scan the file around the struct definition to confirm the new field is in place and no braces got mangled.

Run:
```bash
grep -n "iterm2SessionId" QuipMac/Services/WindowManager.swift
```

Expected: one match at the struct definition line showing `var iterm2SessionId: String?`.

---

## Task 3: Update `applyWindowSnapshot` to carry `iterm2SessionId` across refreshes

**Purpose:** The existing `applyWindowSnapshot` merges new raw window data with previously-known window state to preserve `isEnabled`, `assignedColor`, and `subtitle` across refreshes. We need the same preservation for `iterm2SessionId` — otherwise every refresh blanks it out.

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift`

- [ ] **Step 3.1: Edit both `ManagedWindow(...)` constructor calls in `applyWindowSnapshot`**

Use the Edit tool with this replacement in `QuipMac/Services/WindowManager.swift`:

**Find** (exactly this 18-line block — both constructor calls inside `applyWindowSnapshot`):

```swift
        for info in raw {
            let icon = NSRunningApplication(processIdentifier: info.pid)?.icon
            if let existing = windows.first(where: { $0.id == info.id }) {
                refreshed.append(ManagedWindow(
                    id: info.id, name: info.name, app: info.app,
                    subtitle: existing.subtitle, bundleId: info.bundleId, icon: icon,
                    isEnabled: existing.isEnabled, assignedColor: existing.assignedColor,
                    pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds
                ))
            } else {
                refreshed.append(ManagedWindow(
                    id: info.id, name: info.name, app: info.app,
                    subtitle: "", bundleId: info.bundleId, icon: icon,
                    isEnabled: false, assignedColor: assignColor(),
                    pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds
                ))
            }
        }
```

**Replace with** (20 lines — adds `iterm2SessionId` to both constructor calls, preserving the existing value on the merge branch):

```swift
        for info in raw {
            let icon = NSRunningApplication(processIdentifier: info.pid)?.icon
            if let existing = windows.first(where: { $0.id == info.id }) {
                refreshed.append(ManagedWindow(
                    id: info.id, name: info.name, app: info.app,
                    subtitle: existing.subtitle, bundleId: info.bundleId, icon: icon,
                    isEnabled: existing.isEnabled, assignedColor: existing.assignedColor,
                    pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds,
                    iterm2SessionId: existing.iterm2SessionId
                ))
            } else {
                refreshed.append(ManagedWindow(
                    id: info.id, name: info.name, app: info.app,
                    subtitle: "", bundleId: info.bundleId, icon: icon,
                    isEnabled: false, assignedColor: assignColor(),
                    pid: info.pid, windowNumber: info.windowNumber, bounds: info.bounds,
                    iterm2SessionId: nil
                ))
            }
        }
```

- [ ] **Step 3.2: Verify both call sites updated**

Run:
```bash
grep -c "iterm2SessionId:" QuipMac/Services/WindowManager.swift
```

Expected: at least `3` (one from the struct field declaration, two from the two constructor call sites).

---

## Task 4: Add `fetchIterm2SessionIds()` static method to `WindowManager`

**Purpose:** A `nonisolated static` method (mirroring the shape of `fetchSubtitles`) that runs an AppleScript probe against iTerm2 and returns a dictionary keyed by window title, valued by the current session's unique id. Called from any thread; doesn't block main.

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift`

- [ ] **Step 4.1: Add the `fetchIterm2SessionIds()` method below `fetchSubtitles()`**

Use the Edit tool with this replacement in `QuipMac/Services/WindowManager.swift`:

**Find** (the closing brace of `fetchSubtitles()` followed by the blank line and `/// Apply pre-fetched subtitles` comment — this is the unique anchor that marks the end of `fetchSubtitles`):

```swift
        return result
    }

    /// Apply pre-fetched subtitles to windows. Call on main.
```

**Replace with** (adds the new `fetchIterm2SessionIds` method before `applySubtitles`):

```swift
        return result
    }

    /// Fetch iTerm2 session unique ids for all current windows, keyed by window title.
    /// Runs off-main because `NSAppleScript` can block for ~10-50ms per iTerm2 window.
    ///
    /// Returns `[windowTitle: sessionUUID]`. Window titles are used as the match key
    /// because iTerm2's AppleScript `id of window` returns iTerm2's internal window
    /// identifier, NOT a `CGWindowID` — so we can't match by CGWindowID (empirically
    /// verified during the #13 spec, and noted in `KeystrokeInjector.swift:427-441`).
    /// Title matching is reliable when window titles are distinct (the common case);
    /// when two windows share a title, the first one wins and the second gets nil.
    /// That's strictly no worse than the pre-fix "always front window" fallback.
    nonisolated static func fetchIterm2SessionIds() -> [String: String] {
        var result: [String: String] = [:]
        let script = """
        set output to ""
        tell application "iTerm2"
            repeat with w in windows
                set winName to name of w
                tell current session of w
                    set uid to unique id
                end tell
                set output to output & winName & "\\t" & uid & linefeed
            end repeat
        end tell
        return output
        """

        guard let appleScript = NSAppleScript(source: script) else { return result }
        var error: NSDictionary?
        let asResult = appleScript.executeAndReturnError(&error)
        guard error == nil, let output = asResult.stringValue else { return result }

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { continue }
            let name = parts[0]
            let uuid = parts[1]
            // On duplicate title, keep the first match. Document deliberately.
            if result[name] == nil {
                result[name] = uuid
            }
        }
        return result
    }

    /// Apply pre-fetched subtitles to windows. Call on main.
```

- [ ] **Step 4.2: Verify the method compiles and the signature is right**

Run:
```bash
grep -A 2 "func fetchIterm2SessionIds" QuipMac/Services/WindowManager.swift
```

Expected: the method signature line plus its opening brace visible. The `nonisolated static func fetchIterm2SessionIds() -> [String: String]` line must match exactly.

---

## Task 5: Add `applyIterm2SessionIds(_:)` main-actor method

**Purpose:** Main-actor method that takes the `[String: String]` dictionary from Task 4 and mutates `windows` to set `iterm2SessionId` on every iTerm2 entry whose title matches.

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift`

- [ ] **Step 5.1: Add `applyIterm2SessionIds` after `applySubtitles`**

Use the Edit tool with this replacement in `QuipMac/Services/WindowManager.swift`:

**Find** (the closing brace of `applySubtitles` plus the closing brace of the class — the tail of the file):

```swift
        // Terminal.app — extract from window name
        for i in windows.indices where windows[i].bundleId == "com.apple.Terminal" {
            let name = windows[i].name
            if name.contains("—") {
                let parts = name.components(separatedBy: "—").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2 {
                    let pathPart = parts[1]
                    windows[i].subtitle = (pathPart as NSString).lastPathComponent
                }
            }
        }
    }
}
```

**Replace with** (adds `applyIterm2SessionIds` before the final two closing braces):

```swift
        // Terminal.app — extract from window name
        for i in windows.indices where windows[i].bundleId == "com.apple.Terminal" {
            let name = windows[i].name
            if name.contains("—") {
                let parts = name.components(separatedBy: "—").map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2 {
                    let pathPart = parts[1]
                    windows[i].subtitle = (pathPart as NSString).lastPathComponent
                }
            }
        }
    }

    /// Apply pre-fetched iTerm2 session UUIDs to windows. Call on main.
    /// Looks up each iTerm2 window by title and sets its `iterm2SessionId`.
    /// Terminal.app windows and unmatched iTerm2 windows retain whatever value
    /// they had before (nil for fresh windows).
    func applyIterm2SessionIds(_ sessionIds: [String: String]) {
        for i in windows.indices where windows[i].bundleId == TerminalApp.iterm2.bundleIdentifier {
            if let uuid = sessionIds[windows[i].name] {
                windows[i].iterm2SessionId = uuid
            }
        }
    }
}
```

- [ ] **Step 5.2: Verify both methods are now present**

Run:
```bash
grep -cE "func fetchIterm2SessionIds|func applyIterm2SessionIds" QuipMac/Services/WindowManager.swift
```

Expected: exactly `2`.

---

## Task 6: Wire the probe into the refresh flow

**Purpose:** Find where `refreshSubtitles` is called from the window-refresh pipeline and add a parallel `refresh` path for iTerm2 session ids.

**Files:**
- Modify: `QuipMac/Services/WindowManager.swift` (add a new convenience method)
- Modify: `QuipMac/QuipMacApp.swift` (the call site that triggers the refresh)

- [ ] **Step 6.1: Find where `refreshSubtitles` is called**

Run:
```bash
grep -rn "refreshSubtitles\|fetchSubtitles\|applySubtitles" QuipMac/ --include="*.swift"
```

Record the file(s) and line number(s) where the refresh currently happens — typically `QuipMacApp.swift` has a timer-triggered refresh loop or `applyWindowSnapshot`-completion handler that calls `refreshSubtitles`. This is where the new `refreshIterm2SessionIds` call will live, right next to the existing `refreshSubtitles` call.

- [ ] **Step 6.2: Add `refreshIterm2SessionIds` convenience method to WindowManager**

Use the Edit tool with this replacement in `QuipMac/Services/WindowManager.swift`:

**Find** (the existing `refreshSubtitles` method — 4 lines):

```swift
    /// Query iTerm2 and Terminal.app for current session paths and update subtitles.
    func refreshSubtitles() {
        let subs = Self.fetchSubtitles()
        applySubtitles(subs)
    }
```

**Replace with** (adds a parallel `refreshIterm2SessionIds` method immediately after):

```swift
    /// Query iTerm2 and Terminal.app for current session paths and update subtitles.
    func refreshSubtitles() {
        let subs = Self.fetchSubtitles()
        applySubtitles(subs)
    }

    /// Query iTerm2 for current session UUIDs and update `iterm2SessionId` on matching
    /// windows. Separate from `refreshSubtitles` because the two run different
    /// AppleScripts and it's cheaper to update them independently on different cadences.
    func refreshIterm2SessionIds() {
        let sessionIds = Self.fetchIterm2SessionIds()
        applyIterm2SessionIds(sessionIds)
    }
```

- [ ] **Step 6.3: Add the `refreshIterm2SessionIds` call in `QuipMacApp.swift` alongside `refreshSubtitles`**

This step requires looking at the file found in Step 6.1. The edit is: find the line that calls `windowManager.refreshSubtitles()` and add `windowManager.refreshIterm2SessionIds()` immediately after it. Example shape (actual surrounding code may vary):

**Find** (this template — the actual surrounding lines depend on the context found in Step 6.1):

```swift
                windowManager.refreshSubtitles()
```

**Replace with**:

```swift
                windowManager.refreshSubtitles()
                windowManager.refreshIterm2SessionIds()
```

If `refreshSubtitles` is called from multiple locations, add the `refreshIterm2SessionIds` call at each one. The two refreshes should happen together so the window metadata (subtitle + session id) stays in sync.

- [ ] **Step 6.4: Verify the call site addition**

Run:
```bash
grep -cE "refreshIterm2SessionIds|refreshSubtitles" QuipMac/QuipMacApp.swift
```

Expected: an even number where the count of `refreshIterm2SessionIds` matches the count of `refreshSubtitles`. If they're unequal, one of the refresh sites was missed.

---

## Task 7: Extend `sendText` with `iterm2SessionId` parameter + rewrite AppleScript

**Purpose:** Add the new optional parameter and rewrite the iTerm2 branch of the AppleScript to select by session UUID when one is supplied. The Terminal.app branch is unchanged. The fallback path (for nil session id or no matching session) remains "current session of front window".

**Files:**
- Modify: `QuipMac/Services/KeystrokeInjector.swift`

- [ ] **Step 7.1: Replace the entire `sendText` method**

Use the Edit tool with this replacement in `QuipMac/Services/KeystrokeInjector.swift`:

**Find** (the full `sendText` method, lines 28-89 of the current file — approximately 62 lines):

```swift
    @discardableResult
    func sendText(_ text: String, to windowId: String, pressReturn: Bool, terminalApp: TerminalApp, windowName: String? = nil, cgWindowNumber: CGWindowID = 0) -> InjectionResult {
        let escapedText = escapeForAppleScript(text)
        let textToSend = pressReturn ? escapedText + "\\n" : escapedText

        let script: String
        switch terminalApp {
        case .terminal:
            // Always use System Events keystrokes for Terminal.app to avoid
            // shell command injection via 'do script'. Each line is typed as
            // literal keystrokes, then Return is pressed between lines.
            let lines = text.components(separatedBy: "\n")
            var keystrokeCmds: [String] = []
            for (i, line) in lines.enumerated() {
                if !line.isEmpty {
                    let escapedLine = escapeForAppleScript(line)
                    keystrokeCmds.append("keystroke \"\(escapedLine)\"")
                }
                // Press Return between lines, and at the end if pressReturn is true
                if i < lines.count - 1 {
                    keystrokeCmds.append("key code 36") // Return
                }
            }
            if pressReturn {
                keystrokeCmds.append("key code 36") // Return
            }
            let cmds = keystrokeCmds.joined(separator: "\n                        ")
            script = """
            tell application "Terminal" to activate
            delay 0.1
            tell application "System Events"
                tell process "Terminal"
                    \(cmds)
                end tell
            end tell
            """

        case .iterm2:
            // Try matching by window ID first, then by name, then fallback to front window
            script = """
            tell application "iTerm2"
                -- Try by window id (matches CG window number)
                try
                    repeat with w in windows
                        if id of w is \(cgWindowNumber) then
                            tell current session of w
                                write text "\(textToSend)" newline \(pressReturn ? "yes" : "no")
                            end tell
                            return
                        end if
                    end repeat
                end try
                -- Fallback: use front window (should be focused by AX already)
                tell current session of front window
                    write text "\(textToSend)" newline \(pressReturn ? "yes" : "no")
                end tell
            end tell
            """
        }

        return executeAppleScript(script, context: "sendText to \(windowId)")
    }
```

**Replace with** (same signature plus a new `iterm2SessionId: String? = nil` parameter, same Terminal.app branch, rewritten iTerm2 branch):

```swift
    @discardableResult
    func sendText(_ text: String, to windowId: String, pressReturn: Bool, terminalApp: TerminalApp, windowName: String? = nil, cgWindowNumber: CGWindowID = 0, iterm2SessionId: String? = nil) -> InjectionResult {
        let escapedText = escapeForAppleScript(text)
        let textToSend = pressReturn ? escapedText + "\\n" : escapedText

        let script: String
        switch terminalApp {
        case .terminal:
            // Always use System Events keystrokes for Terminal.app to avoid
            // shell command injection via 'do script'. Each line is typed as
            // literal keystrokes, then Return is pressed between lines.
            let lines = text.components(separatedBy: "\n")
            var keystrokeCmds: [String] = []
            for (i, line) in lines.enumerated() {
                if !line.isEmpty {
                    let escapedLine = escapeForAppleScript(line)
                    keystrokeCmds.append("keystroke \"\(escapedLine)\"")
                }
                // Press Return between lines, and at the end if pressReturn is true
                if i < lines.count - 1 {
                    keystrokeCmds.append("key code 36") // Return
                }
            }
            if pressReturn {
                keystrokeCmds.append("key code 36") // Return
            }
            let cmds = keystrokeCmds.joined(separator: "\n                        ")
            script = """
            tell application "Terminal" to activate
            delay 0.1
            tell application "System Events"
                tell process "Terminal"
                    \(cmds)
                end tell
            end tell
            """

        case .iterm2:
            // If a session UUID is cached, address the session directly by its
            // stable `unique id`. iTerm2's `id of w` is iTerm2's internal window
            // ID (not a CGWindowID), so the previous `id of w is N` match never
            // fired — always fell through to `front window`, which is wrong when
            // multiple iTerm2 windows are open. Session `unique id` is a stable
            // UUID that survives window moves, tab cycles, and iTerm2 state changes.
            if let sessionId = iterm2SessionId {
                let escapedId = escapeForAppleScript(sessionId)
                script = """
                tell application "iTerm2"
                    try
                        repeat with w in windows
                            repeat with s in sessions of w
                                if unique id of s is "\(escapedId)" then
                                    tell s
                                        write text "\(textToSend)" newline \(pressReturn ? "yes" : "no")
                                    end tell
                                    return
                                end if
                            end repeat
                        end repeat
                    end try
                    -- Fallback: front window (reached only if the cached session
                    -- UUID doesn't match any current session, e.g. session closed)
                    tell current session of front window
                        write text "\(textToSend)" newline \(pressReturn ? "yes" : "no")
                    end tell
                end tell
                """
            } else {
                // No cached session id — fall back to the pre-fix behavior (front
                // window). Same risk profile as before the #13 fix for this call site.
                script = """
                tell application "iTerm2"
                    tell current session of front window
                        write text "\(textToSend)" newline \(pressReturn ? "yes" : "no")
                    end tell
                end tell
                """
            }
        }

        return executeAppleScript(script, context: "sendText to \(windowId)")
    }
```

- [ ] **Step 7.2: Verify the signature change**

Run:
```bash
grep -A 1 "func sendText" QuipMac/Services/KeystrokeInjector.swift
```

Expected: the new signature including `iterm2SessionId: String? = nil` at the end.

---

## Task 8: Extend `sendKeystroke` with `iterm2SessionId` parameter + rewrite AppleScript

**Purpose:** Mirror Task 7 for the `sendKeystroke` function. The Terminal.app branch (and its `keystrokeScript` helper) is untouched — only the iTerm2 branch changes.

**Files:**
- Modify: `QuipMac/Services/KeystrokeInjector.swift`

- [ ] **Step 8.1: Replace the `sendKeystroke` iTerm2 branch**

Use the Edit tool with this replacement in `QuipMac/Services/KeystrokeInjector.swift`:

**Find** (the signature plus the iTerm2 branch of `sendKeystroke` — approximately lines 110-138 of the current file):

```swift
    @discardableResult
    func sendKeystroke(_ key: String, to windowId: String, terminalApp: TerminalApp, cgWindowNumber: CGWindowID = 0, windowIndex: Int = 1) -> InjectionResult {
        // iTerm2: use native write-text-with-character-id. Byte-identical to
        // what typing the key into an iTerm2 session does, reliable because
        // write text targets a session by object address rather than by
        // keyboard focus.
        if terminalApp == .iterm2 {
            guard let charId = iTerm2CharIdFor(key) else {
                return InjectionResult(success: false, error: "No iTerm2 char id for key: \(key)")
            }
            let script = """
            tell application "iTerm2"
                try
                    repeat with w in windows
                        if id of w is \(cgWindowNumber) then
                            tell current session of w
                                write text (character id \(charId))
                            end tell
                            return
                        end if
                    end repeat
                end try
                tell current session of front window
                    write text (character id \(charId))
                end tell
            end tell
            """
            return executeAppleScript(script, context: "sendKeystroke \(key) to \(windowId) [iTerm2 write text, charId=\(charId)]")
        }
```

**Replace with** (adds `iterm2SessionId: String? = nil` param, rewrites the iTerm2 script to select by session UUID):

```swift
    @discardableResult
    func sendKeystroke(_ key: String, to windowId: String, terminalApp: TerminalApp, cgWindowNumber: CGWindowID = 0, windowIndex: Int = 1, iterm2SessionId: String? = nil) -> InjectionResult {
        // iTerm2: use native write-text-with-character-id. Byte-identical to
        // what typing the key into an iTerm2 session does, reliable because
        // write text targets a session by object address rather than by
        // keyboard focus.
        if terminalApp == .iterm2 {
            guard let charId = iTerm2CharIdFor(key) else {
                return InjectionResult(success: false, error: "No iTerm2 char id for key: \(key)")
            }
            let script: String
            if let sessionId = iterm2SessionId {
                let escapedId = escapeForAppleScript(sessionId)
                script = """
                tell application "iTerm2"
                    try
                        repeat with w in windows
                            repeat with s in sessions of w
                                if unique id of s is "\(escapedId)" then
                                    tell s
                                        write text (character id \(charId))
                                    end tell
                                    return
                                end if
                            end repeat
                        end repeat
                    end try
                    tell current session of front window
                        write text (character id \(charId))
                    end tell
                end tell
                """
            } else {
                script = """
                tell application "iTerm2"
                    tell current session of front window
                        write text (character id \(charId))
                    end tell
                end tell
                """
            }
            return executeAppleScript(script, context: "sendKeystroke \(key) to \(windowId) [iTerm2 write text, charId=\(charId)]")
        }
```

- [ ] **Step 8.2: Verify the signature change**

Run:
```bash
grep -A 1 "func sendKeystroke" QuipMac/Services/KeystrokeInjector.swift
```

Expected: the new signature including `iterm2SessionId: String? = nil`.

---

## Task 9: Extend `readContent` with `iterm2SessionId` parameter + rewrite AppleScript

**Purpose:** Same pattern for `readContent`, which reads the terminal's visible text.

**Files:**
- Modify: `QuipMac/Services/KeystrokeInjector.swift`

- [ ] **Step 9.1: Replace the `readContent` method**

Use the Edit tool with this replacement in `QuipMac/Services/KeystrokeInjector.swift`:

**Find** (the full `readContent` method — approximately lines 335-368):

```swift
    /// Read the visible/recent text content from a terminal window via AppleScript.
    nonisolated func readContent(terminalApp: TerminalApp, cgWindowNumber: CGWindowID = 0) -> String? {
        let script: String
        switch terminalApp {
        case .terminal:
            script = """
            tell application "Terminal"
                return contents of front window
            end tell
            """
        case .iterm2:
            script = """
            tell application "iTerm2"
                try
                    repeat with w in windows
                        if id of w is \(cgWindowNumber) then
                            tell current session of w
                                return contents
                            end tell
                        end if
                    end repeat
                end try
                tell current session of front window
                    return contents
                end tell
            end tell
            """
        }

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        return result.stringValue
    }
```

**Replace with** (adds `iterm2SessionId: String? = nil` param, rewrites the iTerm2 branch):

```swift
    /// Read the visible/recent text content from a terminal window via AppleScript.
    nonisolated func readContent(terminalApp: TerminalApp, cgWindowNumber: CGWindowID = 0, iterm2SessionId: String? = nil) -> String? {
        let script: String
        switch terminalApp {
        case .terminal:
            script = """
            tell application "Terminal"
                return contents of front window
            end tell
            """
        case .iterm2:
            if let sessionId = iterm2SessionId {
                let escapedId = sessionId
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                script = """
                tell application "iTerm2"
                    try
                        repeat with w in windows
                            repeat with s in sessions of w
                                if unique id of s is "\(escapedId)" then
                                    tell s
                                        return contents
                                    end tell
                                end if
                            end repeat
                        end repeat
                    end try
                    tell current session of front window
                        return contents
                    end tell
                end tell
                """
            } else {
                script = """
                tell application "iTerm2"
                    tell current session of front window
                        return contents
                    end tell
                end tell
                """
            }
        }

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        return result.stringValue
    }
```

Note: `readContent` is `nonisolated`, so it can't call the main-actor `escapeForAppleScript` helper. The inline escape above duplicates the escape logic for strings-only (no shell escaping needed, just backslashes and double quotes for AppleScript string-literal safety).

- [ ] **Step 9.2: Verify the signature change**

Run:
```bash
grep -A 1 "func readContent" QuipMac/Services/KeystrokeInjector.swift
```

Expected: the new signature with `iterm2SessionId: String? = nil`.

---

## Task 10: Thread `iterm2SessionId` through every call site in `QuipMacApp.swift`

**Purpose:** Update all ~15 call sites that invoke `sendText`, `sendKeystroke`, or `readContent` to pass `window.iterm2SessionId` when a window reference is available.

**Files:**
- Modify: `QuipMac/QuipMacApp.swift`

- [ ] **Step 10.1: List every call site**

Run:
```bash
grep -n "keystrokeInjector\.\(sendText\|sendKeystroke\|readContent\)" QuipMac/QuipMacApp.swift
```

Expected output: approximately 15 lines with line numbers. For each line, you'll determine whether the call is inside a block that has a `window: ManagedWindow` reference in scope. Most of them do — the handlers generally start with `if let window = windowManager.windows.first(where: { $0.id == msg.windowId })`.

- [ ] **Step 10.2: Update the `send_text` message handler call site**

Use the Edit tool with this replacement in `QuipMac/QuipMacApp.swift`:

**Find** (the exact line from the earlier grep at line 433):

```swift
                        self.keystrokeInjector.sendText(msg.text, to: msg.windowId, pressReturn: msg.pressReturn, terminalApp: termApp, windowName: name, cgWindowNumber: wn)
```

**Replace with**:

```swift
                        self.keystrokeInjector.sendText(msg.text, to: msg.windowId, pressReturn: msg.pressReturn, terminalApp: termApp, windowName: name, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
```

- [ ] **Step 10.3: Update the `request_content` and view-output read sites**

There are multiple `readContent` call sites (at approximately lines 241, 300, 477, 512, 681, 685 per the earlier grep). Each one needs the same addition: `iterm2SessionId: window.iterm2SessionId`.

For each line of the form:
```swift
keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn)
```
change it to:
```swift
keystrokeInjector.readContent(terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
```

If a specific call site is inside a block that doesn't have a `window` reference in scope (e.g., an outer-scope poll where `window` is named differently), use whatever name refers to the `ManagedWindow` at that point. Never invent a field — always reference the real `ManagedWindow.iterm2SessionId` of the target window.

- [ ] **Step 10.4: Update all `handleQuickAction` call sites**

Lines ~622-660 in `QuipMacApp.swift` have the shortcut action handlers (`press_return`, `ctrl+c`, `ctrl+d`, `escape`, `tab`, `backspace`, `press_y`, `press_n`, `clear_context`, `restart_claude`).

For `sendKeystroke` lines of the form:
```swift
keystrokeInjector.sendKeystroke("ctrl+c", to: wid, terminalApp: termApp, cgWindowNumber: wn)
```
change to:
```swift
keystrokeInjector.sendKeystroke("ctrl+c", to: wid, terminalApp: termApp, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
```

For `sendText` lines inside the same handlers of the form:
```swift
keystrokeInjector.sendText("y", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn)
```
change to:
```swift
keystrokeInjector.sendText("y", to: wid, pressReturn: true, terminalApp: termApp, windowName: wname, cgWindowNumber: wn, iterm2SessionId: window.iterm2SessionId)
```

Apply the same pattern to every call site: append `, iterm2SessionId: window.iterm2SessionId` to the existing argument list. Never omit it. If `handleQuickAction` is a helper that takes `window: ManagedWindow` as a parameter, use that parameter name.

- [ ] **Step 10.5: Verify no call sites were missed**

Run:
```bash
grep -cE "sendText\(|sendKeystroke\(|readContent\(" QuipMac/QuipMacApp.swift
```

Record this count. Then run:

```bash
grep -c "iterm2SessionId:" QuipMac/QuipMacApp.swift
```

Expected: both counts match (each call site passes `iterm2SessionId:`). If the second number is smaller than the first, some call sites are missing the parameter.

---

## Task 11: Build, run tests, verify green

**Purpose:** Compile the Mac app, run the test suite, confirm no regressions.

**Files:**
- Regenerate: `QuipMac/QuipMac.xcodeproj/project.pbxproj` (may or may not change — xcodegen is idempotent for source-only changes)

- [ ] **Step 11.1: Regenerate the Xcode project (safety — no source file list changes, but harmless)**

Run:
```bash
cd QuipMac && xcodegen generate && cd ..
```

Expected: exits 0. No errors.

- [ ] **Step 11.2: Build the Mac app**

Run:
```bash
xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` in the final lines. If the build fails, the most likely causes are:
- A call site in `QuipMacApp.swift` passed `iterm2SessionId` without the label or with a wrong name (look for `unnamed argument` errors).
- A call site references `window.iterm2SessionId` where the local variable for the managed window is named differently (e.g. `w` or `mw` instead of `window`).
- The `ManagedWindow` struct constructor calls in `applyWindowSnapshot` were updated but the struct itself wasn't (Task 2 skipped).

Fix each error one at a time, re-build.

- [ ] **Step 11.3: Run the Mac test suite (both existing and new tests)**

Run:
```bash
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "Test Suite|Executed|TEST SUCCEEDED|TEST FAILED|error:" | tail -15
```

Expected: `** TEST SUCCEEDED **` with 40 tests passing (from Task 1.3's baseline). No new tests are added by #13 — the protocol round-trip tests still apply unchanged.

If any test fails:
- If it's a `MessageProtocol` test, something about the Shared/ code was disturbed — almost certainly a file accidentally modified. Stop and investigate.
- If it's compilation-time only, rebuild; compile errors masquerade as test failures sometimes.

- [ ] **Step 11.4: Run the iPhone test suite to confirm no protocol regressions**

Run:
```bash
xcrun simctl shutdown all 2>&1 ; xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS -destination "platform=iOS Simulator,name=iPhone 17 Pro" 2>&1 | grep -E "Test Suite|Executed|TEST SUCCEEDED|TEST FAILED|error:" | tail -15
```

Expected: `** TEST SUCCEEDED **` with 51 tests passing (40 MessageProtocol + 11 PTTStress). This confirms the iOS side is unaffected — which it should be since #13 touches zero iOS-side files.

If the iOS tests fail, the most likely cause is transient simulator state — re-run after another `simctl shutdown all`. If they continue to fail, investigate whether any shared code got touched.

---

## Task 12: Manual multi-iTerm2-window verification

**Purpose:** The core safety gate. Confirm that iPhone-triggered keystrokes land in the selected iTerm2 window even when that window is NOT frontmost.

**Files:**
- Manual testing against a running Mac + iPhone + iTerm2

- [ ] **Step 12.1: Quit any running Quip Mac process**

Run:
```bash
pgrep -f "Quip.app/Contents/MacOS/Quip" | xargs -r kill ; sleep 1
```

Expected: no errors (if no process, the xargs no-ops). Then verify nothing is running:

```bash
pgrep -f "Quip.app/Contents/MacOS/Quip" ; echo "---"
```

Expected: empty output (no running Quip process).

- [ ] **Step 12.2: Launch the new Quip build**

Run:
```bash
open ~/Library/Developer/Xcode/DerivedData/QuipMac-*/Build/Products/Debug/Quip.app
```

Expected: Quip launches. Give it ~2 seconds to initialize.

- [ ] **Step 12.3: Confirm the new session id probe populated for iTerm2 windows**

This requires instrumentation because `iterm2SessionId` isn't visible in the Quip UI. The simplest check: use `lldb` to attach to the running Quip process and print `windowManager.windows.map { ($0.name, $0.iterm2SessionId) }`.

Alternatively (easier): temporarily add a single `print` statement to `applyIterm2SessionIds` from Task 5 that logs `print("[Quip #13] applied \(sessionIds.count) iTerm2 session ids")`, rebuild, relaunch, and check Console.app or `log stream --predicate 'process == "Quip"'` for the message.

If you don't want to temporarily modify the code, skip this step and rely on Step 12.4's functional test as the indirect signal.

- [ ] **Step 12.4: Run the core regression test — Return into non-frontmost iTerm2 window**

Test procedure:

1. Ensure at least 2 iTerm2 windows are open. Verify:
   ```bash
   osascript -e 'tell application "iTerm2" to count windows'
   ```
   Must return ≥ 2.

2. On the Mac, click iTerm2 window #1 so it becomes frontmost.

3. Open the Quip iPhone app (or use the currently-installed build from earlier in the session — the fix is Mac-side-only, so no iPhone install needed).

4. In the Quip iPhone app's window list, select iTerm2 window #2 (the one that is NOT frontmost on the Mac).

5. On the iPhone, tap the "Press Return" shortcut button.

6. **Observe:** the Return should land in iTerm2 window #2, NOT in the frontmost window #1. Verify visually — iTerm2 window #2's shell prompt should advance one line, and window #1 should be unchanged.

**Pass criteria:** Return lands in window #2.
**Fail criteria:** Return lands in window #1 (the pre-fix behavior), or in neither window (fallback script error).

- [ ] **Step 12.5: Secondary regression tests (optional but recommended)**

Repeat Step 12.4's structure with different actions to sanity-check the other code paths:

- **Ctrl+C into non-frontmost:** same setup, tap Ctrl+C instead of Return. Should fire in the selected (non-frontmost) window.
- **View Output from non-frontmost:** same setup, tap the View Output button. The returned terminal content should be from the selected (non-frontmost) window, not the frontmost.
- **Single-window baseline:** close all but one iTerm2 window. Tap Return on the phone. Should work exactly as before — confirms no regression in the single-window case.

All four tests should pass. If any fails, STOP and investigate before committing.

- [ ] **Step 12.6: Quit the test Quip process**

Run:
```bash
pgrep -f "Quip.app/Contents/MacOS/Quip" | xargs -r kill
```

Expected: no errors. The test session is done.

---

## Task 13: Commit

**Purpose:** Single focused commit on `eb-branch` capturing the entire #13 fix.

**Files:**
- Commit: `QuipMac/Services/WindowManager.swift`, `QuipMac/Services/KeystrokeInjector.swift`, `QuipMac/QuipMacApp.swift`, possibly `QuipMac/QuipMac.xcodeproj/project.pbxproj` (if xcodegen touched it).

- [ ] **Step 13.1: Review the staged diff**

Run:
```bash
git status --short
```

Expected staged files:
- `M  QuipMac/Services/WindowManager.swift`
- `M  QuipMac/Services/KeystrokeInjector.swift`
- `M  QuipMac/QuipMacApp.swift`
- optionally `M  QuipMac/QuipMac.xcodeproj/project.pbxproj`

If any other files show up (especially `Info.plist` or `QuipiOS/` paths), STOP and investigate — the fix is supposed to be Mac-only.

- [ ] **Step 13.2: Stage the files**

Run:
```bash
git add QuipMac/Services/WindowManager.swift QuipMac/Services/KeystrokeInjector.swift QuipMac/QuipMacApp.swift QuipMac/QuipMac.xcodeproj/project.pbxproj
```

(The `project.pbxproj` stage is no-op if xcodegen didn't touch it.)

- [ ] **Step 13.3: Review the final staged diff stat**

Run:
```bash
git diff --cached --stat
```

Expected output (approximately — pbxproj may or may not appear):
```
 QuipMac/QuipMacApp.swift                  |  ~15 +++++++++--
 QuipMac/Services/KeystrokeInjector.swift  |  ~100 ++++++++++++++++++++++++-----------
 QuipMac/Services/WindowManager.swift      |  ~60 +++++++++++++++++++--
```

Scan for any unexpected files. If present, unstage them with `git restore --staged <file>` before committing.

- [ ] **Step 13.4: Create the commit**

Run:
```bash
git commit -m "$(cat <<'EOF'
Fixed the thing where tappin' Return on the phone would land on whichever iTerm window was out front instead of the one you actually picked. Turns out iTerm's window id is its own internal number that's got nothin' to do with the window id the rest of the Mac uses, so the matcher was never hittin'. Grab each session's unique UUID at startup now, stash it on the window record, and point the AppleScript at that session by UUID when firin' keystrokes or typin' text. Single iTerm window still works like before; the fix kicks in when you got two or more open.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: commit succeeds. Output shows the approximate file list and line counts from Step 13.3.

- [ ] **Step 13.5: Confirm the commit landed**

Run:
```bash
git log -1 --stat
```

Expected: the commit message matches verbatim, and the stat shows the files from Step 13.2.

---

## Do NOT push

Per `eb-branch` push policy in the user's memory, do **not** push this commit to GitHub without explicit confirmation from the user. The commit stays local until the user says otherwise.

## Completion criteria

All of the following must be true when the plan is done:

1. `ManagedWindow` has an optional `iterm2SessionId: String?` field.
2. `WindowManager.fetchIterm2SessionIds()` exists as a `nonisolated static` method returning `[String: String]` keyed by window title.
3. `WindowManager.applyIterm2SessionIds(_:)` exists as a main-actor method that mutates `windows` in place.
4. `WindowManager.refreshIterm2SessionIds()` exists as a main-actor convenience method that chains the fetch + apply.
5. `QuipMacApp.swift` calls `refreshIterm2SessionIds()` alongside every existing `refreshSubtitles()` call.
6. `KeystrokeInjector.sendText`, `sendKeystroke`, and `readContent` each have a new optional `iterm2SessionId: String?` parameter (default nil).
7. The three functions' iTerm2 AppleScript branches select by `unique id of s` when a session id is supplied, falling back to `current session of front window` when nil.
8. Every `QuipMacApp.swift` call site that invokes those three functions passes `window.iterm2SessionId` (or the equivalent managed-window reference).
9. `xcodebuild build` and `xcodebuild test` both succeed for QuipMac with all 40 protocol tests passing.
10. `xcodebuild test` for QuipiOS still passes (51 tests — 40 protocol + 11 PTT), proving no iOS-side regression.
11. Manual Step 12.4 regression test passes: Return from a non-frontmost iTerm2 window via the phone lands in the correct window.
12. Single commit on `eb-branch` with the blue-collar voice commit message. No commits pushed.
