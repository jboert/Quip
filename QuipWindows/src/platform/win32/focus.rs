//! Spec 5.3: bringing a window to the foreground from a background process.
//! The waits are M0's (`spike/src/win.rs` `bring_to_front`): 100 ms after a
//! bare `SetForegroundWindow`, 150 ms after `AttachThreadInput`, 300 ms after
//! the Alt tap, polled every 20 ms. "In front" means the handle AND the pid
//! that owned it when listed.
//!
//! Nothing here waits on a window that does not respond: a hung target is
//! refused before any call that sends it a message, and step 3 is skipped
//! when the window in front is hung (attaching to a hung thread can block).
//! Detach always follows attach (`Attached` detaches when dropped).

use std::thread::sleep;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, GetForegroundWindow, GetWindowThreadProcessId, IsHungAppWindow, PeekMessageW,
    SetForegroundWindow, MSG, PM_NOREMOVE, SW_RESTORE,
};

use super::{arrange, input, window};
use crate::platform::keymap::ALT_TAP;
use crate::platform::traits::{FocusStep, PlatformError, PlatformResult};

pub const STEP2_WAIT: Duration = Duration::from_millis(100);
pub const STEP3_WAIT: Duration = Duration::from_millis(150);
pub const STEP4_WAIT: Duration = Duration::from_millis(300);
const POLL: Duration = Duration::from_millis(20);

fn in_front(h: HWND, pid: u32) -> bool {
    // SAFETY: no arguments.
    let fg = unsafe { GetForegroundWindow() };
    fg == h && window::owner_pid(fg) == pid
}

fn wait_front(h: HWND, pid: u32, wait: Duration) -> bool {
    let deadline = Instant::now() + wait;
    loop {
        if in_front(h, pid) {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        sleep(POLL);
    }
}

fn is_hung(h: HWND) -> bool {
    // SAFETY: any handle value is accepted.
    unsafe { IsHungAppWindow(h) }.as_bool()
}

/// `AttachThreadInput(me, other, TRUE)`, undone when dropped.
struct Attached {
    me: u32,
    other: u32,
}

impl Attached {
    fn to(other: u32) -> Option<Attached> {
        // SAFETY: no arguments.
        let me = unsafe { GetCurrentThreadId() };
        if other == 0 || other == me {
            return None;
        }
        // AttachThreadInput needs a message queue on this thread; a peek
        // creates one (the input lane is a plain thread).
        let mut msg = MSG::default();
        // SAFETY: a writable MSG; PM_NOREMOVE takes nothing off the queue.
        let _ = unsafe { PeekMessageW(&mut msg, HWND::default(), 0, 0, PM_NOREMOVE) };
        // SAFETY: plain thread ids.
        unsafe { AttachThreadInput(me, other, true) }.as_bool().then_some(Attached { me, other })
    }
}

impl Drop for Attached {
    fn drop(&mut self) {
        // SAFETY: plain thread ids; undoes the attach made in `to`.
        let _ = unsafe { AttachThreadInput(self.me, self.other, false) };
    }
}

/// The spec 5.3 sequence for `h`, owned by `pid` (already checked live).
pub fn bring_to_foreground(h: HWND, pid: u32) -> PlatformResult<FocusStep> {
    if in_front(h, pid) {
        return Ok(FocusStep::AlreadyForeground);
    }
    if is_hung(h) {
        return Err(PlatformError::FocusRefused);
    }
    // Step 1: a minimized window comes back first (async: never waits).
    if window::is_minimized(h) {
        arrange::show(h, SW_RESTORE)?;
    }
    // Step 2.
    // SAFETY: any handle value is accepted.
    let _ = unsafe { SetForegroundWindow(h) };
    if wait_front(h, pid, STEP2_WAIT) {
        return Ok(FocusStep::SetForeground);
    }
    // Step 3, unless the window in front does not respond.
    // SAFETY: no arguments.
    let fg = unsafe { GetForegroundWindow() };
    if fg.is_invalid() || !is_hung(fg) {
        // SAFETY: a null out pointer is allowed; any handle is accepted.
        let fg_thread = if fg.is_invalid() { 0 } else { unsafe { GetWindowThreadProcessId(fg, None) } };
        let attached = Attached::to(fg_thread);
        // SAFETY: plain handle arguments; `h` is not hung (checked above).
        unsafe {
            let _ = BringWindowToTop(h);
            let _ = SetForegroundWindow(h);
            let _ = SetFocus(h);
        }
        drop(attached);
        if wait_front(h, pid, STEP3_WAIT) {
            return Ok(FocusStep::AttachThreadInput);
        }
    }
    // Step 4: the "last input event" allowance.
    input::send_events(&ALT_TAP);
    // SAFETY: any handle value is accepted.
    let _ = unsafe { SetForegroundWindow(h) };
    if wait_front(h, pid, STEP4_WAIT) {
        return Ok(FocusStep::AltFallback);
    }
    Err(PlatformError::FocusRefused)
}
