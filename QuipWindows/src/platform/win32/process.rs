//! Processes behind the windows: the toolhelp snapshot `classify` walks, the
//! exe path, and the display name from the exe's version resource.

use std::ffi::c_void;

use windows::core::{w, PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE};
use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Threading::{
    GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, TerminateProcess, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
};

use super::window::from_wide;
use crate::platform::traits::{PlatformError, PlatformResult};
use crate::services::classify::Proc;

/// Closes the handle when dropped.
struct Owned(HANDLE);

impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: the handle came from a successful open call and is closed
        // exactly once, here.
        let _ = unsafe { CloseHandle(self.0) };
    }
}

/// Every process now: pid, parent pid, exe file name.
pub fn snapshot() -> PlatformResult<Vec<Proc>> {
    // SAFETY: plain flags; the handle is closed by `Owned`.
    let snap = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }
        .map_err(|e| PlatformError::Failed(format!("CreateToolhelp32Snapshot: {e}")))?;
    let snap = Owned(snap);
    let mut entry = PROCESSENTRY32W { dwSize: size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
    let mut out = Vec::new();
    // SAFETY: `entry` is a writable PROCESSENTRY32W with `dwSize` set, and
    // `snap` is a live process snapshot.
    let mut more = unsafe { Process32FirstW(snap.0, &mut entry) }.is_ok();
    while more {
        out.push(Proc {
            pid: entry.th32ProcessID,
            parent: entry.th32ParentProcessID,
            exe: from_wide(&entry.szExeFile),
            created: created(entry.th32ProcessID),
        });
        // SAFETY: as above.
        more = unsafe { Process32NextW(snap.0, &mut entry) }.is_ok();
    }
    Ok(out)
}

/// When `pid` started (`GetProcessTimes`, 100 ns ticks since 1601), `None`
/// when it cannot be opened. With it `Proc::is_child_of` can tell a real
/// child from a process whose parent pid was reused.
pub fn created(pid: u32) -> Option<u64> {
    if pid == 0 {
        return None;
    }
    // SAFETY: plain arguments; the handle is closed by `Owned`.
    let process = Owned(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?);
    created_of(&process)
}

/// The creation time of an open process handle (with query access).
fn created_of(process: &Owned) -> Option<u64> {
    let (mut c, mut e, mut k, mut u) =
        (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
    // SAFETY: four writable FILETIMEs and a live process handle.
    unsafe { GetProcessTimes(process.0, &mut c, &mut e, &mut k, &mut u) }.ok()?;
    Some((u64::from(c.dwHighDateTime) << 32) | u64::from(c.dwLowDateTime))
}

/// Ends `pid` only if the process the handle opens is the one listed with
/// creation time `created` (`classify::same_process`): between a snapshot and
/// `OpenProcess` the pid can be reused by someone else's process. `true`
/// when `TerminateProcess` was called and succeeded. The handle is closed
/// on every path (`Owned`).
pub fn terminate_if_same(pid: u32, created: Option<u64>) -> bool {
    if pid == 0 {
        return false;
    }
    // SAFETY: plain arguments; the handle is closed by `Owned`.
    let Ok(h) = (unsafe { OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }) else {
        return false;
    };
    let process = Owned(h);
    if !crate::services::classify::same_process(created, created_of(&process)) {
        return false;
    }
    // SAFETY: a live process handle opened with PROCESS_TERMINATE.
    unsafe { TerminateProcess(process.0, 1) }.is_ok()
}

/// Full exe path, `None` when the process cannot be opened (elevated,
/// protected, or gone).
pub fn exe_path(pid: u32) -> Option<String> {
    // SAFETY: plain arguments; the handle is closed by `Owned`.
    let process = Owned(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?);
    let mut buf = vec![0u16; 1024];
    let mut len = buf.len() as u32;
    // SAFETY: `buf` is writable for `len` UTF-16 units; on success `len` is
    // set to the units written, without the NUL.
    unsafe { QueryFullProcessImageNameW(process.0, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len) }.ok()?;
    Some(String::from_utf16_lossy(&buf[..(len as usize).min(buf.len())]))
}

fn wide_z(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The name Task Manager shows for an exe: `FileDescription`, else
/// `ProductName`, from its version resource. `FileDescription` first because
/// `ProductName` is the suite, not the app, for much of what users run:
/// "Microsoft® Windows® Operating System" for Notepad and Explorer,
/// "Microsoft Office" for Word.
pub fn display_name(exe_path: &str) -> Option<String> {
    let path = wide_z(exe_path);
    // SAFETY: `path` is NUL-terminated and outlives the call.
    let size = unsafe { GetFileVersionInfoSizeW(PCWSTR(path.as_ptr()), None) };
    if size == 0 {
        return None;
    }
    // u32 storage keeps every value VerQueryValueW points at aligned.
    let mut data = vec![0u32; (size as usize).div_ceil(4)];
    // SAFETY: `data` holds at least `size` writable bytes.
    unsafe { GetFileVersionInfoW(PCWSTR(path.as_ptr()), 0, size, data.as_mut_ptr() as *mut c_void) }.ok()?;
    let block = data.as_ptr() as *const c_void;

    let mut langs: Vec<String> = Vec::new();
    let mut ptr: *mut c_void = std::ptr::null_mut();
    let mut len = 0u32;
    // SAFETY: `block` is the version block just read; `ptr` / `len` are
    // writable out values.
    if unsafe { VerQueryValueW(block, w!("\\VarFileInfo\\Translation"), &mut ptr, &mut len) }.as_bool()
        && !ptr.is_null()
    {
        let unit_count = len as usize / 2;
        // SAFETY: on success `ptr` points inside `data` at `len` bytes of
        // (language, code page) u16 pairs, 2-byte aligned.
        let units = unsafe { std::slice::from_raw_parts(ptr as *const u16, unit_count) };
        for [lang, code_page] in units.as_chunks::<2>().0 {
            langs.push(format!("{lang:04x}{code_page:04x}"));
        }
    }
    // US English, Unicode and Western code pages: what most exes ship.
    langs.extend(["040904b0".to_string(), "040904e4".to_string()]);

    for key in ["FileDescription", "ProductName"] {
        for lang in &langs {
            let sub = wide_z(&format!("\\StringFileInfo\\{lang}\\{key}"));
            let mut ptr: *mut c_void = std::ptr::null_mut();
            let mut chars = 0u32;
            // SAFETY: as above; `sub` is NUL-terminated and outlives the call.
            let found = unsafe { VerQueryValueW(block, PCWSTR(sub.as_ptr()), &mut ptr, &mut chars) }.as_bool();
            if !found || ptr.is_null() || chars == 0 {
                continue;
            }
            // SAFETY: on success `ptr` points inside `data` at `chars` UTF-16
            // units (NUL included), 2-byte aligned.
            let units = unsafe { std::slice::from_raw_parts(ptr as *const u16, chars as usize) };
            let name = from_wide(units).trim().to_string();
            if !name.is_empty() {
                return Some(name);
            }
        }
    }
    None
}
