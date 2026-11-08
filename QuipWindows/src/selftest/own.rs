//! Which windows and processes are the selftest's own, pure so the rules are
//! Mac-tested.
//!
//! A window the selftest opens is found by a title marker it sets itself,
//! unique to the run (`Quip-selftest-<pid>-<n>-<tag>`), so a window the user
//! has open can never match. Its processes are the window's owner (on
//! Windows, a classic console window is owned by its shell, not conhost.exe)
//! and that shell's children, limited to the programs the selftest starts.

use std::collections::HashSet;

use crate::services::classify::{exe_stem, Proc};

/// Programs the selftest starts (and so may end, under a window it opened).
pub const OWN_STEMS: [&str; 4] = ["conhost", "cmd", "powershell", "ping"];

/// The title marker for the `n`th window of the selftest run in process
/// `pid`. Letters, digits and `-` only, so cmd's `title` and a PowerShell
/// single-quoted string take it as is.
pub fn marker(pid: u32, n: u32, tag: &str) -> String {
    format!("Quip-selftest-{pid}-{n}-{tag}")
}

fn joins(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// `title` carries `marker` as a whole token: alone, or with something the
/// shell adds around it (`Administrator: `), but not as part of a longer
/// marker (`…-1-cmd` never matches `…-11-cmd`).
pub fn has_marker(title: &str, marker: &str) -> bool {
    if marker.is_empty() {
        return false;
    }
    title.match_indices(marker).any(|(at, _)| {
        let before = title[..at].chars().next_back();
        let after = title[at + marker.len()..].chars().next();
        !joins(before) && !joins(after)
    })
}

fn is_own(p: &Proc) -> bool {
    OWN_STEMS.contains(&exe_stem(&p.exe).as_str())
}

/// The processes to end for a window owned by `owner`: the owner and its
/// descendants, walking only through programs in `OWN_STEMS`. Empty when the
/// owner is not in `procs` or is not one of those programs, so a window
/// owned by anything else never gets a process ended.
pub fn cleanup_targets(owner: u32, procs: &[Proc]) -> Vec<Proc> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut stack: Vec<&Proc> = procs.iter().filter(|p| p.pid == owner && owner != 0).take(1).collect();
    while let Some(p) = stack.pop() {
        if !seen.insert(p.pid) || !is_own(p) {
            continue;
        }
        out.push(p.clone());
        // `is_child_of`: a process older than `p` that names p's pid as its
        // parent was started by an exited process whose pid `p` reuses.
        stack.extend(procs.iter().filter(|c| c.is_child_of(p)));
    }
    out
}

/// Which of `targets` (taken while the window was known to be ours) are
/// still running in `now`. A pid counts only with the same parent and exe,
/// so a reused pid is never taken for one of ours.
pub fn still_running(targets: &[Proc], now: &[Proc]) -> Vec<u32> {
    targets.iter().filter(|t| now.contains(t)).map(|t| t.pid).collect()
}

/// `root` and everything under it, as (pid, exe), for failure details.
pub fn tree(root: u32, procs: &[Proc]) -> Vec<(u32, String)> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut stack: Vec<&Proc> = procs.iter().filter(|p| p.pid == root).take(1).collect();
    while let Some(p) = stack.pop() {
        if !seen.insert(p.pid) {
            continue;
        }
        out.push((p.pid, p.exe.clone()));
        stack.extend(procs.iter().filter(|c| c.is_child_of(p)));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Created in pid order, so a listed parent is older than its child.
    fn p(pid: u32, parent: u32, exe: &str) -> Proc {
        Proc { pid, parent, exe: exe.into(), created: Some(pid.into()) }
    }

    #[test]
    fn markers_are_unique_per_run_and_window() {
        assert_eq!(marker(4242, 3, "cmd"), "Quip-selftest-4242-3-cmd");
        assert_ne!(marker(4242, 3, "cmd"), marker(4243, 3, "cmd"));
        assert_ne!(marker(4242, 3, "cmd"), marker(4242, 4, "cmd"));
        assert!(marker(1, 2, "ps").chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
    }

    #[test]
    fn a_marker_matches_only_as_a_whole_token() {
        let m = marker(42, 1, "cmd");
        assert!(has_marker(&m, &m));
        assert!(has_marker(&format!("Administrator: {m}"), &m));
        assert!(has_marker(&format!("{m} - ping"), &m));
        assert!(!has_marker(&marker(42, 11, "cmd"), &m));
        assert!(!has_marker(&marker(421, 1, "cmd"), &m));
        assert!(!has_marker(&format!("{m}x"), &m));
        assert!(!has_marker("Quip-selftest-cmd", &m));
        assert!(!has_marker("Command Prompt", &m));
        assert!(!has_marker("", &m));
        assert!(!has_marker("anything", ""));
    }

    #[test]
    fn cleanup_ends_the_shell_and_its_own_children_only() {
        let procs = [
            p(10, 1, r"C:\Windows\System32\conhost.exe"),
            p(20, 10, r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"),
            p(30, 20, r"C:\Windows\System32\PING.EXE"),
            p(31, 20, r"C:\Windows\System32\conhost.exe"),
            p(40, 20, r"C:\Python\python.exe"),
            p(41, 40, r"C:\Windows\System32\cmd.exe"),
            p(50, 1, r"C:\Windows\System32\cmd.exe"),
        ];
        let mut got: Vec<u32> = cleanup_targets(20, &procs).into_iter().map(|p| p.pid).collect();
        got.sort();
        // Not its parent conhost (10), not a user's program (40) or what runs
        // under it (41), not an unrelated cmd (50).
        assert_eq!(got, [20, 30, 31]);
    }

    #[test]
    fn a_window_owned_by_anything_else_ends_nothing() {
        let procs = [p(20, 1, r"C:\Program Files\App\app.exe"), p(30, 20, r"C:\Windows\System32\cmd.exe")];
        assert!(cleanup_targets(20, &procs).is_empty());
        assert!(cleanup_targets(99, &procs).is_empty());
        assert!(cleanup_targets(0, &[p(0, 0, "cmd.exe")]).is_empty());
    }

    #[test]
    fn a_reused_pid_is_not_still_running() {
        let targets = [p(20, 10, r"C:\Windows\System32\cmd.exe"), p(30, 20, r"C:\Windows\System32\PING.EXE")];
        let now = [p(20, 77, r"C:\Windows\System32\cmd.exe"), p(30, 20, r"C:\Windows\System32\PING.EXE")];
        assert_eq!(still_running(&targets, &now), [30]);
        assert!(still_running(&targets, &[]).is_empty());
    }

    #[test]
    fn cleanup_skips_an_older_process_under_a_reused_pid() {
        // cmd 20 got the pid of an exited process that started 5 and 6.
        let mut old_cmd = p(5, 20, r"C:\Windows\System32\cmd.exe");
        old_cmd.created = Some(1);
        let mut old_ping = p(6, 20, r"C:\Windows\System32\PING.EXE");
        old_ping.created = None;
        let procs = [p(20, 1, r"C:\Windows\System32\cmd.exe"), old_cmd, old_ping, p(30, 20, "ping.exe")];
        let got: Vec<u32> = cleanup_targets(20, &procs).into_iter().map(|p| p.pid).collect();
        assert_eq!(got, [20, 30]);
        let got: Vec<u32> = tree(20, &procs).into_iter().map(|(p, _)| p).collect();
        assert_eq!(got, [20, 30]);
    }

    #[test]
    fn tree_lists_root_and_descendants() {
        let procs = [p(1, 0, "a.exe"), p(2, 1, "b.exe"), p(3, 2, "c.exe"), p(4, 0, "d.exe")];
        let mut got: Vec<u32> = tree(1, &procs).into_iter().map(|(p, _)| p).collect();
        got.sort();
        assert_eq!(got, [1, 2, 3]);
    }
}
