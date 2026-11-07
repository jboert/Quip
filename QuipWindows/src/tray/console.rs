//! `Quip.exe` is a GUI program (`windows_subsystem = "windows"`), so Windows
//! gives it no console. The commands that print (`--selftest`, `--help`,
//! `--fake-platform`) call `attach_parent_console` first: output that is
//! already redirected (a pipe, a file, as in CI) stays where it is, and the
//! rest goes to the console of whatever started Quip, if it has one.
//!
//! A shell does not wait for a GUI program, so from an interactive prompt
//! run `start /wait Quip.exe --selftest` (cmd) or
//! `Quip.exe --selftest | Out-Host` (PowerShell) to see the output before
//! the next prompt. The report file is written either way.

use windows::core::w;
use windows::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE, HANDLE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAGS_AND_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
};
use windows::Win32::System::Console::{
    AttachConsole, GetStdHandle, SetStdHandle, ATTACH_PARENT_PROCESS, STD_ERROR_HANDLE, STD_HANDLE, STD_INPUT_HANDLE,
    STD_OUTPUT_HANDLE,
};

fn current(which: STD_HANDLE) -> Option<HANDLE> {
    // SAFETY: plain value argument.
    match unsafe { GetStdHandle(which) } {
        Ok(h) if !h.is_invalid() && !h.0.is_null() => Some(h),
        _ => None,
    }
}

/// Points stdin, stdout and stderr that have no handle at the parent's
/// console. Does nothing when all three are set or the parent has no
/// console (Explorer, the Run key): the program then runs silent, as before.
pub fn attach_parent_console() {
    let streams = [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE];
    let before: Vec<Option<HANDLE>> = streams.iter().map(|&s| current(s)).collect();
    if before.iter().all(Option::is_some) {
        return;
    }
    // SAFETY: plain value argument; fails harmlessly without a parent console.
    if unsafe { AttachConsole(ATTACH_PARENT_PROCESS) }.is_err() {
        return;
    }
    for (&stream, kept) in streams.iter().zip(before) {
        // Attaching may or may not replace the standard handles (it has
        // differed between Windows versions); set every one explicitly.
        let handle = kept.or_else(|| {
            let name = if stream == STD_INPUT_HANDLE { w!("CONIN$") } else { w!("CONOUT$") };
            // SAFETY: a constant device name; the handle is kept for the
            // life of the process as a standard handle.
            unsafe {
                CreateFileW(
                    name,
                    (GENERIC_READ | GENERIC_WRITE).0,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    None,
                    OPEN_EXISTING,
                    FILE_FLAGS_AND_ATTRIBUTES(0),
                    None,
                )
            }
            .ok()
        });
        if let Some(h) = handle {
            // SAFETY: `h` is a valid handle owned by this process.
            let _ = unsafe { SetStdHandle(stream, h) };
        }
    }
}
