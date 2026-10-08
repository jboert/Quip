import Foundation

/// How text that contains line breaks is injected into a terminal (US-008).
///
/// Two bugs had one cause, line breaks reaching the terminal as Enter:
/// - A shell ran each line of a multi-line send as its own command. A prompt
///   whose `{{clipboard}}` held several lines, sent with ↵ into zsh in
///   Terminal.app, ran line by line (QA, 2026-10-07).
/// - Terminal.app's `sendText` types the text as keystrokes and presses Return
///   between lines whether or not the phone asked for Return, so a multi-line
///   prompt to Claude Code in Terminal.app submitted after its first line.
///
/// Rules, for the terminal hosts (`.terminal`, `.iterm2`):
/// - Single-line text: unchanged, `TextInjectionRoute.choose` and the caller's
///   `pressReturn`. One trailing line break still counts as single-line, and
///   it is stripped (see `normalizedText`), so it is never typed as an Enter.
/// - Multi-line text into a shell: `.pasteText`, and Return is never pressed,
///   even when the phone asked for it. The terminal wraps a Cmd+V paste in
///   bracketed-paste markers, so zsh and bash 5.1+ put the block on the command
///   line without running it; the user reviews it and presses Return.
/// - Multi-line text into an agent CLI in Terminal.app: `.pasteText`, with
///   Return pressed once at the end, only when asked.
/// - Multi-line text into an agent CLI in iTerm2: unchanged. iTerm2 writes the
///   text's line feeds, which Claude Code reads as new lines, not as submit;
///   Codex and Grok already paste.
///
/// Claude Desktop is not a terminal and already pastes, so it is left alone.
enum MultiLineSendPolicy {

    /// The route and Return for `text`. Pass the text as received; the decision
    /// is made on `normalizedText(text)`, which is also what the caller injects.
    static func decide(text: String, cliKind: CLIKind, terminalApp: TerminalApp,
                       pressReturn: Bool) -> (route: TextInjectionRoute, pressReturn: Bool) {
        let unchanged = (route: TextInjectionRoute.choose(cliKind: cliKind, terminalApp: terminalApp),
                         pressReturn: pressReturn)
        guard terminalApp == .terminal || terminalApp == .iterm2,
              isMultiLine(normalizedText(text)) else { return unchanged }
        if cliKind == .shell { return (.pasteText, false) }
        if terminalApp == .terminal { return (.pasteText, pressReturn) }
        return unchanged
    }

    /// `text` without one trailing line break. That break is what the user's
    /// Return would have been; typed into a terminal it IS a Return.
    static func normalizedText(_ text: String) -> String {
        guard let last = text.last, last.isNewline else { return text }
        return String(text.dropLast())
    }

    /// Whether `text` contains a line break of any kind (LF, CR, CRLF, U+2028…).
    static func isMultiLine(_ text: String) -> Bool {
        text.contains(where: \.isNewline)
    }

    /// Number of lines in `text`, counting empty ones.
    static func lineCount(_ text: String) -> Int {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
    }

    /// What the latency.log line gains when the policy dropped a Return the
    /// phone asked for: ` multiline_guard=1 lines=N`, otherwise nothing. Counts
    /// only; the text itself is never logged.
    static func latencySuffix(requestedReturn: Bool, decidedReturn: Bool, text: String) -> String {
        guard requestedReturn, !decidedReturn else { return "" }
        return " multiline_guard=1 lines=\(lineCount(normalizedText(text)))"
    }
}
