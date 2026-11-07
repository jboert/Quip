//! How text with line breaks is injected (US-008 on the Mac).
//!
//! Two layers:
//!
//! 1. An exact port of `QuipMac/Services/MultiLineSendPolicy.swift`
//!    (`decide`, `normalized_text`, `is_multi_line`, `line_count`,
//!    `latency_suffix`), with the Mac's `TerminalApp` and
//!    `TextInjectionRoute`, so the shared vectors (`vectors/multiline.json`)
//!    can drive it unchanged.
//! 2. The Windows decision (`windows_decide`), from M0 (spec 5.4 step 5):
//!    - one trailing line break is stripped and never typed as an Enter;
//!    - single-line text is typed, Return only when asked;
//!    - multi-line text into PowerShell / pwsh (PSReadLine) is typed with each
//!      INNER break as Shift+Enter, and the final Return is never pressed
//!      (the Mac's "a shell never gets a Return after a multi-line paste");
//!    - multi-line text into `cmd.exe` or an unknown shell is REFUSED: M0 saw
//!      both Shift+Enter and paste run lines early there. No clipboard path.
//!
//! "Line break" is Swift's `Character.isNewline`: LF, VT, FF, CR, CRLF (one
//! break), NEL, U+2028, U+2029.

/// Mac `TerminalApp` (`QuipMac/Models/WindowInfo.swift`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalApp {
    Iterm2,
    Terminal,
    ClaudeDesktop,
}

impl TerminalApp {
    pub const ALL: [TerminalApp; 3] = [TerminalApp::Iterm2, TerminalApp::Terminal, TerminalApp::ClaudeDesktop];

    /// Raw values, as the vectors spell them.
    pub fn from_raw(raw: &str) -> Option<Self> {
        match raw {
            "iTerm2" | "iterm2" => Some(TerminalApp::Iterm2),
            "Terminal" | "terminal" => Some(TerminalApp::Terminal),
            "Claude" | "claudeDesktop" => Some(TerminalApp::ClaudeDesktop),
            _ => None,
        }
    }
}

/// Mac `TextInjectionRoute`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    PasteText,
    SendText,
}

impl Route {
    pub fn as_str(self) -> &'static str {
        match self {
            Route::PasteText => "pasteText",
            Route::SendText => "sendText",
        }
    }

    /// `TextInjectionRoute.choose`.
    pub fn choose(cli: crate::protocol::types::CliKind, app: TerminalApp) -> Route {
        use crate::protocol::types::CliKind;
        match (cli, app) {
            (CliKind::Codex, TerminalApp::Iterm2) | (CliKind::Grok, TerminalApp::Iterm2) => Route::PasteText,
            _ => Route::SendText,
        }
    }
}

/// `Character.isNewline` for a single scalar (CRLF is handled by `breaks`).
pub fn is_newline_char(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Split `text` at line breaks, CRLF counting as one. Empty pieces kept, as
/// Swift's `split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)`.
pub fn split_lines(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut iter = text.char_indices().peekable();
    while let Some((i, c)) = iter.next() {
        if is_newline_char(c) {
            out.push(&text[start..i]);
            let mut end = i + c.len_utf8();
            if c == '\r' {
                if let Some(&(j, '\n')) = iter.peek() {
                    iter.next();
                    end = j + 1;
                }
            }
            start = end;
        }
    }
    out.push(&text[start..]);
    out
}

/// `normalizedText`: drop ONE trailing line break (CRLF is one).
pub fn normalized_text(text: &str) -> &str {
    if let Some(stripped) = text.strip_suffix("\r\n") {
        return stripped;
    }
    match text.chars().last() {
        Some(c) if is_newline_char(c) => &text[..text.len() - c.len_utf8()],
        _ => text,
    }
}

/// `isMultiLine`.
pub fn is_multi_line(text: &str) -> bool {
    text.chars().any(is_newline_char)
}

/// `lineCount`.
pub fn line_count(text: &str) -> usize {
    split_lines(text).len()
}

/// `MultiLineSendPolicy.decide`, verbatim.
pub fn decide(text: &str, cli: crate::protocol::types::CliKind, app: TerminalApp, press_return: bool) -> (Route, bool) {
    use crate::protocol::types::CliKind;
    let unchanged = (Route::choose(cli, app), press_return);
    let is_terminal = matches!(app, TerminalApp::Terminal | TerminalApp::Iterm2);
    if !is_terminal || !is_multi_line(normalized_text(text)) {
        return unchanged;
    }
    if cli == CliKind::Shell {
        return (Route::PasteText, false);
    }
    if app == TerminalApp::Terminal {
        return (Route::PasteText, press_return);
    }
    unchanged
}

/// `latencySuffix`: ` multiline_guard=1 lines=N` only when a requested Return
/// was dropped. Counts only; never text.
pub fn latency_suffix(requested_return: bool, decided_return: bool, text: &str) -> String {
    if !requested_return || decided_return {
        return String::new();
    }
    format!(" multiline_guard=1 lines={}", line_count(normalized_text(text)))
}

/// The shell behind a Windows terminal (`classify.rs`, spec 5.1 / 5.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Shell {
    /// Windows PowerShell 5.x (`powershell.exe`), PSReadLine.
    PowerShell,
    /// PowerShell 7 (`pwsh.exe`), PSReadLine.
    Pwsh,
    Cmd,
    Unknown,
}

impl Shell {
    pub fn as_str(self) -> &'static str {
        match self {
            Shell::PowerShell => "powershell",
            Shell::Pwsh => "pwsh",
            Shell::Cmd => "cmd",
            Shell::Unknown => "unknown",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Shell> {
        match raw {
            "powershell" => Some(Shell::PowerShell),
            "pwsh" => Some(Shell::Pwsh),
            "cmd" => Some(Shell::Cmd),
            "unknown" => Some(Shell::Unknown),
            _ => None,
        }
    }

    /// Proven by M0 to take Shift+Enter as "new line, do not run".
    pub fn multi_line_safe(self) -> bool {
        matches!(self, Shell::PowerShell | Shell::Pwsh)
    }
}

/// What to type into a Windows terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WindowsSend {
    /// Type `segments` with a Shift+Enter between each pair (never after the
    /// last), then Return only if `press_return`.
    Type { segments: Vec<String>, press_return: bool },
    /// Type nothing. The caller sends `error` and logs
    /// `kind=unknown detail="multi-line not safe in this shell"`.
    Refuse,
}

pub const REFUSE_DETAIL: &str = "multi-line not safe in this shell";

/// The Windows decision. Every terminal is `cliKind: shell` in phase 1, so the
/// Mac's shell rule applies: multi-line never gets the final Return.
pub fn windows_decide(text: &str, shell: Shell, press_return: bool) -> WindowsSend {
    let body = normalized_text(text);
    if !is_multi_line(body) {
        return WindowsSend::Type { segments: vec![body.to_string()], press_return };
    }
    if !shell.multi_line_safe() {
        return WindowsSend::Refuse;
    }
    WindowsSend::Type { segments: split_lines(body).into_iter().map(str::to_string).collect(), press_return: false }
}

/// The Return the phone asked for vs the one `windows_decide` allows, for
/// `latency_suffix`.
pub fn decided_return(send: &WindowsSend) -> bool {
    matches!(send, WindowsSend::Type { press_return: true, .. })
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/MultiLineSendPolicyTests.swift` (MultiLineSendPolicyTests
    //! class), then the Windows decision.
    #![allow(non_snake_case)]
    use super::*;
    use crate::protocol::types::CliKind;

    const THREE: &str = "echo one\necho two\necho three";
    const AGENTS: [CliKind; 4] = [CliKind::Claude, CliKind::Codex, CliKind::Grok, CliKind::Cursor];

    #[test]
    fn test_singleLine_keepsTodaysRouteAndReturn() {
        for cli in CliKind::ALL {
            for app in TerminalApp::ALL {
                for pr in [true, false] {
                    assert_eq!(decide("echo hi", cli, app, pr), (Route::choose(cli, app), pr));
                }
            }
        }
    }

    #[test]
    fn test_multiLineShell_pastesWithoutReturn_inBothTerminals() {
        for app in [TerminalApp::Terminal, TerminalApp::Iterm2] {
            for pr in [true, false] {
                assert_eq!(decide(THREE, CliKind::Shell, app, pr), (Route::PasteText, false));
            }
        }
    }

    #[test]
    fn test_multiLineAgentInTerminalApp_pastesWithReturnAsAsked() {
        for cli in AGENTS {
            for pr in [true, false] {
                assert_eq!(decide(THREE, cli, TerminalApp::Terminal, pr), (Route::PasteText, pr));
            }
        }
    }

    #[test]
    fn test_multiLineAgentInITerm2_isUnchanged() {
        for cli in AGENTS {
            for pr in [true, false] {
                assert_eq!(decide(THREE, cli, TerminalApp::Iterm2, pr), (Route::choose(cli, TerminalApp::Iterm2), pr));
            }
        }
    }

    #[test]
    fn test_oneTrailingNewline_isSingleLine() {
        assert_eq!(decide("ls\n", CliKind::Shell, TerminalApp::Terminal, true), (Route::SendText, true));
        assert_eq!(normalized_text("ls\n"), "ls");
        assert_eq!(normalized_text("ls\r\n"), "ls");
    }

    #[test]
    fn test_trailingNewlineOnMultiLineText_isStrippedButStillMultiLine() {
        assert_eq!(normalized_text("a\nb\n"), "a\nb");
        assert_eq!(decide("a\nb\n", CliKind::Shell, TerminalApp::Terminal, true).0, Route::PasteText);
        assert!(is_multi_line(normalized_text("a\n\n")));
    }

    #[test]
    fn test_textWithoutTrailingNewline_isLeftAlone() {
        assert_eq!(normalized_text("a\nb"), "a\nb");
        assert_eq!(normalized_text(""), "");
    }

    #[test]
    fn test_carriageReturnCountsAsALineBreak() {
        assert_eq!(decide("echo one\recho two", CliKind::Shell, TerminalApp::Iterm2, true).0, Route::PasteText);
        assert!(!decide("echo one\r\necho two", CliKind::Shell, TerminalApp::Terminal, true).1);
    }

    #[test]
    fn test_claudeDesktopIsLeftAlone() {
        assert_eq!(decide(THREE, CliKind::Shell, TerminalApp::ClaudeDesktop, true), (Route::SendText, true));
    }

    #[test]
    fn test_latencySuffix_onlyWhenARequestedReturnWasDropped() {
        assert_eq!(latency_suffix(true, false, THREE), " multiline_guard=1 lines=3");
        assert_eq!(latency_suffix(false, false, THREE), "");
        assert_eq!(latency_suffix(true, true, THREE), "");
    }

    #[test]
    fn test_latencySuffix_countsLinesAfterTheTrailingNewlineIsStripped_andNeverCarriesText() {
        let s = latency_suffix(true, false, "SECRET-1\nSECRET-2\n");
        assert_eq!(s, " multiline_guard=1 lines=2");
        assert!(!s.contains("SECRET"));
    }

    #[test]
    fn test_lineCount() {
        assert_eq!(line_count("one"), 1);
        assert_eq!(line_count("a\nb\nc"), 3);
        assert_eq!(line_count("a\n\nc"), 3);
    }

    #[test]
    fn route_choose_only_codex_and_grok_in_iterm2_paste() {
        for cli in CliKind::ALL {
            for app in TerminalApp::ALL {
                let want =
                    matches!((cli, app), (CliKind::Codex, TerminalApp::Iterm2) | (CliKind::Grok, TerminalApp::Iterm2));
                assert_eq!(Route::choose(cli, app) == Route::PasteText, want, "{cli:?} {app:?}");
            }
        }
    }

    // --- Windows-only: CRLF and U+2028 are one break each ---

    #[test]
    fn crlf_is_one_break_and_u2028_is_a_break() {
        assert_eq!(line_count("a\r\nb"), 2);
        assert_eq!(line_count("a\u{2028}b"), 2);
        assert_eq!(line_count("a\u{2029}b\u{85}c\u{0B}d\u{0C}e"), 5);
        assert_eq!(line_count("a\n\rb"), 3, "LF then CR is two breaks");
        assert_eq!(normalized_text("ls\u{2028}"), "ls");
        assert_eq!(normalized_text("a\r\n\r\n"), "a\r\n", "only one trailing break goes");
        assert_eq!(split_lines("x\r\ny"), ["x", "y"]);
        assert!(!is_multi_line("é😀 plain"));
    }

    // --- Windows decision (M0) ---

    #[test]
    fn windows_single_line_is_typed_with_return_as_asked() {
        for shell in [Shell::PowerShell, Shell::Pwsh, Shell::Cmd, Shell::Unknown] {
            for pr in [true, false] {
                assert_eq!(
                    windows_decide("Get-Date", shell, pr),
                    WindowsSend::Type { segments: vec!["Get-Date".into()], press_return: pr }
                );
            }
        }
    }

    #[test]
    fn windows_one_trailing_newline_is_stripped_and_single_line_even_in_cmd() {
        assert_eq!(
            windows_decide("dir\n", Shell::Cmd, true),
            WindowsSend::Type { segments: vec!["dir".into()], press_return: true }
        );
        assert_eq!(
            windows_decide("dir\r\n", Shell::Unknown, false),
            WindowsSend::Type { segments: vec!["dir".into()], press_return: false }
        );
    }

    #[test]
    fn windows_multi_line_powershell_splits_and_never_returns() {
        for shell in [Shell::PowerShell, Shell::Pwsh] {
            for pr in [true, false] {
                assert_eq!(
                    windows_decide("a\nb\r\nc\u{2028}d\n", shell, pr),
                    WindowsSend::Type {
                        segments: vec!["a".into(), "b".into(), "c".into(), "d".into()],
                        press_return: false
                    }
                );
            }
        }
    }

    #[test]
    fn windows_multi_line_keeps_blank_inner_lines() {
        assert_eq!(
            windows_decide("a\n\nb", Shell::Pwsh, true),
            WindowsSend::Type { segments: vec!["a".into(), "".into(), "b".into()], press_return: false }
        );
    }

    #[test]
    fn windows_multi_line_cmd_and_unknown_are_refused() {
        for shell in [Shell::Cmd, Shell::Unknown] {
            for pr in [true, false] {
                assert_eq!(windows_decide("a\nb", shell, pr), WindowsSend::Refuse);
                assert_eq!(windows_decide("a\u{2028}b", shell, pr), WindowsSend::Refuse);
                assert_eq!(windows_decide("a\r\nb\n", shell, pr), WindowsSend::Refuse);
            }
        }
    }

    #[test]
    fn windows_decision_agrees_with_the_mac_shell_rule_on_return() {
        // Every Windows terminal is cliKind shell: the Mac's decide() says
        // "no Return" for multi-line, and so must windows_decide.
        for text in ["a\nb", "a\r\nb\n", "x", "x\n"] {
            let (_, mac_return) = decide(text, CliKind::Shell, TerminalApp::Terminal, true);
            let win = windows_decide(text, Shell::Pwsh, true);
            assert_eq!(decided_return(&win), mac_return, "{text:?}");
        }
    }

    #[test]
    fn shell_raw_values_round_trip() {
        for s in [Shell::PowerShell, Shell::Pwsh, Shell::Cmd, Shell::Unknown] {
            assert_eq!(Shell::from_raw(s.as_str()), Some(s));
        }
        assert!(Shell::PowerShell.multi_line_safe() && Shell::Pwsh.multi_line_safe());
        assert!(!Shell::Cmd.multi_line_safe() && !Shell::Unknown.multi_line_safe());
    }

    #[test]
    fn raw_names_as_the_vectors_spell_them() {
        assert_eq!(TerminalApp::from_raw("iTerm2"), Some(TerminalApp::Iterm2));
        assert_eq!(TerminalApp::from_raw("Terminal"), Some(TerminalApp::Terminal));
        assert_eq!(TerminalApp::from_raw("Claude"), Some(TerminalApp::ClaudeDesktop));
        assert_eq!(TerminalApp::from_raw("Konsole"), None);
        assert_eq!(Route::PasteText.as_str(), "pasteText");
        assert_eq!(Route::SendText.as_str(), "sendText");
    }
}
