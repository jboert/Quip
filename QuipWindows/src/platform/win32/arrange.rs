//! Spec 5.2 and 3.3, the Win32 calls behind arrange, minimize and close. The
//! order (restore, measure, move, verify, retry) is `services::arrange`;
//! this only makes the calls. Every function takes an HWND the caller got
//! from `Win32Platform::live`, so the pid still owns it.
//!
//! Nothing here can block on a hung window: a window `IsHungAppWindow`
//! reports is refused before `SetWindowPos` (which waits for the window's
//! thread), and restore and minimize post with `ShowWindowAsync`.
//!
//! A window of the CALLING thread (the tests' own windows) gets the
//! synchronous `ShowWindow` instead: `ShowWindowAsync` would queue it on a
//! thread that is busy waiting for it.
//!
//! Never `TerminateProcess`: close is `WM_CLOSE`, which the app may answer
//! with a "save changes?" prompt.

use std::thread::sleep;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{ERROR_ACCESS_DENIED, HWND, LPARAM, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    BeginDeferWindowPos, DeferWindowPos, EndDeferWindowPos, GetWindowThreadProcessId, IsHungAppWindow, PostMessageW,
    SetWindowPos, ShowWindow, ShowWindowAsync, SHOW_WINDOW_CMD, SWP_NOACTIVATE, SWP_NOZORDER, SW_MINIMIZE, SW_RESTORE,
    WM_CLOSE,
};

use super::window;
use crate::platform::traits::{PlatformError, PlatformResult, WindowRects};
use crate::services::layout::PixelRect;

/// The refusal text for a window Windows would not move (spec 5.2).
pub const REFUSED: &str = "elevated or refused";
/// The refusal text for a window whose thread does not respond.
pub const NOT_RESPONDING: &str = "not responding";
/// The refusal text for a window still minimized or maximized after
/// `RESTORE_WAIT`.
pub const DID_NOT_RESTORE: &str = "did not restore";

/// Spec 5.2: how long a restore may take.
pub const RESTORE_WAIT: Duration = Duration::from_millis(500);
const RESTORE_POLL: Duration = Duration::from_millis(20);

fn is_hung(h: HWND) -> bool {
    // SAFETY: any handle value is accepted.
    unsafe { IsHungAppWindow(h) }.as_bool()
}

fn on_this_thread(h: HWND) -> bool {
    // SAFETY: a null out pointer is allowed; any handle value is accepted.
    let thread = unsafe { GetWindowThreadProcessId(h, None) };
    // SAFETY: no arguments.
    thread != 0 && thread == unsafe { GetCurrentThreadId() }
}

/// `ShowWindowAsync`, or `ShowWindow` for a window of this thread. `Err`
/// when Windows refused to queue it.
pub(super) fn show(h: HWND, cmd: SHOW_WINDOW_CMD) -> PlatformResult<()> {
    if on_this_thread(h) {
        // SAFETY: a live window of this thread. The return value is the
        // previous visibility, not success.
        let _ = unsafe { ShowWindow(h, cmd) };
        return Ok(());
    }
    // SAFETY: any handle value is accepted; nothing waits for the window.
    if unsafe { ShowWindowAsync(h, cmd) }.as_bool() {
        Ok(())
    } else if !window::is_window(h) {
        Err(PlatformError::WindowGone)
    } else {
        Err(PlatformError::Refused(REFUSED.into()))
    }
}

/// `SW_RESTORE`, then wait until it is neither minimized nor maximized. A
/// window that comes back maximized (it was maximized before it was
/// minimized) gets one more `SW_RESTORE`.
pub fn restore(h: HWND) -> PlatformResult<()> {
    if is_hung(h) {
        return Err(PlatformError::Refused(NOT_RESPONDING.into()));
    }
    let was_minimized = window::is_minimized(h);
    show(h, SW_RESTORE)?;
    let mut second = false;
    let deadline = Instant::now() + RESTORE_WAIT;
    loop {
        if !window::is_window(h) {
            return Err(PlatformError::WindowGone);
        }
        let (min, max) = (window::is_minimized(h), window::is_maximized(h));
        if !min && !max {
            return Ok(());
        }
        if was_minimized && !min && max && !second {
            second = true;
            show(h, SW_RESTORE)?;
        }
        if Instant::now() >= deadline {
            let why = if is_hung(h) { NOT_RESPONDING } else { DID_NOT_RESTORE };
            return Err(PlatformError::Refused(why.into()));
        }
        sleep(RESTORE_POLL);
    }
}

/// `GetWindowRect` + `DWMWA_EXTENDED_FRAME_BOUNDS` (the outer rect when DWM
/// has none) and the window's state, now.
pub fn rects(h: HWND) -> PlatformResult<WindowRects> {
    let Some(outer) = window::outer_rect(h) else {
        return Err(if window::is_window(h) {
            PlatformError::Failed("GetWindowRect failed".into())
        } else {
            PlatformError::WindowGone
        });
    };
    Ok(WindowRects {
        outer,
        visible: window::frame_bounds(h).unwrap_or(outer),
        is_minimized: window::is_minimized(h),
        is_maximized: window::is_maximized(h),
    })
}

const FLAGS: windows::Win32::UI::WindowsAndMessaging::SET_WINDOW_POS_FLAGS =
    windows::Win32::UI::WindowsAndMessaging::SET_WINDOW_POS_FLAGS(SWP_NOZORDER.0 | SWP_NOACTIVATE.0);

/// One `BeginDeferWindowPos` batch. `false` when any step failed: Windows'
/// docs say to abandon the whole batch then (spec 5.2).
fn deferred(batch: &[(HWND, PixelRect)]) -> bool {
    let Ok(n) = i32::try_from(batch.len()) else { return false };
    // SAFETY: plain value argument.
    let Ok(mut hdwp) = (unsafe { BeginDeferWindowPos(n) }) else { return false };
    for &(h, r) in batch {
        // SAFETY: `hdwp` is the live batch handle; on failure Windows frees
        // it and it is not used again.
        match unsafe { DeferWindowPos(hdwp, h, HWND::default(), r.x, r.y, r.width, r.height, FLAGS) } {
            Ok(next) => hdwp = next,
            Err(_) => return false,
        }
    }
    // SAFETY: the live batch handle, ended exactly once.
    unsafe { EndDeferWindowPos(hdwp) }.is_ok()
}

/// One `SetWindowPos` with its own result.
fn set_window_pos(h: HWND, r: PixelRect) -> PlatformResult<()> {
    // SAFETY: plain value arguments; a stale handle fails harmlessly.
    match unsafe { SetWindowPos(h, HWND::default(), r.x, r.y, r.width, r.height, FLAGS) } {
        Ok(()) => Ok(()),
        Err(_) if !window::is_window(h) => Err(PlatformError::WindowGone),
        Err(e) if e.code() == ERROR_ACCESS_DENIED.to_hresult() => Err(PlatformError::Refused(REFUSED.into())),
        Err(e) => Err(PlatformError::Failed(format!("SetWindowPos: {e}"))),
    }
}

/// Moves `moves` (each already checked with `live`, or its error), one
/// result per entry, in order. A hung window is refused without a call; the
/// rest go in one deferred batch, or one by one when the batch fails.
pub fn move_windows(moves: Vec<PlatformResult<(HWND, PixelRect)>>) -> Vec<PlatformResult<()>> {
    let mut out: Vec<Option<PlatformResult<()>>> = Vec::with_capacity(moves.len());
    let mut batch: Vec<(usize, HWND, PixelRect)> = Vec::new();
    for (i, m) in moves.into_iter().enumerate() {
        match m {
            Err(e) => out.push(Some(Err(e))),
            Ok((h, _)) if is_hung(h) => out.push(Some(Err(PlatformError::Refused(NOT_RESPONDING.into())))),
            Ok((h, r)) => {
                out.push(None);
                batch.push((i, h, r));
            }
        }
    }
    let plain: Vec<(HWND, PixelRect)> = batch.iter().map(|&(_, h, r)| (h, r)).collect();
    let all_moved = !plain.is_empty() && deferred(&plain);
    for (i, h, r) in batch {
        out[i] = Some(if all_moved { Ok(()) } else { set_window_pos(h, r) });
    }
    out.into_iter().map(|r| r.unwrap_or(Err(PlatformError::Failed("no result".into())))).collect()
}

/// `ShowWindowAsync(SW_MINIMIZE)`.
pub fn minimize(h: HWND) -> PlatformResult<()> {
    show(h, SW_MINIMIZE)
}

/// `PostMessageW(WM_CLOSE)`: the app decides; never `TerminateProcess`.
pub fn close(h: HWND) -> PlatformResult<()> {
    // SAFETY: posting to any handle is allowed; a stale one fails.
    match unsafe { PostMessageW(h, WM_CLOSE, WPARAM(0), LPARAM(0)) } {
        Ok(()) => Ok(()),
        Err(_) if !window::is_window(h) => Err(PlatformError::WindowGone),
        Err(e) => Err(PlatformError::Refused(format!("{REFUSED} ({e})"))),
    }
}
