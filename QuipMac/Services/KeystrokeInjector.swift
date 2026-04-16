// KeystrokeInjector.swift
// QuipMac — Sends text and keystrokes to terminal windows via AppleScript
// Supports Terminal.app and iTerm2

import AppKit
import Observation

@MainActor
@Observable
final class KeystrokeInjector {

    /// Result of a keystroke injection operation
    struct InjectionResult: Sendable {
        let success: Bool
        let error: String?
    }

    // MARK: - Send Text

    /// Send text to a specific terminal window, optionally pressing Return after.
    /// - Parameters:
    ///   - text: The text to type into the terminal
    ///   - windowId: Quip window identifier (used for logging; windowIndex targets the window)
    ///   - pressReturn: Whether to append a newline (press Return) after the text
    ///   - terminalApp: Which terminal emulator to target
    ///   - windowIndex: 1-based window index in the terminal app (default: 1)
    /// - Returns: Result indicating success or failure
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
                    tell current session of front window
                        write text "\(textToSend)" newline \(pressReturn ? "yes" : "no")
                    end tell
                end tell
                """
            } else {
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

    // MARK: - Send Keystroke

    /// Send a special keystroke (e.g., Ctrl+C, Return) to a specific terminal window.
    /// - Parameters:
    ///   - key: Key descriptor: "return", "ctrl+c", "ctrl+d", "escape", "tab", "backspace"
    ///   - windowId: Quip window identifier (used for logging)
    ///   - terminalApp: Which terminal emulator to target
    ///   - cgWindowNumber: The CGWindowID of the target window.
    ///   - windowIndex: 1-based window index (legacy fallback, default: 1)
    /// - Returns: Result indicating success or failure
    ///
    /// iTerm2 path: uses iTerm2's native `write text (character id N)` AppleScript
    /// verb, which addresses a specific session directly and does NOT depend on
    /// OS-level keyboard focus. This is the same transport `sendText` uses for
    /// Y/N and other text injection, so it has the same proven reliability.
    ///
    /// Terminal.app path: uses System Events keystroke injection (the legacy
    /// approach), which relies on `windowManager.focusWindow(windowId)` having
    /// raised the correct window before the AppleScript runs.
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

        // Terminal.app: legacy System Events keystroke path.
        let script: String
        switch key.lowercased() {
        case "return", "enter":
            script = keystrokeScript(
                key: "return", using: "",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "ctrl+c":
            script = keystrokeScript(
                key: "c", using: "control down",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "ctrl+d":
            script = keystrokeScript(
                key: "d", using: "control down",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "escape", "esc":
            script = keystrokeScript(
                key: "escape", using: "",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "tab":
            script = keystrokeScript(
                key: "tab", using: "",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "backspace", "delete":
            script = keystrokeScript(
                key: "delete", using: "",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        default:
            return InjectionResult(success: false, error: "Unknown key: \(key)")
        }

        return executeAppleScript(script, context: "sendKeystroke \(key) to \(windowId) (cgWin=\(cgWindowNumber))")
    }

    /// Map a key descriptor to the ASCII/Unicode codepoint that iTerm2's
    /// `write text (character id N)` will send into a session. Returns nil for
    /// unknown keys.
    private func iTerm2CharIdFor(_ key: String) -> Int? {
        switch key.lowercased() {
        case "return", "enter":      return 13   // CR
        case "escape", "esc":        return 27   // ESC
        case "tab":                  return 9    // HT
        case "backspace", "delete":  return 127  // DEL
        case "ctrl+c":               return 3    // ETX / SIGINT
        case "ctrl+d":               return 4    // EOT / EOF
        default:                     return nil
        }
    }

    // MARK: - Spawn Terminal

    /// Open a new terminal window, cd to a directory, and run `claude`.
    /// - Parameters:
    ///   - directory: The directory to change to
    ///   - terminalApp: Which terminal to open
    /// - Returns: Result indicating success or failure
    @discardableResult
    func spawnTerminal(in directory: String, terminalApp: TerminalApp) -> InjectionResult {
        let escapedDir = escapeForAppleScript(directory)
        let script: String

        switch terminalApp {
        case .terminal:
            script = """
            tell application "Terminal"
                activate
                do script "cd \\"\(escapedDir)\\" && claude"
            end tell
            """

        case .iterm2:
            script = """
            tell application "iTerm2"
                activate
                create window with default profile
                tell current session of current window
                    write text "cd \\"\(escapedDir)\\" && claude"
                end tell
            end tell
            """
        }

        return executeAppleScript(script, context: "spawnTerminal in \(directory)")
    }

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

    // MARK: - Read Terminal Content

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

    // MARK: - Capture Window Screenshot

    /// Capture a screenshot of a specific window via the `screencapture` CLI.
    /// Returns base64-encoded PNG data, or nil on failure.
    nonisolated func captureWindowScreenshot(cgWindowNumber: CGWindowID) -> String? {
        guard cgWindowNumber != 0 else { return nil }
        let tmpPath = NSTemporaryDirectory() + "quip_capture_\(cgWindowNumber).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", "\(cgWindowNumber)", "-x", "-o", tmpPath]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        guard let data = FileManager.default.contents(atPath: tmpPath) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Helpers

    /// Build a System Events keystroke AppleScript targeting the correct terminal window.
    ///
    /// For iTerm2 with a non-zero `cgWindowNumber`, emits a `repeat with w in windows`
    /// loop that selects the window whose id matches the CGWindowID before sending
    /// the System Events keystroke. This mirrors the same window-targeting pattern
    /// `sendText` already uses for iTerm2 (see the `.iterm2` branch of `sendText`)
    /// and prevents keystrokes from landing in the wrong iTerm2 window when
    /// multiple are open.
    ///
    /// For Terminal.app, or for iTerm2 with `cgWindowNumber == 0`, falls back to
    /// bare `activate` on the app, which targets whichever window is currently
    /// frontmost within that process. Terminal.app window targeting is tracked
    /// as a separate wishlist item because Terminal.app's AppleScript window
    /// model doesn't expose CGWindowID directly.
    private func keystrokeScript(key: String, using modifiers: String, terminalApp: TerminalApp, cgWindowNumber: CGWindowID, windowIndex: Int) -> String {
        let appName = terminalApp.rawValue
        let isSpecialKey = ["return", "escape", "tab", "delete"].contains(key.lowercased())

        let keystrokeCmd: String
        if isSpecialKey {
            if modifiers.isEmpty {
                keystrokeCmd = "key code \(keyCodeFor(key))"
            } else {
                keystrokeCmd = "key code \(keyCodeFor(key)) using {\(modifiers)}"
            }
        } else {
            if modifiers.isEmpty {
                keystrokeCmd = "keystroke \"\(key)\""
            } else {
                keystrokeCmd = "keystroke \"\(key)\" using {\(modifiers)}"
            }
        }

        // NOTE on window targeting: an earlier version of this function tried
        // to iterate iTerm2's windows and `select` one whose `id` matched the
        // CGWindowID, so the keystroke would land in a specific window even
        // when multiple iTerm2 windows were open. That DIDN'T WORK — iTerm2's
        // AppleScript `id of window` returns iTerm2's internal window
        // identifier, NOT a CGWindowID, so the repeat loop silently never
        // matched. Combined with a removed `delay 0.1`, keystrokes were
        // firing before iTerm2 was even frontmost.
        //
        // For now, we rely on `windowManager.focusWindow(windowId)` (called
        // from the caller) to AX-raise the target window, and `delay 0.1`
        // here to give that raise time to propagate. Multi-iTerm2-window
        // targeting is a wishlist item — it needs a different identifier
        // like iTerm2 session unique id, or a lower-level AX-based keystroke
        // injection that bypasses System Events entirely.
        return """
        tell application "\(appName)" to activate
        delay 0.1
        tell application "System Events"
            tell process "\(appName)"
                \(keystrokeCmd)
            end tell
        end tell
        """
    }

    /// Map key names to macOS virtual key codes
    private func keyCodeFor(_ key: String) -> Int {
        switch key.lowercased() {
        case "return", "enter": return 36
        case "escape", "esc": return 53
        case "tab": return 48
        case "delete": return 51
        case "space": return 49
        default: return 0
        }
    }

    /// Escape text for use inside AppleScript string literals
    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

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

    /// Execute an AppleScript and return the result
    private func executeAppleScript(_ source: String, context: String) -> InjectionResult {
        guard let appleScript = NSAppleScript(source: source) else {
            let msg = "Failed to create NSAppleScript"
            print("[KeystrokeInjector] \(context): \(msg)")
            return InjectionResult(success: false, error: msg)
        }

        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo = errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            print("[KeystrokeInjector] \(context): \(message)")
            return InjectionResult(success: false, error: message)
        }

        return InjectionResult(success: true, error: nil)
    }
}
