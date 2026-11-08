//! Spec 5.4 step 2b: the integrity level (RID) of a process's token, and,
//! for the selftest's probe only, starting a process one level lower. The
//! rule (`platform::integrity::access`) is pure; this only reads tokens.

use std::ffi::c_void;
use std::fs::File;
use std::os::windows::io::{FromRawHandle, RawHandle};

use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CloseHandle, LocalFree, SetHandleInformation, HANDLE, HANDLE_FLAGS, HANDLE_FLAG_INHERIT, HLOCAL,
};
use windows::Win32::Security::Authorization::ConvertStringSidToSidW;
use windows::Win32::Security::{
    DuplicateTokenEx, GetLengthSid, GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation,
    SecurityImpersonation, SetTokenInformation, TokenIntegrityLevel, TokenPrimary, PSID, SECURITY_ATTRIBUTES,
    SID_AND_ATTRIBUTES, TOKEN_ACCESS_MASK, TOKEN_ADJUST_DEFAULT, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE,
    TOKEN_MANDATORY_LABEL, TOKEN_QUERY,
};
use windows::Win32::System::Pipes::CreatePipe;
use windows::Win32::System::Threading::{
    CreateProcessAsUserW, GetCurrentProcess, OpenProcess, OpenProcessToken, CREATE_NO_WINDOW, PROCESS_INFORMATION,
    PROCESS_QUERY_LIMITED_INFORMATION, STARTF_USESTDHANDLES, STARTUPINFOW,
};

/// `SE_GROUP_INTEGRITY` (winnt.h).
const SE_GROUP_INTEGRITY: u32 = 0x20;

/// Closes the handle when dropped.
pub struct Owned(pub HANDLE);

impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_invalid() && !self.0 .0.is_null() {
            // SAFETY: the handle came from a successful open call and is
            // closed exactly once, here.
            let _ = unsafe { CloseHandle(self.0) };
        }
    }
}

/// The RID of `process`'s token, `None` when it cannot be read.
fn rid_of_process(process: HANDLE) -> Option<u32> {
    let mut token = HANDLE::default();
    // SAFETY: a live process handle and a writable out handle.
    unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) }.ok()?;
    let token = Owned(token);
    let mut len = 0u32;
    // SAFETY: a size query: no buffer, `len` receives the size needed. It
    // "fails" with ERROR_INSUFFICIENT_BUFFER by design.
    let _ = unsafe { GetTokenInformation(token.0, TokenIntegrityLevel, None, 0, &mut len) };
    if len == 0 {
        return None;
    }
    // u64 storage keeps the TOKEN_MANDATORY_LABEL at the start aligned.
    let mut buf = vec![0u64; (len as usize).div_ceil(8)];
    // SAFETY: `buf` holds at least `len` writable bytes.
    unsafe { GetTokenInformation(token.0, TokenIntegrityLevel, Some(buf.as_mut_ptr() as *mut c_void), len, &mut len) }
        .ok()?;
    // SAFETY: on success the buffer starts with a TOKEN_MANDATORY_LABEL whose
    // SID points inside the same buffer, which outlives these reads.
    unsafe {
        let label = &*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
        let sid = label.Label.Sid;
        if sid.0.is_null() {
            return None;
        }
        let count = *GetSidSubAuthorityCount(sid);
        if count == 0 {
            return None;
        }
        Some(*GetSidSubAuthority(sid, u32::from(count) - 1))
    }
}

/// The RID of process `pid`, `None` when it cannot be opened or read
/// (elevated past what Quip may query, protected, or gone).
pub fn rid_of_pid(pid: u32) -> Option<u32> {
    if pid == 0 {
        return None;
    }
    // SAFETY: plain arguments; the handle is closed by `Owned`.
    let process = Owned(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }.ok()?);
    rid_of_process(process.0)
}

/// Quip's own RID.
pub fn own_rid() -> Option<u32> {
    // SAFETY: a pseudo handle that needs no closing.
    rid_of_process(unsafe { GetCurrentProcess() })
}

/// A process started by `spawn_at_integrity`: its handle and its stdout
/// (and stderr) as a pipe.
pub struct Lowered {
    pub process: Owned,
    pub pid: u32,
    pub output: File,
}

/// Starts `command_line` with this process's own token lowered to `rid`
/// (`DuplicateTokenEx` + `SetTokenInformation(TokenIntegrityLevel)` +
/// `CreateProcessAsUserW`), no window, stdout and stderr into a pipe. For
/// the selftest's probe: a sender BELOW the window it types at.
pub fn spawn_at_integrity(command_line: &str, rid: u32) -> Result<Lowered, String> {
    let mut own = HANDLE::default();
    let access = TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY;
    // SAFETY: the current-process pseudo handle and a writable out handle.
    unsafe { OpenProcessToken(GetCurrentProcess(), access, &mut own) }.map_err(|e| format!("OpenProcessToken: {e}"))?;
    let own = Owned(own);
    let mut lowered = HANDLE::default();
    // SAFETY: a live token handle opened with TOKEN_DUPLICATE; the new
    // handle is closed by `Owned`.
    unsafe { DuplicateTokenEx(own.0, TOKEN_ACCESS_MASK(0), None, SecurityImpersonation, TokenPrimary, &mut lowered) }
        .map_err(|e| format!("DuplicateTokenEx: {e}"))?;
    let lowered = Owned(lowered);

    let sid_text: Vec<u16> = format!("S-1-16-{rid}").encode_utf16().chain(std::iter::once(0)).collect();
    let mut sid = PSID::default();
    // SAFETY: a NUL-terminated SID string; `sid` is freed with LocalFree below.
    unsafe { ConvertStringSidToSidW(PCWSTR(sid_text.as_ptr()), &mut sid) }
        .map_err(|e| format!("ConvertStringSidToSidW: {e}"))?;
    let label = TOKEN_MANDATORY_LABEL { Label: SID_AND_ATTRIBUTES { Sid: sid, Attributes: SE_GROUP_INTEGRITY } };
    // SAFETY: `label` and the SID it points at are live for the call; the
    // length covers the label and the SID, as the call expects.
    let set = unsafe {
        SetTokenInformation(
            lowered.0,
            TokenIntegrityLevel,
            &label as *const TOKEN_MANDATORY_LABEL as *const c_void,
            (size_of::<TOKEN_MANDATORY_LABEL>() as u32) + GetLengthSid(sid),
        )
    };
    // SAFETY: `sid` came from ConvertStringSidToSidW and is freed once.
    let _ = unsafe { LocalFree(HLOCAL(sid.0)) };
    set.map_err(|e| format!("SetTokenInformation(TokenIntegrityLevel): {e}"))?;

    let inherit = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: std::ptr::null_mut(),
        bInheritHandle: true.into(),
    };
    let (mut read, mut write) = (HANDLE::default(), HANDLE::default());
    // SAFETY: writable out handles and a valid SECURITY_ATTRIBUTES.
    unsafe { CreatePipe(&mut read, &mut write, Some(&inherit), 0) }.map_err(|e| format!("CreatePipe: {e}"))?;
    let write = Owned(write);
    // SAFETY: `read` is a live pipe handle; from here it is owned by the File.
    let output = unsafe { File::from_raw_handle(read.0 as RawHandle) };
    // SAFETY: a live handle of this process; the child must not inherit it.
    unsafe { SetHandleInformation(read, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0)) }
        .map_err(|e| format!("SetHandleInformation: {e}"))?;

    let si = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        dwFlags: STARTF_USESTDHANDLES,
        hStdInput: HANDLE::default(),
        hStdOutput: write.0,
        hStdError: write.0,
        ..Default::default()
    };
    let mut pi = PROCESS_INFORMATION::default();
    let mut cmd: Vec<u16> = command_line.encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: `cmd` is a writable NUL-terminated buffer (the call may write
    // to it); `si` and `pi` are valid; the token is a primary token.
    unsafe {
        CreateProcessAsUserW(
            lowered.0,
            PCWSTR::null(),
            PWSTR(cmd.as_mut_ptr()),
            None,
            None,
            true,
            CREATE_NO_WINDOW,
            None,
            PCWSTR::null(),
            &si,
            &mut pi,
        )
    }
    .map_err(|e| format!("CreateProcessAsUserW: {e}"))?;
    drop(Owned(pi.hThread));
    // `write` drops here, so the pipe ends when the child exits.
    drop(write);
    Ok(Lowered { process: Owned(pi.hProcess), pid: pi.dwProcessId, output })
}
