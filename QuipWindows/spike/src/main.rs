//! Q-91 M0 spike: a throwaway probe, not product code.
//!
//! Answers the three unknowns the Windows host design rests on
//! (docs/superpowers/specs/2026-11-06-q91-quip-windows-host.md, sections 5.3,
//! 5.4 and 13) on a real Windows desktop:
//!
//! 1. Can a background process bring a chosen window to the foreground, and
//!    which step of the workaround does it take?
//! 2. Does `SendInput` with `KEYEVENTF_UNICODE` type into PowerShell (Windows
//!    Terminal and the classic console) and cmd, including non-ASCII text?
//! 3. Which way of entering multi-line text leaves it on the command line
//!    WITHOUT running it: Shift+Enter between lines, or a clipboard paste?
//!
//! It opens its own shell windows, types only into them, writes marker files
//! under a fresh temp folder, and closes what it opened. The report goes to
//! stdout and to `%LOCALAPPDATA%\Quip\spike-report-<unix time>.txt`.
//!
//! Exit code: 0 when every mechanics check passed (findings such as "unsafe"
//! are results, not failures), 1 when a mechanics check failed, 2 when not on
//! Windows.

#[cfg(windows)]
mod win;

#[cfg(windows)]
fn main() {
    std::process::exit(win::run());
}

#[cfg(not(windows))]
fn main() {
    eprintln!("quip-spike runs on Windows only");
    std::process::exit(2);
}
