//! The `--selftest` report (spec 10.5): its format, its exit code, and what
//! it must never say. Pure, so all of it is tested on the Mac; the cases that
//! fill it run only on Windows (`selftest::win32`).
//!
//! The owner sends the file back and it is stored in the repo, so the whole
//! text goes through `Redactor` before it is written: no machine name, user
//! name, profile path, IP address, or title of a window the selftest did not
//! open.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use regex::Regex;

use crate::services::clock::iso8601;
use crate::services::layout::PixelRect;

/// What one case found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Pass,
    /// What went wrong. May span several lines; the first goes on the case
    /// line, the rest are indented under it.
    Fail(String),
    /// Why the case could not run here (e.g. no `wt.exe`). Not a pass.
    Skip(String),
}

impl Outcome {
    pub fn label(&self) -> &'static str {
        match self {
            Outcome::Pass => "PASS",
            Outcome::Fail(_) => "FAIL",
            Outcome::Skip(_) => "SKIP",
        }
    }

    fn detail(&self) -> Option<&str> {
        match self {
            Outcome::Pass => None,
            Outcome::Fail(d) | Outcome::Skip(d) => Some(d),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CaseResult {
    pub name: String,
    pub outcome: Outcome,
    /// Evidence a case records whatever its outcome (the focus step used,
    /// what the integrity probe saw), one `note:` line each under it.
    pub notes: Vec<String>,
}

/// One monitor as the header shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DisplayInfo {
    pub name: String,
    pub is_primary: bool,
    pub bounds: PixelRect,
    pub work_area: PixelRect,
    /// `GetDpiForMonitor(MDT_EFFECTIVE_DPI)`; `None` when Windows did not say.
    pub dpi: Option<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Header {
    pub unix_seconds: f64,
    pub quip_version: String,
    pub git_sha: Option<String>,
    /// `major.minor.build`, e.g. `10.0.26100`.
    pub windows_version: Option<String>,
    pub displays: Vec<DisplayInfo>,
}

/// Every case passed.
pub const EXIT_ALL_PASSED: i32 = 0;
/// At least one case failed (or none ran, or the report was not written).
pub const EXIT_FAILED: i32 = 1;
/// Nothing failed, but at least one case was skipped.
pub const EXIT_SKIPPED: i32 = 3;

fn counts(results: &[CaseResult]) -> (usize, usize, usize) {
    let n = |label: &str| results.iter().filter(|r| r.outcome.label() == label).count();
    (n("PASS"), n("FAIL"), n("SKIP"))
}

/// 0 only when every case passed; a skip is not a pass.
pub fn exit_code(results: &[CaseResult]) -> i32 {
    match counts(results) {
        _ if results.is_empty() => EXIT_FAILED,
        (_, f, _) if f > 0 => EXIT_FAILED,
        (_, _, s) if s > 0 => EXIT_SKIPPED,
        _ => EXIT_ALL_PASSED,
    }
}

/// The last line of the report.
pub fn summary_line(results: &[CaseResult]) -> String {
    let (p, f, s) = counts(results);
    let verdict = match exit_code(results) {
        EXIT_ALL_PASSED => "PASS",
        EXIT_SKIPPED => "INCOMPLETE",
        _ => "FAIL",
    };
    format!("SUMMARY {verdict}: {p} passed, {f} failed, {s} skipped of {} cases", results.len())
}

/// `selftest-20261106T123456Z.txt` (no `:`, which Windows file names cannot
/// hold); `attempt` > 0 adds `-<attempt>` for a second run in the same second.
pub fn file_name(unix_seconds: f64, attempt: u32) -> String {
    let stamp: String = iso8601(unix_seconds).chars().filter(|c| *c != '-' && *c != ':').collect();
    if attempt == 0 {
        format!("selftest-{stamp}.txt")
    } else {
        format!("selftest-{stamp}-{attempt}.txt")
    }
}

/// Windows' scale setting for a DPI: 96 is 100 %, 144 is 150 %.
pub fn scale_percent(dpi: u32) -> u32 {
    (dpi * 100 + 48) / 96
}

fn rect(r: PixelRect) -> String {
    format!("{}x{} at {},{}", r.width, r.height, r.x, r.y)
}

/// The whole report, redacted. One `PASS`/`FAIL`/`SKIP` line per case, a
/// detail's further lines indented under it, `SUMMARY` last.
pub fn format_report(header: &Header, results: &[CaseResult], redactor: &Redactor) -> String {
    let mut out = String::new();
    out.push_str("Quip selftest\n");
    out.push_str(&format!("time: {}\n", iso8601(header.unix_seconds)));
    let sha = header.git_sha.as_deref().map(|s| format!(" (git {s})")).unwrap_or_default();
    out.push_str(&format!("quip: {}{sha}\n", header.quip_version));
    out.push_str(&format!("windows: {}\n", header.windows_version.as_deref().unwrap_or("unknown")));
    out.push_str(&format!("displays: {}\n", header.displays.len()));
    for (i, d) in header.displays.iter().enumerate() {
        let dpi =
            d.dpi.map(|dpi| format!("dpi {dpi} ({}%)", scale_percent(dpi))).unwrap_or_else(|| "dpi unknown".into());
        out.push_str(&format!(
            "display {}: {}{} {} work {} {dpi}\n",
            i + 1,
            d.name,
            if d.is_primary { " primary" } else { "" },
            rect(d.bounds),
            rect(d.work_area),
        ));
    }
    for r in results {
        out.push_str(&format!("{} {}", r.outcome.label(), r.name));
        if let Some(detail) = r.outcome.detail() {
            let mut lines = detail.lines().filter(|l| !l.trim().is_empty());
            if let Some(first) = lines.next() {
                out.push_str(&format!(": {}", first.trim_end()));
            }
            for l in lines {
                out.push_str(&format!("\n    {}", l.trim_end()));
            }
        }
        for n in r.notes.iter().flat_map(|n| n.lines()).filter(|l| !l.trim().is_empty()) {
            out.push_str(&format!("\n    note: {}", n.trim_end()));
        }
        out.push('\n');
    }
    out.push_str(&summary_line(results));
    out.push('\n');
    redactor.redact(&out)
}

/// Removes what identifies the machine or its user. Built from the
/// environment (`from_env`), then told which window titles belong to windows
/// the selftest opened (`own_title`, kept) and which it merely saw
/// (`foreign_title`, replaced by `<title>`).
#[derive(Debug, Clone, Default)]
pub struct Redactor {
    /// Profile folders, e.g. `C:\Users\bob`.
    profiles: Vec<String>,
    /// (value, placeholder): user, machine and domain names.
    names: Vec<(String, &'static str)>,
    own_titles: BTreeSet<String>,
    foreign_titles: BTreeSet<String>,
}

/// A foreign title shorter than this is not replaced: replacing a one- or
/// two-letter title everywhere would garble the report and hides nothing.
const MIN_TITLE_CHARS: usize = 3;

impl Redactor {
    pub fn new() -> Self {
        Self::default()
    }

    /// `USERPROFILE`, `USERNAME`, `COMPUTERNAME`, `USERDOMAIN`, `LOGONSERVER`
    /// and the DNS host name.
    pub fn from_env(env: &dyn Fn(&str) -> Option<String>, hostname: Option<String>) -> Self {
        let mut r = Self::new();
        if let Some(p) = env("USERPROFILE") {
            r.profile(&p);
        }
        for (key, placeholder) in [("USERNAME", "<user>"), ("COMPUTERNAME", "<host>"), ("USERDOMAIN", "<domain>")] {
            if let Some(v) = env(key) {
                r.name(&v, placeholder);
            }
        }
        if let Some(v) = env("LOGONSERVER") {
            r.name(v.trim_start_matches('\\'), "<host>");
        }
        if let Some(h) = hostname {
            r.name(&h, "<host>");
            if let Some(short) = h.split('.').next() {
                r.name(short, "<host>");
            }
        }
        r
    }

    pub fn profile(&mut self, path: &str) {
        let p = path.trim_end_matches(['\\', '/']);
        if !p.is_empty() {
            self.profiles.push(p.to_string());
        }
    }

    pub fn name(&mut self, value: &str, placeholder: &'static str) {
        let v = value.trim();
        if !v.is_empty() && !self.names.iter().any(|(n, _)| n.eq_ignore_ascii_case(v)) {
            self.names.push((v.to_string(), placeholder));
        }
    }

    /// The title of a window the selftest opened: it may appear.
    pub fn own_title(&mut self, title: &str) {
        self.foreign_titles.remove(title);
        if !title.is_empty() {
            self.own_titles.insert(title.to_string());
        }
    }

    /// A title the selftest saw on a window it did not open.
    pub fn foreign_title(&mut self, title: &str) {
        if title.chars().count() >= MIN_TITLE_CHARS && !self.own_titles.contains(title) {
            self.foreign_titles.insert(title.to_string());
        }
    }

    pub fn redact(&self, text: &str) -> String {
        let mut out = self.redact_quoted_titles(text);
        // Longest first, so a title that contains another goes whole.
        let mut foreign: Vec<&String> = self.foreign_titles.iter().collect();
        foreign.sort_by_key(|t| std::cmp::Reverse(t.len()));
        for t in foreign {
            // A foreign title inside one of ours ("Quip") would garble ours;
            // what it shows is already in our own title.
            if self.own_titles.iter().any(|own| own.contains(t.as_str())) {
                continue;
            }
            out = out.replace(t.as_str(), "<title>");
        }
        for p in &self.profiles {
            // Raw, and as `{:?}` prints it (every backslash doubled).
            for form in [p.clone(), p.replace('\\', "\\\\")] {
                out = replace_ci(&out, &form, "%USERPROFILE%", true);
            }
        }
        if let Some(re) = OTHER_PROFILES.as_ref() {
            out = re.replace_all(&out, "%USERPROFILE%").into_owned();
        }
        // Longest first: `pc.lan` goes whole before `pc` is replaced inside it.
        let mut names: Vec<&(String, &'static str)> = self.names.iter().collect();
        names.sort_by_key(|(v, _)| std::cmp::Reverse(v.len()));
        for (v, placeholder) in names {
            out = replace_ci(&out, v, placeholder, true);
        }
        redact_ips(&out)
    }

    /// `title="…"` as `Win32Platform::explain_class` prints it: kept only for
    /// a window the selftest opened, since that output lists every window of
    /// a class, hidden ones included.
    fn redact_quoted_titles(&self, text: &str) -> String {
        let Some(re) = QUOTED_TITLE.as_ref() else { return text.to_string() };
        re.replace_all(text, |c: &regex::Captures<'_>| {
            let quoted = c.get(1).map(|m| m.as_str()).unwrap_or("");
            let title = unescape_debug(quoted);
            if self.own_titles.contains(&title) {
                c.get(0).map(|m| m.as_str().to_string()).unwrap_or_default()
            } else {
                "title=<title>".to_string()
            }
        })
        .into_owned()
    }
}

static QUOTED_TITLE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r#"title="((?:[^"\\]|\\.)*)""#).ok());

/// Any `X:\Users\<name>` (raw or with doubled backslashes), not only the
/// current user's.
static OTHER_PROFILES: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r#"(?i)\b[a-z]:\\{1,2}users\\{1,2}[^\\/\s"']+"#).ok());

static IPV4: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b").ok());

static IPV6: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"(?i)[0-9a-f]{0,4}(?::[0-9a-f]{0,4}){2,7}").ok());

/// `{:?}` of a string, back to the string (only the escapes it produces for
/// a title matter: `\\` and `\"`; anything else stays as written).
fn unescape_debug(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\\') => out.push('\\'),
                Some('"') => out.push('"'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn is_word(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_alphanumeric() || c == '_')
}

/// Case-insensitive literal replace; with `bounded`, only where the match is
/// not part of a longer word (a user named "eb" leaves "web" alone, and the
/// profile `C:\Users\bob` leaves `C:\Users\bobby` to the generic rule).
fn replace_ci(text: &str, needle: &str, with: &str, bounded: bool) -> String {
    if needle.is_empty() {
        return text.to_string();
    }
    let Ok(re) = Regex::new(&format!("(?i){}", regex::escape(needle))) else { return text.to_string() };
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for m in re.find_iter(text) {
        let before = text[..m.start()].chars().next_back();
        let after = text[m.end()..].chars().next();
        if bounded && (is_word(before) || is_word(after)) {
            continue;
        }
        out.push_str(&text[last..m.start()]);
        out.push_str(with);
        last = m.end();
    }
    out.push_str(&text[last..]);
    out
}

/// Every IPv4 (an octet over 255 makes it a version string, kept) and IPv6
/// address becomes `<ip>`. IPv6 needs a `::` or all eight groups, so a time
/// (`12:34:56`) and a Rust path (`classify::exe_stem`) stay.
fn redact_ips(text: &str) -> String {
    let mut out = match IPV4.as_ref() {
        Some(re) => re
            .replace_all(text, |c: &regex::Captures<'_>| {
                let valid =
                    (1..=4).all(|i| c.get(i).and_then(|m| m.as_str().parse::<u32>().ok()).is_some_and(|n| n <= 255));
                if valid {
                    "<ip>".to_string()
                } else {
                    c.get(0).map(|m| m.as_str().to_string()).unwrap_or_default()
                }
            })
            .into_owned(),
        None => text.to_string(),
    };
    if let Some(re) = IPV6.as_ref() {
        let src = out.clone();
        out = String::with_capacity(src.len());
        let mut last = 0;
        for m in re.find_iter(&src) {
            let s = m.as_str();
            let before = src[..m.start()].chars().next_back();
            let after = src[m.end()..].chars().next();
            let shaped = s.contains("::") || s.matches(':').count() == 7;
            let has_hex = s.chars().any(|c| c.is_ascii_hexdigit());
            if !shaped || !has_hex || is_word(before) || is_word(after) || before == Some('.') {
                continue;
            }
            out.push_str(&src[last..m.start()]);
            out.push_str("<ip>");
            last = m.end();
        }
        out.push_str(&src[last..]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn case(name: &str, outcome: Outcome) -> CaseResult {
        CaseResult { name: name.into(), outcome, notes: vec![] }
    }

    #[test]
    fn notes_go_under_their_case_and_are_redacted() {
        let mut pass = case("focus_own_console", Outcome::Pass);
        pass.notes = vec!["step=set_foreground".into(), "".into()];
        let mut fail = case("elevated_target_types_nothing", Outcome::Fail("probe failed".into()));
        fail.notes = vec!["raw_inserted=0\nfrom C:\\Users\\bob\\x".into()];
        let mut r = Redactor::new();
        r.profile(r"C:\Users\bob");
        let text = format_report(&header(), &[pass, fail], &r);
        assert!(text.contains("PASS focus_own_console\n    note: step=set_foreground\n"), "{text}");
        assert!(
            text.contains(
                "FAIL elevated_target_types_nothing: probe failed\n    note: raw_inserted=0\n    note: from "
            ),
            "{text}"
        );
        assert!(!text.contains("bob"), "{text}");
        assert!(!text.contains("note: \n"), "empty notes are dropped: {text}");
    }

    fn header() -> Header {
        Header {
            unix_seconds: 1_800_000_000.0,
            quip_version: "0.1.0".into(),
            git_sha: Some("a52c5e2abcde".into()),
            windows_version: Some("10.0.26100".into()),
            displays: vec![
                DisplayInfo {
                    name: "Generic PnP Monitor".into(),
                    is_primary: true,
                    bounds: PixelRect::new(0, 0, 1920, 1080),
                    work_area: PixelRect::new(0, 0, 1920, 1040),
                    dpi: Some(144),
                },
                DisplayInfo {
                    name: "DISPLAY2".into(),
                    is_primary: false,
                    bounds: PixelRect::new(1920, 0, 2560, 1440),
                    work_area: PixelRect::new(1920, 0, 2560, 1400),
                    dpi: None,
                },
            ],
        }
    }

    #[test]
    fn exit_code_is_zero_only_when_every_case_passed() {
        assert_eq!(exit_code(&[case("a", Outcome::Pass), case("b", Outcome::Pass)]), EXIT_ALL_PASSED);
        assert_eq!(exit_code(&[case("a", Outcome::Pass), case("b", Outcome::Skip("no wt".into()))]), EXIT_SKIPPED);
        assert_eq!(
            exit_code(&[case("a", Outcome::Skip("x".into())), case("b", Outcome::Fail("y".into()))]),
            EXIT_FAILED,
            "a failure wins over a skip"
        );
        assert_eq!(exit_code(&[]), EXIT_FAILED, "no case ran: nothing was proven");
    }

    #[test]
    fn the_report_has_the_header_one_line_per_case_and_ends_with_the_summary() {
        let results = vec![
            case("process_snapshot", Outcome::Pass),
            case("classic_cmd_console", Outcome::Fail("no new console in 15 s\nverdict=untitled\n\n".into())),
            case("windows_terminal", Outcome::Skip("wt.exe is not installed".into())),
        ];
        let text = format_report(&header(), &results, &Redactor::new());
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines[0], "Quip selftest");
        assert!(lines.contains(&"time: 2027-01-15T08:00:00Z"), "{text}");
        assert!(lines.contains(&"quip: 0.1.0 (git a52c5e2abcde)"), "{text}");
        assert!(lines.contains(&"windows: 10.0.26100"), "{text}");
        assert!(lines.contains(&"displays: 2"), "{text}");
        assert!(
            lines.contains(
                &"display 1: Generic PnP Monitor primary 1920x1080 at 0,0 work 1920x1040 at 0,0 dpi 144 (150%)"
            ),
            "{text}"
        );
        assert!(
            lines.contains(&"display 2: DISPLAY2 2560x1440 at 1920,0 work 2560x1400 at 1920,0 dpi unknown"),
            "{text}"
        );
        assert!(lines.contains(&"PASS process_snapshot"));
        assert!(lines.contains(&"FAIL classic_cmd_console: no new console in 15 s"));
        assert!(lines.contains(&"    verdict=untitled"), "further detail lines are indented: {text}");
        assert!(lines.contains(&"SKIP windows_terminal: wt.exe is not installed"), "a skip is shown as SKIP");
        assert_eq!(
            lines.iter().filter(|l| l.starts_with("PASS ") || l.starts_with("FAIL ") || l.starts_with("SKIP ")).count(),
            3
        );
        assert_eq!(*lines.last().unwrap_or(&""), "SUMMARY FAIL: 1 passed, 1 failed, 1 skipped of 3 cases");
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn summary_verdicts() {
        assert_eq!(summary_line(&[case("a", Outcome::Pass)]), "SUMMARY PASS: 1 passed, 0 failed, 0 skipped of 1 cases");
        assert_eq!(
            summary_line(&[case("a", Outcome::Pass), case("b", Outcome::Skip("x".into()))]),
            "SUMMARY INCOMPLETE: 1 passed, 0 failed, 1 skipped of 2 cases"
        );
    }

    #[test]
    fn no_git_sha_or_windows_version_still_reads() {
        let h = Header { git_sha: None, windows_version: None, displays: vec![], ..header() };
        let text = format_report(&h, &[case("a", Outcome::Pass)], &Redactor::new());
        assert!(text.contains("quip: 0.1.0\n"), "{text}");
        assert!(text.contains("windows: unknown\n"), "{text}");
        assert!(text.contains("displays: 0\n"), "{text}");
    }

    #[test]
    fn file_names_hold_no_colon() {
        assert_eq!(file_name(1_800_000_000.0, 0), "selftest-20270115T080000Z.txt");
        assert_eq!(file_name(1_800_000_000.0, 2), "selftest-20270115T080000Z-2.txt");
        assert!(!file_name(1_800_000_000.0, 0).contains(':'));
    }

    #[test]
    fn scale_from_dpi() {
        assert_eq!(scale_percent(96), 100);
        assert_eq!(scale_percent(120), 125);
        assert_eq!(scale_percent(144), 150);
        assert_eq!(scale_percent(192), 200);
    }

    fn env_redactor() -> Redactor {
        let env = |k: &str| {
            match k {
                "USERPROFILE" => Some(r"C:\Users\bobsmith"),
                "USERNAME" => Some("bobsmith"),
                "COMPUTERNAME" => Some("DESKTOP-7QX2B"),
                "USERDOMAIN" => Some("ACMECORP"),
                "LOGONSERVER" => Some(r"\\ACME-DC01"),
                _ => None,
            }
            .map(str::to_string)
        };
        Redactor::from_env(&env, Some("desktop-7qx2b.lan".into()))
    }

    #[test]
    fn user_machine_and_profile_never_reach_the_report() {
        let r = env_redactor();
        let text = r.redact(
            "exe=C:\\Users\\bobsmith\\AppData\\Local\\x.exe\n\
             debug exe=\"c:\\\\users\\\\BOBSMITH\\\\bin\\\\y.exe\"\n\
             other C:\\Users\\alice\\z.exe\n\
             user BobSmith on DESKTOP-7qx2b (desktop-7qx2b.lan) in ACMECORP via ACME-DC01\n",
        );
        for leak in ["bobsmith", "BOBSMITH", "BobSmith", "alice", "7qx2b", "7QX2B", "ACMECORP", "ACME-DC01"] {
            assert!(!text.contains(leak), "{leak} leaked: {text}");
        }
        assert!(text.contains(r"exe=%USERPROFILE%\AppData\Local\x.exe"), "{text}");
        assert!(text.contains(r#"debug exe="%USERPROFILE%\\bin\\y.exe""#), "{text}");
        assert!(text.contains(r"other %USERPROFILE%\z.exe"), "{text}");
        assert!(text.contains("user <user> on <host> (<host>) in <domain> via <host>"), "{text}");
    }

    #[test]
    fn a_short_user_name_is_replaced_only_as_a_word() {
        let mut r = Redactor::new();
        r.name("eb", "<user>");
        assert_eq!(r.redact("eb opened the web page as EB."), "<user> opened the web page as <user>.");
    }

    #[test]
    fn titles_of_windows_it_did_not_open_are_dropped_and_its_own_kept() {
        let mut r = Redactor::new();
        r.foreign_title("Quip-selftest-cmd"); // seen before it was known as ours
        r.own_title("Quip-selftest-cmd");
        r.foreign_title("Q3 salaries.xlsx - Excel");
        r.foreign_title("Quip");
        r.foreign_title("ab");
        let explain = "0x1 pid=4 exe=\"C:\\\\Windows\\\\conhost.exe\" title=\"Quip-selftest-cmd\" verdict=listed\n\
                       0x2 pid=5 exe=\"\" title=\"secret \\\"plan\\\"\" verdict=hidden\n\
                       0x3 pid=6 exe=\"\" title=\"\" verdict=untitled\n";
        let text = r.redact(&format!("{explain}saw Q3 salaries.xlsx - Excel in front; ab\n"));
        assert!(text.contains("title=\"Quip-selftest-cmd\" verdict=listed"), "own title kept: {text}");
        assert!(text.contains("pid=5 exe=\"\" title=<title> verdict=hidden"), "{text}");
        assert!(text.contains("pid=6 exe=\"\" title=<title> verdict=untitled"), "{text}");
        assert!(!text.contains("secret"), "{text}");
        assert!(!text.contains("salaries"), "{text}");
        assert!(text.contains("saw <title> in front; ab"), "{text}");
    }

    #[test]
    fn ip_addresses_are_masked_and_versions_and_times_kept() {
        let text = Redactor::new().redact(
            "ping -n 120 127.0.0.1 from 192.168.1.20 and fe80::1c2b:3d4e%12, ::1, \
             2001:0db8:85a3:0000:0000:8a2e:0370:7334\n\
             windows 10.0.26100.1234 quip 0.1.0 at 2027-01-15T08:00:00Z via classify::exe_stem\n",
        );
        for leak in ["127.0.0.1", "192.168", "fe80", "::1", "2001:0db8"] {
            assert!(!text.contains(leak), "{leak} leaked: {text}");
        }
        assert!(
            text.contains("windows 10.0.26100.1234 quip 0.1.0 at 2027-01-15T08:00:00Z via classify::exe_stem"),
            "{text}"
        );
    }

    #[test]
    fn the_formatted_report_is_redacted_as_a_whole() {
        let r = env_redactor();
        let results =
            vec![case("x", Outcome::Fail("opened C:\\Users\\bobsmith\\a on DESKTOP-7QX2B at 10.1.2.3".into()))];
        let text = format_report(&header(), &results, &r);
        assert!(text.contains("FAIL x: opened %USERPROFILE%\\a on <host> at <ip>"), "{text}");
    }
}
