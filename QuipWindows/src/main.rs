//! `Quip.exe`. Only `--fake-platform` (spec 10.6) runs a host so far; the
//! Win32 backend lists windows, and the tray app that will run on it is not
//! built yet. No `windows_subsystem = "windows"` yet:
//! until there is a tray, stderr is the only place an error can show.
#![cfg_attr(not(test), deny(clippy::unwrap_used, clippy::expect_used))]
#![deny(clippy::undocumented_unsafe_blocks)]

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = if args.iter().any(|a| a == "--fake-platform") {
        match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(rt) => rt.block_on(quip_windows::fake_mode::run(args)),
            Err(e) => {
                eprintln!("cannot start the async runtime: {e}");
                1
            }
        }
    } else {
        real_host()
    };
    std::process::exit(code);
}

/// Builds the Win32 platform. The tray app that runs the host on it is not
/// built yet, so this stops there.
#[cfg(windows)]
fn real_host() -> i32 {
    match quip_windows::platform::win32::Win32Platform::new() {
        Ok(_) => {
            eprintln!(
                "Quip: the Windows tray app is not built yet; run with --fake-platform.\n{}",
                quip_windows::fake_mode::USAGE
            );
            2
        }
        Err(e) => {
            eprintln!("Quip: {e}");
            1
        }
    }
}

#[cfg(not(windows))]
fn real_host() -> i32 {
    eprintln!("Quip for Windows: on this OS only the fake platform runs.\n{}", quip_windows::fake_mode::USAGE);
    2
}
