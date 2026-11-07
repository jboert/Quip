//! Terminal detection (spec 5.1), pure. The Win32 side gathers the facts
//! (class name, exe name, product name, the shells attached to the window's
//! consoles); this decides what they mean, so every case is testable on the Mac.
//!
//! | Window | Terminal? | `app` | shell |
//! |---|---|---|---|
//! | process `WindowsTerminal.exe` or class `CASCADIA_HOSTING_WINDOW_CLASS` | yes | `Windows Terminal` | from its tabs |
//! | class `ConsoleWindowClass` | yes | `PowerShell` / `PowerShell 7` / `Command Prompt` / `Console` | from the console |
//! | anything else | no | product name, else exe stem, else class name | — |
//!
//! Shell (spec 5.4 step 5, M0): `shells` holds the foreground program of each
//! console attached to the window (one per Windows Terminal tab), as
//! `foreground_program` finds it. All the same shell -> that shell; none, a
//! mix, or anything that is not a shell -> `unknown`, which is treated like
//! `cmd` (multi-line refused): with mixed tabs we cannot know which one has
//! focus, and a shell running `python`, `ssh` or `node` passes our Shift+Enter
//! to that program, which may run each line.
//!
//! `foreground_program` (spec 5.1): Windows has no "foreground process of a
//! console" call, so the Win32 side takes a process snapshot
//! (`CreateToolhelp32Snapshot`) and this walks it from the console's shell
//! down through its CHILD processes. A child that is a shell (pwsh started
//! from cmd) becomes the new shell; any other child (console hosts aside)
//! means a program is running in the shell.

use super::multiline_policy::Shell;

pub const WT_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";
pub const CONSOLE_CLASS: &str = "ConsoleWindowClass";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TerminalHost {
    WindowsTerminal,
    Console,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Classification {
    pub terminal: Option<TerminalHost>,
    pub shell: Option<Shell>,
    pub app: String,
}

/// The file name without directory, lower-cased, without `.exe`.
pub fn exe_stem(path: &str) -> String {
    let name = path.rsplit(['\\', '/']).next().unwrap_or(path);
    let lower = name.to_ascii_lowercase();
    lower.strip_suffix(".exe").map(str::to_string).unwrap_or(lower)
}

/// One process name -> shell.
pub fn shell_of_exe(exe: &str) -> Option<Shell> {
    match exe_stem(exe).as_str() {
        "powershell" => Some(Shell::PowerShell),
        "pwsh" => Some(Shell::Pwsh),
        "cmd" => Some(Shell::Cmd),
        _ => None,
    }
}

/// See the module table.
pub fn resolve_shell(shells: &[String]) -> Shell {
    let mut found: Option<Shell> = None;
    for s in shells {
        let Some(sh) = shell_of_exe(s) else { return Shell::Unknown };
        match found {
            None => found = Some(sh),
            Some(prev) if prev != sh => return Shell::Unknown,
            Some(_) => {}
        }
    }
    found.unwrap_or(Shell::Unknown)
}

/// One row of the process snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub parent: u32,
    pub exe: String,
}

/// Console plumbing that is a child of the shell but not a program the user
/// runs in it.
fn is_console_host(exe: &str) -> bool {
    matches!(exe_stem(exe).as_str(), "conhost" | "openconsole")
}

/// The program that gets the keys in the console whose shell is `shell_pid`:
/// the deepest shell in its child chain, or the first non-shell program found
/// below a shell. Never loops on a pid cycle (Windows reuses pids, so a
/// snapshot can contain one). An unknown `shell_pid` gives `""`, which
/// `resolve_shell` reads as unknown.
pub fn foreground_program(shell_pid: u32, procs: &[Proc]) -> String {
    let Some(root) = procs.iter().find(|p| p.pid == shell_pid) else { return String::new() };
    let mut current = root;
    let mut seen = std::collections::HashSet::from([root.pid]);
    loop {
        let children: Vec<&Proc> = procs
            .iter()
            .filter(|p| p.parent == current.pid && p.pid != current.pid && !is_console_host(&p.exe))
            .collect();
        if let Some(program) = children.iter().find(|c| shell_of_exe(&c.exe).is_none()) {
            return program.exe.clone();
        }
        match children.into_iter().find(|c| !seen.contains(&c.pid)) {
            Some(shell) => {
                seen.insert(shell.pid);
                current = shell;
            }
            None => return current.exe.clone(),
        }
    }
}

pub fn console_app_name(shell: Shell) -> &'static str {
    match shell {
        Shell::PowerShell => "PowerShell",
        Shell::Pwsh => "PowerShell 7",
        Shell::Cmd => "Command Prompt",
        Shell::Unknown => "Console",
    }
}

/// `exe_path` / `product_name` are `None` when the process could not be
/// opened (elevated or protected): the window is kept, named from its class.
pub fn classify(
    class_name: &str,
    exe_path: Option<&str>,
    product_name: Option<&str>,
    shells: &[String],
) -> Classification {
    let is_wt = class_name == WT_CLASS || exe_path.map(exe_stem).as_deref() == Some("windowsterminal");
    if is_wt {
        return Classification {
            terminal: Some(TerminalHost::WindowsTerminal),
            shell: Some(resolve_shell(shells)),
            app: "Windows Terminal".into(),
        };
    }
    if class_name == CONSOLE_CLASS {
        let shell = resolve_shell(shells);
        return Classification {
            terminal: Some(TerminalHost::Console),
            shell: Some(shell),
            app: console_app_name(shell).into(),
        };
    }
    let app = product_name
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(str::to_string)
        .or_else(|| {
            exe_path.map(|p| {
                let name = p.rsplit(['\\', '/']).next().unwrap_or(p);
                let n = name.len();
                if n > 4 && name[n - 4..].eq_ignore_ascii_case(".exe") {
                    name[..n - 4].to_string()
                } else {
                    name.to_string()
                }
            })
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| class_name.to_string());
    Classification { terminal: None, shell: None, app }
}

#[cfg(test)]
mod tests {
    //! Shape of `QuipMac/Tests/CLIKindClassifierTests.swift` (facts in, kind
    //! out), with the spec 10.3 Windows cases.
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn windows_terminal_by_process_or_class() {
        let c = classify(
            WT_CLASS,
            Some(r"C:\Program Files\WindowsApps\WindowsTerminal.exe"),
            Some("Windows Terminal"),
            &s(&["pwsh.exe"]),
        );
        assert_eq!(
            c,
            Classification {
                terminal: Some(TerminalHost::WindowsTerminal),
                shell: Some(Shell::Pwsh),
                app: "Windows Terminal".into()
            }
        );
        let c = classify("SomethingElse", Some(r"C:\x\WINDOWSTERMINAL.EXE"), None, &[]);
        assert_eq!(c.terminal, Some(TerminalHost::WindowsTerminal));
        assert_eq!(c.shell, Some(Shell::Unknown));
    }

    #[test]
    fn conhost_with_each_shell() {
        for (exe, shell, app) in [
            ("powershell.exe", Shell::PowerShell, "PowerShell"),
            ("PWSH.EXE", Shell::Pwsh, "PowerShell 7"),
            (r"C:\Windows\System32\cmd.exe", Shell::Cmd, "Command Prompt"),
        ] {
            let c = classify(CONSOLE_CLASS, Some(r"C:\Windows\System32\conhost.exe"), None, &s(&[exe]));
            assert_eq!(
                c,
                Classification { terminal: Some(TerminalHost::Console), shell: Some(shell), app: app.into() },
                "{exe}"
            );
        }
    }

    #[test]
    fn unknown_console_is_still_a_terminal() {
        let c = classify(CONSOLE_CLASS, None, None, &s(&["python.exe"]));
        assert_eq!(
            c,
            Classification {
                terminal: Some(TerminalHost::Console),
                shell: Some(Shell::Unknown),
                app: "Console".into()
            }
        );
        let c = classify(CONSOLE_CLASS, None, None, &[]);
        assert_eq!(c.shell, Some(Shell::Unknown));
    }

    #[test]
    fn elevated_window_without_process_access_is_kept() {
        let c = classify("Notepad", None, None, &[]);
        assert_eq!(c, Classification { terminal: None, shell: None, app: "Notepad".into() });
        let c = classify(WT_CLASS, None, None, &[]);
        assert_eq!(c.terminal, Some(TerminalHost::WindowsTerminal), "an elevated WT is still WT by class");
    }

    #[test]
    fn non_terminal_app_name_falls_back_product_then_exe_then_class() {
        assert_eq!(
            classify("Chrome_WidgetWin_1", Some(r"C:\p\chrome.exe"), Some("Google Chrome"), &[]).app,
            "Google Chrome"
        );
        assert_eq!(classify("Chrome_WidgetWin_1", Some(r"C:\p\Code.EXE"), Some("  "), &[]).app, "Code");
        assert_eq!(classify("Cls", Some(r"C:\p\tool"), None, &[]).app, "tool");
        assert_eq!(classify("Cls", None, None, &[]).app, "Cls");
    }

    #[test]
    fn mixed_or_foreign_tabs_resolve_unknown() {
        assert_eq!(resolve_shell(&s(&["pwsh.exe", "pwsh.exe"])), Shell::Pwsh);
        assert_eq!(resolve_shell(&s(&["pwsh.exe", "cmd.exe"])), Shell::Unknown);
        assert_eq!(resolve_shell(&s(&["pwsh.exe", "wsl.exe"])), Shell::Unknown);
        assert_eq!(resolve_shell(&[]), Shell::Unknown);
    }

    fn procs(rows: &[(u32, u32, &str)]) -> Vec<Proc> {
        rows.iter().map(|(pid, parent, exe)| Proc { pid: *pid, parent: *parent, exe: exe.to_string() }).collect()
    }

    #[test]
    fn a_shell_with_no_children_is_itself() {
        let p = procs(&[(10, 1, "pwsh.exe"), (11, 10, "conhost.exe"), (12, 1, "python.exe")]);
        assert_eq!(foreground_program(10, &p), "pwsh.exe", "conhost and a sibling do not count");
        assert_eq!(resolve_shell(&[foreground_program(10, &p)]), Shell::Pwsh);
    }

    #[test]
    fn a_program_running_in_the_shell_makes_it_unknown() {
        for exe in ["python.exe", "ssh.exe", "node.exe", "wsl.exe"] {
            let p = procs(&[(10, 1, "pwsh.exe"), (20, 10, exe)]);
            assert_eq!(foreground_program(10, &p), exe);
            assert_eq!(resolve_shell(&[foreground_program(10, &p)]), Shell::Unknown, "{exe}");
        }
    }

    #[test]
    fn a_nested_shell_wins_and_its_own_children_count() {
        let p = procs(&[(10, 1, "pwsh.exe"), (20, 10, "cmd.exe")]);
        assert_eq!(resolve_shell(&[foreground_program(10, &p)]), Shell::Cmd);
        let p = procs(&[(10, 1, "cmd.exe"), (20, 10, "powershell.exe"), (30, 20, "ssh.exe")]);
        assert_eq!(foreground_program(10, &p), "ssh.exe");
        let p = procs(&[(10, 1, "cmd.exe"), (20, 10, "OpenConsole.exe"), (21, 10, "powershell.exe")]);
        assert_eq!(foreground_program(10, &p), "powershell.exe");
    }

    #[test]
    fn a_pid_cycle_or_missing_shell_never_hangs() {
        let p = procs(&[(10, 20, "pwsh.exe"), (20, 10, "pwsh.exe")]);
        assert_eq!(foreground_program(10, &p), "pwsh.exe");
        let p = procs(&[(10, 10, "cmd.exe")]);
        assert_eq!(foreground_program(10, &p), "cmd.exe");
        assert_eq!(foreground_program(99, &p), "");
        assert_eq!(resolve_shell(&[foreground_program(99, &p)]), Shell::Unknown);
    }

    #[test]
    fn exe_stem_handles_both_separators() {
        assert_eq!(exe_stem(r"C:\a\B.exe"), "b");
        assert_eq!(exe_stem("/x/pwsh"), "pwsh");
        assert_eq!(shell_of_exe("powershell_ise.exe"), None);
    }

    #[test]
    fn short_and_bare_exe_names() {
        assert_eq!(classify("Cls", Some(r"C:\p\ab"), None, &[]).app, "ab");
        assert_eq!(classify("Cls", Some(r"C:\p\.exe"), None, &[]).app, ".exe");
        assert_eq!(classify("Cls", Some(r"C:\p\a.exe"), None, &[]).app, "a");
    }
}
