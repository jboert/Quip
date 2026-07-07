// KeystrokeInjector.swift
// QuipMac — Sends text and keystrokes to terminal windows via AppleScript
// Supports Terminal.app and iTerm2

import AppKit
import Observation

enum TextInjectionRoute: String, Sendable {
    case pasteText
    case sendText

    static func choose(cliKind: CLIKind, terminalApp: TerminalApp) -> TextInjectionRoute {
        switch (cliKind, terminalApp) {
        case (.codex, .iterm2), (.grok, .iterm2):
            return .pasteText
        default:
            return .sendText
        }
    }
}

@MainActor
@Observable
final class KeystrokeInjector {

    /// Structured failure kinds — drives self-heal decisions without string-
    /// matching the AppleScript error wording (#4).
    enum InjectionError: Sendable, Equatable {
        /// iTerm2 session uuid not found by the AppleScript walker — the
        /// cached id is stale (session was recreated). Triggers self-heal:
        /// refresh session-id map + retry once. (§)
        case sessionNotFound
        /// AppleScript blocked by TCC (Apple Events / Accessibility).
        case tccDenied
        /// Target window has gone away before injection started.
        case windowClosed
        /// Anything else; carries the original message for debugging.
        case unknown(String)
    }

    /// Result of a keystroke injection operation
    struct InjectionResult: Sendable {
        let success: Bool
        let error: String?
        /// Structured kind, when classifiable. nil for older call sites or
        /// when classification didn't yield a specific case. (#4)
        let kind: InjectionError?

        init(success: Bool, error: String?, kind: InjectionError? = nil) {
            self.success = success
            self.error = error
            self.kind = kind
        }
    }

    /// Classify a raw AppleScript error message into a structured `InjectionError`.
    /// Pulled out for testing; runs on every executeAppleScript failure. (#4)
    nonisolated static func classifyAppleScriptError(_ message: String) -> InjectionError {
        let lower = message.lowercased()
        if lower.contains("not found") { return .sessionNotFound }
        if lower.contains("not authorized") || lower.contains("denied") || lower.contains("tcc") {
            return .tccDenied
        }
        if lower.contains("window") && (lower.contains("closed") || lower.contains("doesn't exist")) {
            return .windowClosed
        }
        return .unknown(message)
    }

    /// Which injection path the delay is being computed for. `.sendText`
    /// historically needed 80ms; `.quickAction` needed 200ms because the
    /// System Events keystroke path races the AX window raise harder.
    enum KeystrokePath: Sendable { case sendText, quickAction }

    /// Returns the delay QuipMac should wait after calling `focusWindow`
    /// before firing the AppleScript keystroke. When iTerm2 session-write
    /// targets a session directly by UUID, it does NOT require the window
    /// to be frontmost — the delay is pure latency and must be zero.
    nonisolated static func focusDelay(path: KeystrokePath,
                                       terminalApp: TerminalApp,
                                       iterm2SessionId: String?) -> TimeInterval {
        if terminalApp == .iterm2 && iterm2SessionId != nil { return 0 }
        switch path {
        case .sendText:    return 0.08
        case .quickAction: return 0.2
        }
    }

    // MARK: - Clipboard injection coordinator
    //
    // pasteText / pasteImage / sendText[Claude Desktop] all stomp
    // NSPasteboard.general to inject content, then restore the user's
    // clipboard after a delay. When injections overlap — rapid grok/codex
    // voice sends land on the paste serial queue ~0.5s apart, inside the
    // 0.6s restore window — a naive per-call snapshot captures the PREVIOUS
    // injection instead of the user's real clipboard, and the staggered
    // restores clobber each other, leaving injected prompt text on the
    // user's clipboard. This coordinator snapshots the real original ONCE
    // per burst (the 0→1 transition) and restores it exactly once, when the
    // last outstanding injection finishes. NSLock-guarded so the off-main
    // paste-queue callers and the main-actor self-heal retry stay serialized.
    // nonisolated: the @MainActor class would otherwise isolate these statics
    // to main, but they're touched from the off-main paste queue too. The lock
    // (Sendable, immutable) provides the actual synchronization; the mutable
    // vars are nonisolated(unsafe) because that synchronization is manual.
    nonisolated private static let clipboardLock = NSLock()
    nonisolated(unsafe) private static var clipboardOriginal: String?
    nonisolated(unsafe) private static var clipboardOutstanding = 0

    /// Mark one clipboard injection in flight, snapshotting the user's real
    /// clipboard on the first (0→1) call of a burst. Returns the burst's
    /// original string (identical for every call within the burst). Must be
    /// paired with `endClipboardInjection`. Safe from any thread.
    @discardableResult
    nonisolated static func beginClipboardInjection() -> String? {
        clipboardLock.lock()
        defer { clipboardLock.unlock() }
        if clipboardOutstanding == 0 {
            clipboardOriginal = NSPasteboard.general.string(forType: .string)
        }
        clipboardOutstanding += 1
        return clipboardOriginal
    }

    /// Restore the burst's original clipboard after `delay`s, but only when
    /// this is the LAST outstanding injection — so a burst restores once to
    /// the real original, never an intermediate injected value. The restore
    /// runs under the lock so a new burst can't re-snapshot mid-restore.
    nonisolated static func endClipboardInjection(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            clipboardLock.lock()
            defer { clipboardLock.unlock() }
            clipboardOutstanding = max(0, clipboardOutstanding - 1)
            guard clipboardOutstanding == 0 else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            if let original = clipboardOriginal { pb.setString(original, forType: .string) }
        }
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
        let textToSend = escapedText

        // iTerm2's `newline yes` emits LF (0x0A). Claude Code's TUI only fires
        // submit on CR (0x0D / key code 13) — the key the user's Return button
        // presses. So when pressReturn is true, we always write the text with
        // `newline no` and then send a CR via `write text (character id 13)`.
        let returnSuffix = pressReturn ? "\n                                write text (character id 13)" : ""

        let script: String
        switch terminalApp {
        case .claudeDesktop:
            // Claude Desktop is an Electron app — clipboard paste is the
            // only reliable text insertion method. Save/restore the user's
            // clipboard so we don't clobber it.
            let pb = NSPasteboard.general
            // Shared coordinator (see beginClipboardInjection) restores once
            // after the burst; +0.1s since Cmd+V into Electron lands fast.
            Self.beginClipboardInjection()
            pb.clearContents()
            pb.setString(text, forType: .string)
            // defer (not an explicit call) so the counter can't leak if an
            // early return is ever added below — matches pasteText/pasteImage.
            defer { Self.endClipboardInjection(after: 0.1) }

            let returnCmd = pressReturn ? "\n                    key code 36" : ""
            let pasteScript = """
            tell application "Claude" to activate
            delay 0.15
            tell application "System Events"
                tell process "Claude"
                    keystroke "v" using command down\(returnCmd)
                end tell
            end tell
            """
            return executeAppleScript(pasteScript, context: "sendText to \(windowId) [Claude Desktop paste]")

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
            // No session id → no safe target. Falling back to `current session
            // of front window` would silently type into whatever iTerm2 window
            // is frontmost on the Mac — a different terminal than the phone is
            // looking at. Refuse instead and let the next session-id refresh
            // heal things; the phone can retry.
            guard let sessionId = iterm2SessionId else {
                let err = "iTerm2 session not yet mapped for window \(windowId)"
                print("[KeystrokeInjector] sendText DROPPED: \(err)")
                return InjectionResult(success: false, error: err)
            }
            let escapedId = escapeForAppleScript(sessionId)
            // iTerm2's AppleScript hierarchy is window → tab → session. The
            // shorthand `sessions of w` the old code used silently errors
            // ("Can't get every session of item 1 of every window") and the
            // old fallback happened to mask it by writing to front window —
            // which is how every keystroke quietly landed in the wrong pane
            // for months. Walk the tabs explicitly.
            script = """
            tell application "iTerm2"
                set quipFound to false
                repeat with aWindow in windows
                    tell aWindow
                        repeat with aTab in tabs
                            tell aTab
                                repeat with aSession in sessions
                                    if unique id of aSession is "\(escapedId)" then
                                        tell aSession
                                            write text "\(textToSend)" newline no\(returnSuffix)
                                        end tell
                                        set quipFound to true
                                        exit repeat
                                    end if
                                end repeat
                            end tell
                            if quipFound then exit repeat
                        end repeat
                    end tell
                    if quipFound then exit repeat
                end repeat
                if not quipFound then
                    error "Quip: iTerm2 session \(escapedId) not found"
                end if
            end tell
            """
        }

        return executeAppleScript(script, context: "sendText to \(windowId)")
    }

    // MARK: - Paste Image (Codex CLI path)

    /// Paste image bytes into a terminal window via the system clipboard +
    /// Cmd+V. Used for AI CLIs (notably Codex) whose interactive composer
    /// expects pasted *image data*, not a typed file path. Saves and
    /// restores the user's existing clipboard string so we don't clobber
    /// what they had copied. (GH I.)
    ///
    /// Sequence:
    /// 1. Snapshot current clipboard string contents.
    /// 2. Set clipboard to the image (NSImage from disk).
    /// 3. Activate iTerm2, focus target session, send Cmd+V.
    /// 4. Restore the snapshotted string contents after a short delay.
    ///
    /// Returns failure if the image can't be loaded; success codepath
    /// trusts AppleScript (same as `sendText`'s iTerm2 path).
    @discardableResult
    func pasteImage(at imageURL: URL, to windowId: String, terminalApp: TerminalApp,
                    iterm2SessionId: String?) -> InjectionResult {
        guard let image = NSImage(contentsOf: imageURL) else {
            return InjectionResult(success: false, error: "couldn't load image at \(imageURL.path)")
        }

        // Snapshot the user's current clipboard string so we can restore it.
        // We don't snapshot non-string types — losing whatever NSImage was
        // there is acceptable since this whole flow assumes the user wants
        // an image on the clipboard for one moment anyway.
        let pb = NSPasteboard.general
        // Shared coordinator: restore once after the burst even if a text
        // paste overlaps this image paste (both touch NSPasteboard.general).
        Self.beginClipboardInjection()
        pb.clearContents()
        pb.writeObjects([image])
        // 0.6s: floor before Cmd+V lands; iTerm2 paste-confirm may extend past it.
        defer { Self.endClipboardInjection(after: 0.6) }

        switch terminalApp {
        case .iterm2:
            guard let sessionId = iterm2SessionId else {
                return InjectionResult(success: false, error: "iTerm2 session not yet mapped for window \(windowId)")
            }
            let escapedId = escapeForAppleScript(sessionId)
            // iTerm2 needs to be activated AND the target session selected
            // before Cmd+V lands in the right pane. Walk window→tab→session
            // (same shape as sendText) to flip selection, then activate
            // iTerm2 process and send Cmd+V via System Events.
            let script = """
            tell application "iTerm2"
                set quipFound to false
                repeat with aWindow in windows
                    tell aWindow
                        repeat with aTab in tabs
                            tell aTab
                                repeat with aSession in sessions
                                    if unique id of aSession is "\(escapedId)" then
                                        select aSession
                                        set quipFound to true
                                        exit repeat
                                    end if
                                end repeat
                            end tell
                            if quipFound then exit repeat
                        end repeat
                    end tell
                    if quipFound then exit repeat
                end repeat
                if not quipFound then
                    error "Quip: iTerm2 session \(escapedId) not found"
                end if
                activate
            end tell
            delay 0.1
            tell application "System Events"
                tell process "iTerm2"
                    keystroke "v" using command down
                end tell
            end tell
            """
            return executeAppleScript(script, context: "pasteImage to \(windowId) [iTerm2]")

        case .terminal:
            // Terminal.app doesn't support image paste (text-only); the
            // caller should fall back to path-typing for this host.
            return InjectionResult(success: false, error: "Terminal.app does not accept pasted images")

        case .claudeDesktop:
            // Claude Desktop has its own paste path in sendText that handles
            // text via NSPasteboard; image-paste isn't routed here today.
            return InjectionResult(success: false, error: "Claude Desktop image paste not implemented via this path")
        }
    }

    // MARK: - Paste Text (Codex CLI path)

    /// Paste a text string into a terminal window via the system clipboard +
    /// Cmd+V. Used for AI CLIs (notably Codex) whose interactive composer
    /// ignores PTY-typed bytes from `write text` — Codex's composer captures
    /// real macOS paste events but discards raw stdin chars, so a PTT
    /// transcript routed through `sendText`'s `write text` path silently
    /// vanishes. Mirrors `pasteImage` and saves/restores the user's
    /// clipboard.
    ///
    /// Sequence:
    /// 1. Snapshot current clipboard string.
    /// 2. Set clipboard to `text`.
    /// 3. Activate iTerm2, focus target session, send Cmd+V.
    /// 4. Optionally send Cmd+Enter (Codex's submit) when `pressReturn` is true.
    /// 5. Restore the snapshotted clipboard string after a short delay.
    ///
    /// Codex submit: Codex CLI's interactive composer accepts a single
    /// pasted blob and submits on Enter (key code 36). Cmd+Enter is the
    /// "send and keep composer open" variant; we use plain Enter to match
    /// the existing `pressReturn` semantics in `sendText`.
    @discardableResult
    nonisolated func pasteText(_ text: String, to windowId: String, pressReturn: Bool,
                               terminalApp: TerminalApp, iterm2SessionId: String?) -> InjectionResult {
        let pb = NSPasteboard.general
        // Shared coordinator restores the user's clipboard once after the
        // burst — overlapping grok/codex pastes (serial queue, ~0.5s apart,
        // inside the 0.6s window) must not leave injected prompt text behind.
        Self.beginClipboardInjection()
        pb.clearContents()
        pb.setString(text, forType: .string)
        // 0.6s: empirical floor before Cmd+V lands; faster restore races the paste.
        defer { Self.endClipboardInjection(after: 0.6) }

        switch terminalApp {
        case .iterm2:
            guard let sessionId = iterm2SessionId else {
                return InjectionResult(success: false, error: "iTerm2 session not yet mapped for window \(windowId)")
            }
            let script = Self.pasteTextScript(iterm2SessionId: sessionId, pressReturn: pressReturn)
            return executeAppleScript(script, context: "pasteText to \(windowId) [iTerm2]")

        case .terminal:
            // Terminal.app accepts both keystroke chars AND clipboard paste;
            // sendText already handles it via the keystroke path. Don't
            // shadow that — fall back signal so caller can use sendText.
            return InjectionResult(success: false, error: "Terminal.app uses sendText keystroke path")

        case .claudeDesktop:
            // Claude Desktop's sendText already routes through NSPasteboard
            // + Cmd+V — that path is tuned for Electron quirks, don't
            // duplicate here.
            return InjectionResult(success: false, error: "Claude Desktop uses sendText paste path")
        }
    }

    /// Pure script builder for `pasteText` so unit tests can lock the shape
    /// without setting NSPasteboard or invoking osascript. Exposed
    /// internal-only. `nonisolated` so tests on the default executor can
    /// call without hopping the main actor.
    nonisolated static func pasteTextScript(iterm2SessionId: String, pressReturn: Bool) -> String {
        let escapedId = escapeForAppleScriptStatic(iterm2SessionId)
        let returnCmd = pressReturn ? "\n                    key code 36" : ""
        return """
        tell application "iTerm2"
            set quipFound to false
            repeat with aWindow in windows
                tell aWindow
                    repeat with aTab in tabs
                        tell aTab
                            repeat with aSession in sessions
                                if unique id of aSession is "\(escapedId)" then
                                    select aSession
                                    set quipFound to true
                                    exit repeat
                                end if
                            end repeat
                        end tell
                        if quipFound then exit repeat
                    end repeat
                end tell
                if quipFound then exit repeat
            end repeat
            if not quipFound then
                error "Quip: iTerm2 session \(escapedId) not found"
            end if
            activate
        end tell
        delay 0.1
        tell application "System Events"
            tell process "iTerm2"
                keystroke "v" using command down\(returnCmd)
            end tell
        end tell
        """
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
        // iTerm2: use native write-text. Byte-identical to typing the key into an
        // iTerm2 session, reliable because write text targets a session by object
        // address rather than by keyboard focus.
        if terminalApp == .iterm2 {
            guard let writeExpr = Self.iTerm2WriteExpression(for: key) else {
                return InjectionResult(success: false, error: "No iTerm2 write expression for key: \(key)")
            }
            // Same rule as sendText: refuse to type into a random front window
            // when we don't have a verified session id. A stray Ctrl+C landing
            // in the wrong terminal kills whatever's running there.
            guard let sessionId = iterm2SessionId else {
                let err = "iTerm2 session not yet mapped for window \(windowId)"
                print("[KeystrokeInjector] sendKeystroke DROPPED: \(err)")
                return InjectionResult(success: false, error: err)
            }
            let escapedId = escapeForAppleScript(sessionId)
            // Walks window → tab → session (same reason as sendText: iTerm2's
            // AppleScript rejects the `sessions of w` shortcut).
            let script = """
            tell application "iTerm2"
                set quipFound to false
                repeat with aWindow in windows
                    tell aWindow
                        repeat with aTab in tabs
                            tell aTab
                                repeat with aSession in sessions
                                    if unique id of aSession is "\(escapedId)" then
                                        tell aSession
                                            -- `newline no` is critical. Without it, iTerm2 appends a
                                            -- CR after every keystroke — Claude Code's Ink prompt reads
                                            -- that as "submit," so backspace (and tab/esc/ctrl-*) would
                                            -- delete a char and then immediately enter the half-edited
                                            -- input. See sendText's comment above for the same rule on
                                            -- the text path.
                                            write text \(writeExpr) newline no
                                        end tell
                                        set quipFound to true
                                        exit repeat
                                    end if
                                end repeat
                            end tell
                            if quipFound then exit repeat
                        end repeat
                    end tell
                    if quipFound then exit repeat
                end repeat
                if not quipFound then
                    error "Quip: iTerm2 session \(escapedId) not found"
                end if
            end tell
            """
            return executeAppleScript(script, context: "sendKeystroke \(key) to \(windowId) [iTerm2 write text, expr=\(writeExpr)]")
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

        case "ctrl+u":
            script = keystrokeScript(
                key: "u", using: "control down",
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

        // Arrow keys via System Events `key code` (keystrokeScript treats these
        // as special keys). Without this, Terminal.app windows silently fail:
        // accept-autocomplete (`right`) and interactive multi-select navigation
        // (`down`/`up`) returned "Unknown key" and no-op'd, working only on
        // iTerm2. `left` rounds out the set for symmetry.
        case "right", "down", "up", "left":
            script = keystrokeScript(
                key: key.lowercased(), using: "",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "backspace", "delete":
            script = keystrokeScript(
                key: "delete", using: "",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        case "shift+tab":
            script = keystrokeScript(
                key: "tab", using: "shift down",
                terminalApp: terminalApp, cgWindowNumber: cgWindowNumber, windowIndex: windowIndex
            )

        default:
            return InjectionResult(success: false, error: "Unknown key: \(key)")
        }

        return executeAppleScript(script, context: "sendKeystroke \(key) to \(windowId) (cgWin=\(cgWindowNumber))")
    }

    /// Map a key descriptor to an AppleScript expression suitable as the
    /// argument to iTerm2's `write text` verb. Single-byte keys come back as
    /// `(character id N)`. Multi-byte sequences (CSI escape codes like Shift+Tab)
    /// come back as a concatenation of `character id` plus a literal string,
    /// which iTerm2 writes verbatim into the session — same effect as a real
    /// terminal seeing those bytes from the keyboard. Returns nil for unknown keys.
    ///
    /// Exposed `internal static` so unit tests can lock the AppleScript shape
    /// for every key (any drift here breaks every keystroke — high-stakes table).
    /// Marked `nonisolated` because it's pure / has no instance state, which
    /// also lets non-MainActor tests call it without an actor hop.
    nonisolated static func iTerm2WriteExpression(for key: String) -> String? {
        switch key.lowercased() {
        case "return", "enter":      return "(character id 13)"   // CR
        case "escape", "esc":        return "(character id 27)"   // ESC
        case "tab":                  return "(character id 9)"    // HT
        case "space":                return "(character id 32)"   // SP — toggles the highlighted checkbox in Ink multiselects
        // Arrow keys as CSI sequences (ESC [ A/B), same verbatim-byte approach as
        // shift+tab below. Ink TUIs (Claude Code) read these as up/down navigation.
        case "up":                   return #"((character id 27) & "[A")"#
        case "down":                 return #"((character id 27) & "[B")"#
        // Right-arrow (CSI C) — the primary accept-autocomplete key: zsh-autosuggestions,
        // fish, and Claude Code inline suggest all accept the greyed ghost text on Right.
        // Bytes derive from TerminalKeyBytes.csi(for: "right").
        case "right":                return #"((character id 27) & "[C")"#
        case "backspace", "delete":  return "(character id 127)"  // DEL
        case "ctrl+c":               return "(character id 3)"    // ETX / SIGINT
        case "ctrl+d":               return "(character id 4)"    // EOT / EOF
        // NAK — readline "kill backward" (clears prompt to start of line in
        // most TUI input layers, including Claude Code's Ink-based prompt).
        case "ctrl+u":               return "(character id 21)"
        // Shift+Tab is the standard CSI sequence ESC [ Z (`back-tab`). Used by
        // Claude Code to cycle the editing mode (normal → autoAccept → plan → normal).
        // iTerm2 writes the concatenated bytes verbatim — the TUI sees them as
        // the same keypress the user would have pressed on a real keyboard.
        case "shift+tab":            return #"((character id 27) & "[Z")"#
        default:                     return nil
        }
    }

    // MARK: - Scrollback (§38)

    /// Direction of scrollback navigation in a terminal window. Mapped to
    /// iTerm2's default menu shortcuts: Shift+PageUp/Down for one page,
    /// Cmd+Home/End for top/bottom. Phone-driven; the user pans the
    /// terminal panel and gets the corresponding action up here.
    enum ScrollDirection: String, Sendable, CaseIterable {
        case pageUp
        case pageDown
        case top
        case bottom

        /// Mac virtual keycode + modifier flags shipped to System Events.
        /// Pulled out as a pure mapping so the unit tests don't need to
        /// stand up an AppleScript runtime.
        var iTerm2Keystroke: (keyCode: Int, modifiers: [String]) {
            switch self {
            case .pageUp:   return (116, ["shift down"])      // Shift+PageUp
            case .pageDown: return (121, ["shift down"])      // Shift+PageDown
            case .top:      return (115, ["command down"])    // Cmd+Home
            case .bottom:   return (119, ["command down"])    // Cmd+End
            }
        }
    }

    /// Scroll the iTerm2 scrollback for a specific window. AppleScript
    /// path: activate iTerm2, walk window→tab→session to select the
    /// target session (so the menu shortcut applies to the right pane),
    /// then send the corresponding keystroke via System Events. (§38.)
    ///
    /// Terminal.app + Claude Desktop are not supported; phone UI should
    /// hide the scroll buttons for those host apps.
    @discardableResult
    func iterm2Scroll(_ direction: ScrollDirection,
                      to windowId: String,
                      iterm2SessionId: String?) -> InjectionResult {
        guard let sessionId = iterm2SessionId else {
            return InjectionResult(success: false, error: "iTerm2 session not yet mapped for window \(windowId)")
        }
        let escapedId = escapeForAppleScript(sessionId)
        let (keyCode, modifiers) = direction.iTerm2Keystroke
        let modSuffix = modifiers.isEmpty ? "" : " using {\(modifiers.joined(separator: ", "))}"

        let script = """
        tell application "iTerm2"
            set quipFound to false
            repeat with aWindow in windows
                tell aWindow
                    repeat with aTab in tabs
                        tell aTab
                            repeat with aSession in sessions
                                if unique id of aSession is "\(escapedId)" then
                                    select aSession
                                    set quipFound to true
                                    exit repeat
                                end if
                            end repeat
                        end tell
                        if quipFound then exit repeat
                    end repeat
                end tell
                if quipFound then exit repeat
            end repeat
            if not quipFound then
                error "Quip: iTerm2 session \(escapedId) not found"
            end if
            activate
        end tell
        delay 0.05
        tell application "System Events"
            tell process "iTerm2"
                key code \(keyCode)\(modSuffix)
            end tell
        end tell
        """
        return executeAppleScript(script, context: "iterm2Scroll(\(direction.rawValue)) to \(windowId)")
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
        case .claudeDesktop:
            return InjectionResult(success: false, error: "Cannot spawn a terminal inside Claude Desktop")

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
        case .claudeDesktop:
            return nil
        case .terminal:
            script = """
            tell application "Terminal"
                return contents of front window
            end tell
            """
        case .iterm2:
            // Read falls under the same "don't guess" rule as sendText. Without
            // a verified session id, the old fallback returned the contents of
            // whichever iTerm2 window happened to be frontmost — that's how
            // the phone ended up displaying another window's buffer while the
            // user thought they were looking at their selection.
            guard let sessionId = iterm2SessionId else { return nil }
            let escapedId = sessionId
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // window → tab → session — see sendText for why the shortcut
            // `sessions of w` can't be used here.
            script = """
            tell application "iTerm2"
                repeat with aWindow in windows
                    tell aWindow
                        repeat with aTab in tabs
                            tell aTab
                                repeat with aSession in sessions
                                    if unique id of aSession is "\(escapedId)" then
                                        tell aSession
                                            return contents
                                        end tell
                                    end if
                                end repeat
                            end tell
                        end repeat
                    end tell
                end repeat
                return ""
            end tell
            """
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

        // A key with a known virtual keycode is injected as `key code N` (special
        // keys: return/escape/tab/delete/arrows); everything else is typed as a
        // literal `keystroke "x"`. Driving this off keyCodeFor (not a parallel
        // list) means the two can't drift — and an unmapped "special" key falls
        // to a visible literal keystroke instead of silently injecting keycode 0
        // (= the `a` key).
        let keystrokeCmd: String
        if let code = Self.keyCodeFor(key) {
            keystrokeCmd = modifiers.isEmpty
                ? "key code \(code)"
                : "key code \(code) using {\(modifiers)}"
        } else {
            keystrokeCmd = modifiers.isEmpty
                ? "keystroke \"\(key)\""
                : "keystroke \"\(key)\" using {\(modifiers)}"
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

    /// Map key names to macOS virtual key codes, or nil for an unmapped key.
    /// `nonisolated static` + internal so the table is unit-testable (mirrors
    /// `iTerm2WriteExpression`). Returning nil (not 0) stops `keystrokeScript`
    /// from silently injecting keycode 0 — the `a` key — for an unknown key.
    nonisolated static func keyCodeFor(_ key: String) -> Int? {
        switch key.lowercased() {
        case "return", "enter": return 36
        case "escape", "esc": return 53
        case "tab": return 48
        case "delete": return 51
        case "space": return 49
        case "down": return 125
        case "up": return 126
        case "right": return 124
        case "left": return 123
        default: return nil
        }
    }

    /// Escape text for use inside AppleScript string literals
    private func escapeForAppleScript(_ text: String) -> String {
        Self.escapeForAppleScriptStatic(text)
    }

    /// Static variant so pure script builders (e.g. `pasteTextScript`) can
    /// produce the same escape without needing an instance. `nonisolated`
    /// to let unit tests call without hopping the main actor.
    nonisolated static func escapeForAppleScriptStatic(_ text: String) -> String {
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
    nonisolated private func executeAppleScript(_ source: String, context: String) -> InjectionResult {
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
            return InjectionResult(success: false, error: message,
                                   kind: Self.classifyAppleScriptError(message))
        }

        return InjectionResult(success: true, error: nil)
    }
}
