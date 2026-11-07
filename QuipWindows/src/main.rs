//! `Quip.exe`. M1 runs only `--fake-platform` (spec 10.6); the real Windows
//! host (tray, Win32 backend) is M2+. No `windows_subsystem = "windows"` yet:
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

#[cfg(windows)]
fn real_host() -> i32 {
    match quip_windows::platform::win32::Win32Platform::new() {
        Ok(_) => 0,
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
