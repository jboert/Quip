import XCTest
@testable import Quip

/// US-008: multi-line text never runs line by line in a shell, and never
/// submits after its first line in Terminal.app.
final class MultiLineSendPolicyTests: XCTestCase {

    private let threeLines = "echo one\necho two\necho three"
    private let agents: [CLIKind] = [.claude, .codex, .grok, .cursor]

    private func decide(_ text: String, _ cli: CLIKind, _ term: TerminalApp,
                        _ pressReturn: Bool) -> (route: TextInjectionRoute, pressReturn: Bool) {
        MultiLineSendPolicy.decide(text: text, cliKind: cli, terminalApp: term, pressReturn: pressReturn)
    }

    // MARK: - Rule 1: single-line text is unchanged

    func test_singleLine_keepsTodaysRouteAndReturn() {
        for cli in CLIKind.allCases {
            for term in TerminalApp.allCases {
                for pr in [true, false] {
                    let d = decide("echo hi", cli, term, pr)
                    XCTAssertEqual(d.route, TextInjectionRoute.choose(cliKind: cli, terminalApp: term),
                                   "\(cli) in \(term)")
                    XCTAssertEqual(d.pressReturn, pr, "\(cli) in \(term)")
                }
            }
        }
    }

    // MARK: - Rule 2: multi-line into a shell pastes and never presses Return

    func test_multiLineShell_pastesWithoutReturn_inBothTerminals() {
        for term in [TerminalApp.terminal, .iterm2] {
            for pr in [true, false] {
                let d = decide(threeLines, .shell, term, pr)
                XCTAssertEqual(d.route, .pasteText, "\(term)")
                XCTAssertFalse(d.pressReturn, "a shell must never get a Return after a multi-line paste (\(term))")
            }
        }
    }

    // MARK: - Rule 3: multi-line into an agent CLI in Terminal.app pastes, Return as asked

    func test_multiLineAgentInTerminalApp_pastesWithReturnAsAsked() {
        for cli in agents {
            for pr in [true, false] {
                let d = decide(threeLines, cli, .terminal, pr)
                XCTAssertEqual(d.route, .pasteText, "\(cli)")
                XCTAssertEqual(d.pressReturn, pr, "\(cli)")
            }
        }
    }

    // MARK: - Rule 4: multi-line into an agent CLI in iTerm2 is unchanged

    func test_multiLineAgentInITerm2_isUnchanged() {
        for cli in agents {
            for pr in [true, false] {
                let d = decide(threeLines, cli, .iterm2, pr)
                XCTAssertEqual(d.route, TextInjectionRoute.choose(cliKind: cli, terminalApp: .iterm2), "\(cli)")
                XCTAssertEqual(d.pressReturn, pr, "\(cli)")
            }
        }
    }

    // MARK: - Rule 5: one trailing newline counts as single-line and is stripped

    func test_oneTrailingNewline_isSingleLine() {
        let d = decide("ls\n", .shell, .terminal, true)
        XCTAssertEqual(d.route, .sendText)
        XCTAssertTrue(d.pressReturn)
        XCTAssertEqual(MultiLineSendPolicy.normalizedText("ls\n"), "ls",
                       "the trailing newline is not injected; typed into a terminal it would be an Enter")
        XCTAssertEqual(MultiLineSendPolicy.normalizedText("ls\r\n"), "ls")
    }

    func test_trailingNewlineOnMultiLineText_isStrippedButStillMultiLine() {
        XCTAssertEqual(MultiLineSendPolicy.normalizedText("a\nb\n"), "a\nb")
        XCTAssertEqual(decide("a\nb\n", .shell, .terminal, true).route, .pasteText)
        // Only ONE trailing break is forgiven: a blank last line is still a line.
        XCTAssertTrue(MultiLineSendPolicy.isMultiLine(MultiLineSendPolicy.normalizedText("a\n\n")))
    }

    func test_textWithoutTrailingNewline_isLeftAlone() {
        XCTAssertEqual(MultiLineSendPolicy.normalizedText("a\nb"), "a\nb")
        XCTAssertEqual(MultiLineSendPolicy.normalizedText(""), "")
    }

    // MARK: - Edges

    func test_carriageReturnCountsAsALineBreak() {
        // A bare CR typed into a terminal is Enter too.
        XCTAssertEqual(decide("echo one\recho two", .shell, .iterm2, true).route, .pasteText)
        XCTAssertFalse(decide("echo one\r\necho two", .shell, .terminal, true).pressReturn)
    }

    func test_claudeDesktopIsLeftAlone() {
        let d = decide(threeLines, .shell, .claudeDesktop, true)
        XCTAssertEqual(d.route, .sendText, "Claude Desktop is not a terminal; its sendText already pastes")
        XCTAssertTrue(d.pressReturn)
    }

    // MARK: - latency.log suffix

    func test_latencySuffix_onlyWhenARequestedReturnWasDropped() {
        XCTAssertEqual(MultiLineSendPolicy.latencySuffix(requestedReturn: true, decidedReturn: false,
                                                         text: threeLines),
                       " multiline_guard=1 lines=3")
        XCTAssertEqual(MultiLineSendPolicy.latencySuffix(requestedReturn: false, decidedReturn: false,
                                                         text: threeLines), "")
        XCTAssertEqual(MultiLineSendPolicy.latencySuffix(requestedReturn: true, decidedReturn: true,
                                                         text: threeLines), "")
    }

    func test_latencySuffix_countsLinesAfterTheTrailingNewlineIsStripped_andNeverCarriesText() {
        let suffix = MultiLineSendPolicy.latencySuffix(requestedReturn: true, decidedReturn: false,
                                                       text: "SECRET-1\nSECRET-2\n")
        XCTAssertEqual(suffix, " multiline_guard=1 lines=2")
        XCTAssertFalse(suffix.contains("SECRET"))
    }

    func test_lineCount() {
        XCTAssertEqual(MultiLineSendPolicy.lineCount("one"), 1)
        XCTAssertEqual(MultiLineSendPolicy.lineCount("a\nb\nc"), 3)
        XCTAssertEqual(MultiLineSendPolicy.lineCount("a\n\nc"), 3)
    }
}

/// Locks the Terminal.app paste script the way `PasteTextScriptTests` locks
/// the iTerm2 one: no osascript, no pasteboard.
final class TerminalPasteTextScriptTests: XCTestCase {

    func test_activatesTerminalThenSendsCmdVToTerminal() {
        let script = KeystrokeInjector.terminalPasteTextScript(pressReturn: false)
        XCTAssertTrue(script.contains("tell application \"Terminal\" to activate"))
        XCTAssertTrue(script.contains("tell process \"Terminal\""))
        XCTAssertTrue(script.contains("keystroke \"v\" using command down"))
        guard let activate = script.range(of: "to activate"),
              let paste = script.range(of: "keystroke \"v\" using command down") else {
            return XCTFail("script missing activate or Cmd+V")
        }
        XCTAssertLessThan(activate.lowerBound, paste.lowerBound,
                          "Terminal must be frontmost before Cmd+V lands")
        XCTAssertFalse(script.contains("iTerm2"))
    }

    func test_pressReturnFalse_neverPressesReturn() {
        let script = KeystrokeInjector.terminalPasteTextScript(pressReturn: false)
        XCTAssertFalse(script.contains("key code 36"),
                       "a paste-only send must not press Return: a shell would run the block")
    }

    func test_pressReturnTrue_pressesReturnOnceAfterThePaste() {
        let script = KeystrokeInjector.terminalPasteTextScript(pressReturn: true)
        XCTAssertEqual(script.components(separatedBy: "key code 36").count - 1, 1,
                       "Return is pressed once, at the end, not between lines")
        guard let paste = script.range(of: "keystroke \"v\" using command down"),
              let enter = script.range(of: "key code 36") else {
            return XCTFail("script missing Cmd+V or Return")
        }
        XCTAssertLessThan(paste.lowerBound, enter.lowerBound)
    }

    func test_typesNothingButCmdV() {
        // The text rides the clipboard, never the script, so nothing in it can
        // be read as AppleScript or typed as keystrokes (a typed line feed is
        // exactly the Return this path exists to avoid).
        for pr in [true, false] {
            let script = KeystrokeInjector.terminalPasteTextScript(pressReturn: pr)
            XCTAssertEqual(script.components(separatedBy: "keystroke \"").count - 1, 1,
                           "the only keystroke is the Cmd+V")
        }
    }
}

/// The CLI kind `send_text` and `paste_prompt` hand to `MultiLineSendPolicy`
/// (`QuipMacApp.routingCLIKind`). paste_prompt used the cached kind as it was,
/// so a stale `.shell` cache on a Claude window turned a multi-line prompt into
/// a paste with no Return.
final class RoutingCLIKindTests: XCTestCase {

    private let threeLines = "line one\nline two\nline three"

    func test_aShellOrMissingCacheIsReclassified() {
        XCTAssertEqual(QuipMacApp.routingCLIKind(cached: .shell) { .claude }, .claude)
        XCTAssertEqual(QuipMacApp.routingCLIKind(cached: nil) { .codex }, .codex)
        XCTAssertEqual(QuipMacApp.routingCLIKind(cached: .shell) { .shell }, .shell,
                       "a window that really is a shell stays one")
    }

    func test_aCachedAgentKindIsTrustedWithoutReclassifying() {
        for kind in CLIKind.allCases where kind != .shell {
            var reclassified = false
            let chosen = QuipMacApp.routingCLIKind(cached: kind) { reclassified = true; return .shell }
            XCTAssertEqual(chosen, kind)
            XCTAssertFalse(reclassified, "\(kind): a re-classify on every press is the latency cost send_text avoids")
        }
    }

    /// The regression: a multi-line prompt with Return to Claude Code in iTerm2
    /// while the cache still said `.shell`.
    func test_aStaleShellCacheOnClaudeInITerm2StillSubmitsAMultiLinePrompt() {
        let stale = MultiLineSendPolicy.decide(text: threeLines, cliKind: .shell,
                                               terminalApp: .iterm2, pressReturn: true)
        XCTAssertEqual(stale.route, .pasteText, "precondition: decided on the stale kind, the Return is dropped")
        XCTAssertFalse(stale.pressReturn)

        let kind = QuipMacApp.routingCLIKind(cached: .shell) { .claude }
        let d = MultiLineSendPolicy.decide(text: threeLines, cliKind: kind,
                                           terminalApp: .iterm2, pressReturn: true)
        XCTAssertEqual(d.route, .sendText)
        XCTAssertTrue(d.pressReturn, "submitted, as it was before US-008")
    }
}
