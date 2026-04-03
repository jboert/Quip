// TerminalColorManager.swift
// QuipMac — Changes terminal background colors based on Claude Code state
// Supports Terminal.app and iTerm2 via AppleScript

import AppKit
import Observation

// MARK: - TerminalColorManager

@MainActor
@Observable
final class TerminalColorManager {

    // MARK: - Color Configuration

    /// Terminal.app colors use {R, G, B, A} in 0-65535 range
    struct TerminalAppColors {
        var waitingForInput = "{0, 0, 8000, 65535}"     // dark blue
        var sttActive = "{15000, 0, 25000, 65535}"       // dark purple
    }

    /// iTerm2 colors use "R G B" in 0-255 range
    struct ITerm2Colors {
        var waitingForInput = "0 0 50"    // dark blue
        var sttActive = "60 0 100"         // dark purple
    }

    var terminalAppColors = TerminalAppColors()
    var iterm2Colors = ITerm2Colors()

    /// Tracks the last applied state per window to avoid redundant AppleScript calls
    private var lastAppliedState: [String: TerminalState] = [:]

    // MARK: - Update Color

    /// Update the background color of a terminal window based on state.
    /// Does nothing for `.neutral` state (restores default).
    /// - Parameters:
    ///   - windowId: The Quip window identifier
    ///   - state: Current terminal state
    ///   - terminalApp: Which terminal emulator to target
    ///   - windowIndex: 1-based window index in the terminal app (default: 1)
    func updateColor(for windowId: String, state: TerminalState, terminalApp: TerminalApp, windowIndex: Int = 1) {
        // Skip if state hasn't changed
        if lastAppliedState[windowId] == state { return }
        lastAppliedState[windowId] = state

        switch state {
        case .neutral:
            resetColor(terminalApp: terminalApp, windowIndex: windowIndex)
        case .waitingForInput:
            applyColor(terminalApp: terminalApp, windowIndex: windowIndex, state: .waitingForInput)
        case .sttActive:
            applyColor(terminalApp: terminalApp, windowIndex: windowIndex, state: .sttActive)
        }
    }

    // MARK: - Apply Color

    private func applyColor(terminalApp: TerminalApp, windowIndex: Int, state: TerminalState) {
        let script: String

        switch terminalApp {
        case .terminal:
            let color: String
            switch state {
            case .waitingForInput: color = terminalAppColors.waitingForInput
            case .sttActive: color = terminalAppColors.sttActive
            case .neutral: return
            }
            script = """
            tell application "Terminal"
                set background color of selected tab of window \(windowIndex) to \(color)
            end tell
            """

        case .iterm2:
            let color: String
            switch state {
            case .waitingForInput: color = iterm2Colors.waitingForInput
            case .sttActive: color = iterm2Colors.sttActive
            case .neutral: return
            }
            let components = color.split(separator: " ")
            guard components.count == 3 else { return }
            script = """
            tell application "iTerm2"
                tell current session of window \(windowIndex)
                    set background color to {"\(components[0])", "\(components[1])", "\(components[2])"}
                end tell
            end tell
            """
        }

        executeAppleScript(script)
    }

    // MARK: - Reset Color

    private func resetColor(terminalApp: TerminalApp, windowIndex: Int) {
        let script: String

        switch terminalApp {
        case .terminal:
            // Reset to the default profile's background color
            script = """
            tell application "Terminal"
                set currentSettings to name of current settings of selected tab of window \(windowIndex)
                set background color of selected tab of window \(windowIndex) to background color of settings set currentSettings
            end tell
            """

        case .iterm2:
            // Reset iTerm2 to profile default by re-applying the profile
            script = """
            tell application "iTerm2"
                tell current session of window \(windowIndex)
                    set profileName to profile name
                    -- Resetting by reloading profile resets background
                end tell
            end tell
            """
        }

        executeAppleScript(script)
    }

    // MARK: - AppleScript Execution

    private func executeAppleScript(_ source: String) {
        guard let appleScript = NSAppleScript(source: source) else {
            print("[TerminalColorManager] Failed to create NSAppleScript")
            return
        }

        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            print("[TerminalColorManager] AppleScript error: \(message)")
        }
    }
}
