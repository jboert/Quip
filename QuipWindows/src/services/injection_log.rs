//! `injection.log` lines: one per FAILED injection.
//!
//! Exact port of `KeystrokeInjector.injectionLogLine` / `injectionLogToken` /
//! `injectionLogValue` (`QuipMac/Services/KeystrokeInjector.swift`), pinned by
//! the cases of `QuipMac/Tests/InjectionLogTests.swift`:
//!
//! `DROPPED op=<token> window=<token> app=<token> kind=<kind> msg="<escaped>"[ detail="<escaped>"]`
//!
//! One Windows difference: on the Mac `app` is a `TerminalApp` raw value
//! (`iTerm2`, `Terminal`), which never has spaces. Windows app names do
//! ("Windows Terminal", "Command Prompt"), so `app` goes through the same
//! token rule as `op` and `window` (`Windows_Terminal`). Otherwise a reader
//! splitting on spaces would see `kind` in the wrong column.

/// `KeystrokeInjector.InjectionError`, plus "no classification" (`nil` on the
/// Mac). Closed vocabulary: `kind=` is greppable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InjectionKind {
    SessionNotFound,
    TccDenied,
    WindowClosed,
    Unknown,
    Unclassified,
}

impl InjectionKind {
    pub const ALL: [InjectionKind; 5] = [
        InjectionKind::SessionNotFound,
        InjectionKind::TccDenied,
        InjectionKind::WindowClosed,
        InjectionKind::Unknown,
        InjectionKind::Unclassified,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            InjectionKind::SessionNotFound => "sessionNotFound",
            InjectionKind::TccDenied => "tccDenied",
            InjectionKind::WindowClosed => "windowClosed",
            InjectionKind::Unknown => "unknown",
            InjectionKind::Unclassified => "unclassified",
        }
    }
}

/// `injectionLogToken`: whitespace runs become `_`, empties become `-`.
pub fn token(value: &str) -> String {
    let collapsed: Vec<&str> = value.split(char::is_whitespace).filter(|s| !s.is_empty()).collect();
    if collapsed.is_empty() {
        "-".to_string()
    } else {
        collapsed.join("_")
    }
}

/// `injectionLogValue`: backslash first, then quote, LF, CR.
pub fn value(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n").replace('\r', "\\r")
}

/// `injectionLogLine`. `app` `None` is `-` (a context-only line).
pub fn line(op: &str, window_id: &str, app: Option<&str>, kind: InjectionKind, message: &str, detail: &str) -> String {
    let app = app.map(token).unwrap_or_else(|| "-".to_string());
    let base = format!(
        "DROPPED op={} window={} app={} kind={} msg=\"{}\"",
        token(op),
        token(window_id),
        app,
        kind.as_str(),
        value(message)
    );
    if detail.is_empty() {
        base
    } else {
        format!("{base} detail=\"{}\"", value(detail))
    }
}

/// `logInjectionFailure`: `msg` and `detail` pass through `SecretRedactor`
/// on the way in. Returns the full file line (timestamp + newline), as
/// `appendInjectionLog` writes it.
pub fn redacted_file_line(
    unix_seconds: f64,
    op: &str,
    window_id: &str,
    app: Option<&str>,
    kind: InjectionKind,
    message: &str,
    detail: &str,
) -> String {
    let msg = super::secret_redactor::redact(message);
    let det = if detail.is_empty() { String::new() } else { super::secret_redactor::redact(detail) };
    format!("{} {}\n", super::clock::iso8601(unix_seconds), line(op, window_id, app, kind, &msg, &det))
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/InjectionLogTests.swift`, then the Windows-only cases.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn testLineCarriesOpWindowAppAndKind() {
        let l = line(
            "sendText",
            "com.googlecode.iterm2.808",
            Some("iTerm2"),
            InjectionKind::SessionNotFound,
            "iTerm2 session not yet mapped for window com.googlecode.iterm2.808",
            "",
        );
        assert_eq!(
            l,
            r#"DROPPED op=sendText window=com.googlecode.iterm2.808 app=iTerm2 kind=sessionNotFound msg="iTerm2 session not yet mapped for window com.googlecode.iterm2.808""#
        );
    }

    #[test]
    fn testTccDenialIsLabelledDistinctly() {
        let l = line(
            "sendKeystroke escape to com.googlecode.iterm2.808 [iTerm2]",
            "-",
            None,
            InjectionKind::TccDenied,
            "Not authorized to send Apple events to iTerm2.",
            "",
        );
        assert!(l.contains("kind=tccDenied"), "{l}");
        assert!(l.contains("app=-"));
    }

    #[test]
    fn testUnknownKindDoesNotLeakItsPayloadIntoTheKindField() {
        let l = line("pasteText", "w1", Some("Terminal"), InjectionKind::Unknown, "AppleEvent timed out.", "");
        assert!(l.contains("kind=unknown "), "{l}");
        assert!(!l.contains("kind=unknown("));
    }

    #[test]
    fn testMissingClassificationReadsAsUnclassified() {
        let l = line("spawnWindow", "-", None, InjectionKind::Unclassified, "boom", "");
        assert!(l.contains("kind=unclassified"), "{l}");
    }

    #[test]
    fn testQuotesAndNewlinesCannotForgeASecondLine() {
        let l = line(
            "sendText",
            "w1",
            Some("iTerm2"),
            InjectionKind::Unknown,
            "said \"hi\"\nDROPPED op=forged window=evil",
            "",
        );
        assert!(!l.contains('\n'));
        assert!(l.contains(r#"said \"hi\""#), "{l}");
        assert!(l.ends_with('"'));
    }

    #[test]
    fn testOpWithSpacesCannotBreakTheFieldGrammar() {
        let l = line(
            "sendText to com.googlecode.iterm2.808 [iTerm2]",
            "com.googlecode.iterm2.808",
            Some("iTerm2"),
            InjectionKind::TccDenied,
            "denied",
            "",
        );
        let f: Vec<&str> = l.split(' ').collect();
        assert_eq!(f[0], "DROPPED");
        assert_eq!(f[2], "window=com.googlecode.iterm2.808");
        assert_eq!(f[3], "app=iTerm2");
    }

    #[test]
    fn testEmptyTokenReadsAsADashRatherThanCollapsingTheField() {
        let l = line("spawnWindow", "", None, InjectionKind::Unclassified, "boom", "");
        assert!(l.contains("window=- "), "{l}");
    }

    #[test]
    fn testDetailIsQuotedAndOnlyPresentWhenGiven() {
        let with =
            line("sendKeystroke", "w1", Some("iTerm2"), InjectionKind::Unknown, "boom", "key=shift+tab cgWin=808");
        assert!(with.ends_with(r#"detail="key=shift+tab cgWin=808""#), "{with}");
        let without = line("sendKeystroke", "w1", Some("iTerm2"), InjectionKind::Unknown, "boom", "");
        assert!(!without.contains("detail="));
    }

    #[test]
    fn testDetailCannotForgeASecondLineEither() {
        let l =
            line("spawnWindow", "-", None, InjectionKind::Unclassified, "boom", "cmd=echo \"hi\"\nDROPPED op=forged");
        assert!(!l.contains('\n'));
        assert!(l.ends_with('"'));
    }

    #[test]
    fn testBackslashIsEscapedBeforeQuotes() {
        assert_eq!(value(r"a\b"), r"a\\b");
        assert_eq!(value("a\rb"), r"a\rb");
        assert_eq!(value("\\\""), r#"\\\""#);
    }

    // --- Windows-only ---

    #[test]
    fn kind_is_a_closed_vocabulary() {
        let words: Vec<&str> = InjectionKind::ALL.iter().map(|k| k.as_str()).collect();
        assert_eq!(words, ["sessionNotFound", "tccDenied", "windowClosed", "unknown", "unclassified"]);
    }

    #[test]
    fn op_window_and_app_never_contain_spaces() {
        let l =
            line("send text\tnow", "w 1\n2", Some("Windows Terminal"), InjectionKind::Unknown, "m", "focus refused");
        let f: Vec<&str> = l.split(' ').collect();
        assert_eq!(f[1], "op=send_text_now");
        assert_eq!(f[2], "window=w_1_2");
        assert_eq!(f[3], "app=Windows_Terminal");
        assert_eq!(f[4], "kind=unknown");
    }

    #[test]
    fn file_line_is_timestamped_and_redacted() {
        let l = redacted_file_line(
            0.0,
            "sendText",
            "w-1",
            Some("PowerShell"),
            InjectionKind::Unknown,
            "token=abcdefghijklmnopqrstuvwxyz",
            "focus refused",
        );
        assert!(l.starts_with("1970-01-01T00:00:00Z DROPPED op=sendText "), "{l}");
        assert!(l.ends_with("detail=\"focus refused\"\n"));
        assert!(!l.contains("abcdefghijklmnopqrstuvwxyz"));
    }
}
