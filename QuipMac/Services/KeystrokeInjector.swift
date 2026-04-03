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
    func sendText(_ text: String, to windowId: String, pressReturn: Bool, terminalApp: TerminalApp, windowName: String? = nil, cgWindowNumber: CGWindowID = 0) -> InjectionResult {
        let escapedText = escapeForAppleScript(text)
        let textToSend = pressReturn ? escapedText + "\\n" : escapedText

        let script: String
        switch terminalApp {
        case .terminal:
            if pressReturn {
                script = """
                tell application "Terminal"
                    do script "\(escapedText)" in front window
                end tell
                """
            } else {
                script = """
                tell application "Terminal" to activate
                delay 0.1
                tell application "System Events"
                    tell process "Terminal"
                        keystroke "\(escapedText)"
                    end tell
                end tell
                """
            }

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

    // MARK: - Send Keystroke

    /// Send a special keystroke (e.g., Ctrl+C, Return) to a terminal window.
    /// - Parameters:
    ///   - key: Key descriptor: "return", "ctrl+c", "ctrl+d", "escape", "tab"
    ///   - windowId: Quip window identifier
    ///   - terminalApp: Which terminal emulator to target
    ///   - windowIndex: 1-based window index (default: 1)
    /// - Returns: Result indicating success or failure
    @discardableResult
    func sendKeystroke(_ key: String, to windowId: String, terminalApp: TerminalApp, windowIndex: Int = 1) -> InjectionResult {
        let script: String

        switch key.lowercased() {
        case "return", "enter":
            script = keystrokeScript(
                key: "return", using: "",
                terminalApp: terminalApp, windowIndex: windowIndex
            )

        case "ctrl+c":
            script = keystrokeScript(
                key: "c", using: "control down",
                terminalApp: terminalApp, windowIndex: windowIndex
            )

        case "ctrl+d":
            script = keystrokeScript(
                key: "d", using: "control down",
                terminalApp: terminalApp, windowIndex: windowIndex
            )

        case "escape", "esc":
            script = keystrokeScript(
                key: "escape", using: "",
                terminalApp: terminalApp, windowIndex: windowIndex
            )

        case "tab":
            script = keystrokeScript(
                key: "tab", using: "",
                terminalApp: terminalApp, windowIndex: windowIndex
            )

        default:
            return InjectionResult(success: false, error: "Unknown key: \(key)")
        }

        return executeAppleScript(script, context: "sendKeystroke \(key) to \(windowId)")
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

    // MARK: - Helpers

    /// Build a System Events keystroke AppleScript targeting the correct terminal
    private func keystrokeScript(key: String, using modifiers: String, terminalApp: TerminalApp, windowIndex: Int) -> String {
        let appName = terminalApp.rawValue
        let isSpecialKey = ["return", "escape", "tab"].contains(key.lowercased())

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
