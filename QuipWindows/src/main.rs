//! `Quip.exe`. With no arguments on Windows it is the tray app (spec 6):
//! one instance per session, the host on the Win32 platform, the tray menu.
//! `--selftest` (spec 10.5) runs the Win32 cases and writes a report;
//! `--fake-platform` (spec 10.6) runs the host on the scripted fake.
//!
//! A GUI program (`windows_subsystem = "windows"`): no console window opens.
//! The commands that print attach to the console of whatever started them
//! (`tray::console`); the tray app reports errors in a message box.
#![cfg_attr(all(windows, not(test)), windows_subsystem = "windows")]
#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]
#![deny(clippy::undocumented_unsafe_blocks)]

const USAGE: &str = "usage: Quip              the tray app (Windows)
       Quip --selftest   check this PC, write a report to %LOCALAPPDATA%\\Quip\\Logs
       Quip --fake-platform [--port N] [--pin PIN] [--fixture PATH] [--log-dir DIR]
       Quip --version    print the version and commit of this build
       Quip --help
       Quip --input-probe <marker>   internal: the selftest's integrity probe
From an interactive prompt use `start /wait Quip --selftest` (cmd) or
`Quip --selftest | Out-Host` (PowerShell) to see the output before the next prompt.";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let has = |flag: &str| args.iter().any(|a| a == flag);
    let code = if args.is_empty() {
        real_host()
    } else {
        attach_console();
        if has("--help") || has("-h") {
            println!("{USAGE}");
            0
        } else if has("--version") {
            println!("{}", quip_windows::build_info::product_line());
            0
        } else if args.first().map(String::as_str) == Some("--input-probe") {
            input_probe(args.get(1).map(String::as_str).unwrap_or(""))
        } else if has("--selftest") {
            selftest()
        } else if has("--fake-platform") {
            match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
                Ok(rt) => rt.block_on(quip_windows::fake_mode::run(args)),
                Err(e) => {
                    eprintln!("cannot start the async runtime: {e}");
                    1
                }
            }
        } else {
            eprintln!("unknown arguments: {}\n{USAGE}", args.join(" "));
            2
        }
    };
    std::process::exit(code);
}

#[cfg(windows)]
fn attach_console() {
    quip_windows::tray::console::attach_parent_console();
}

#[cfg(not(windows))]
fn attach_console() {}

#[cfg(windows)]
fn real_host() -> i32 {
    quip_windows::app::run()
}

#[cfg(not(windows))]
fn real_host() -> i32 {
    eprintln!("Quip for Windows: on this OS only the fake platform runs.\n{}", quip_windows::fake_mode::USAGE);
    2
}

#[cfg(windows)]
fn selftest() -> i32 {
    quip_windows::selftest::win32::run()
}

#[cfg(windows)]
fn input_probe(marker: &str) -> i32 {
    quip_windows::selftest::probe::run(marker)
}

#[cfg(not(windows))]
fn input_probe(_marker: &str) -> i32 {
    eprintln!("Quip for Windows: --input-probe runs only on Windows.");
    2
}

#[cfg(not(windows))]
fn selftest() -> i32 {
    eprintln!("Quip for Windows: --selftest runs only on Windows.");
    2
}
