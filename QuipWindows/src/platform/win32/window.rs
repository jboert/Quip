//! Reading one top-level window: the `user32` / `dwmapi` calls behind the
//! listing. Nothing here acts on a window.
//!
//! None of these sends a message to a window of ANOTHER process, so a hung
//! app cannot hang the poll. `GetWindowTextW` does send `WM_GETTEXT` to a
//! window of this process owned by another thread, which is why the lister
//! leaves Quip's own windows out before it reads a title.

use std::ffi::c_void;

use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetWindow, GetWindowLongPtrW, GetWindowPlacement, GetWindowRect, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible, IsZoomed, GWL_EXSTYLE, GW_OWNER, WINDOWPLACEMENT,
};

use crate::platform::listing::{rect_from_ltrb, restored_rect};
use crate::platform::traits::{PlatformError, PlatformResult};
use crate::services::layout::PixelRect;

pub fn hwnd(handle: u64) -> HWND {
    HWND(handle as usize as *mut c_void)
}

pub fn handle_of(h: HWND) -> u64 {
    h.0 as usize as u64
}

pub fn pixel_rect(r: RECT) -> PixelRect {
    rect_from_ltrb(r.left, r.top, r.right, r.bottom)
}

/// UTF-16 up to the first NUL.
pub fn from_wide(buf: &[u16]) -> String {
    let end = buf.iter().position(|c| *c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..end])
}

/// Every top-level window, in z-order (front first).
pub fn top_level_windows() -> PlatformResult<Vec<u64>> {
    unsafe extern "system" fn collect(h: HWND, lp: LPARAM) -> BOOL {
        // SAFETY: `lp` is the `&mut Vec<u64>` passed below; it outlives the
        // synchronous `EnumWindows` call and nothing else touches it meanwhile.
        let out = unsafe { &mut *(lp.0 as *mut Vec<u64>) };
        out.push(handle_of(h));
        BOOL(1)
    }
    let mut out: Vec<u64> = Vec::new();
    // SAFETY: the callback only writes through the pointer to `out`, which
    // lives on this frame for the whole call.
    unsafe { EnumWindows(Some(collect), LPARAM(&mut out as *mut Vec<u64> as isize)) }
        .map_err(|e| PlatformError::Failed(format!("EnumWindows: {e}")))?;
    Ok(out)
}

/// The owning process, 0 when the handle is no longer a window.
pub fn owner_pid(h: HWND) -> u32 {
    let mut pid = 0u32;
    // SAFETY: `pid` is a valid out pointer for the call; any handle value is
    // accepted (a dead one returns 0 and leaves `pid` 0).
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    pid
}

pub fn is_window(h: HWND) -> bool {
    // SAFETY: takes any handle value and only reports whether it is a window.
    unsafe { IsWindow(h) }.as_bool()
}

pub fn is_visible(h: HWND) -> bool {
    // SAFETY: as `is_window`.
    unsafe { IsWindowVisible(h) }.as_bool()
}

pub fn is_minimized(h: HWND) -> bool {
    // SAFETY: as `is_window`.
    unsafe { IsIconic(h) }.as_bool()
}

pub fn is_maximized(h: HWND) -> bool {
    // SAFETY: as `is_window`.
    unsafe { IsZoomed(h) }.as_bool()
}

pub fn class_name(h: HWND) -> String {
    let mut buf = [0u16; 256];
    // SAFETY: `buf` is a writable UTF-16 buffer; the call writes at most its
    // length and returns how many units it wrote.
    let n = unsafe { GetClassNameW(h, &mut buf) };
    String::from_utf16_lossy(&buf[..n.clamp(0, 256) as usize])
}

/// See the module doc before calling this on a window of this process.
pub fn title(h: HWND) -> String {
    let mut buf = [0u16; 512];
    // SAFETY: as `class_name`.
    let n = unsafe { GetWindowTextW(h, &mut buf) };
    String::from_utf16_lossy(&buf[..n.clamp(0, 512) as usize])
}

pub fn has_owner(h: HWND) -> bool {
    // SAFETY: reads the owner link of any handle; a null owner is an `Err`.
    unsafe { GetWindow(h, GW_OWNER) }.is_ok_and(|o| !o.is_invalid())
}

pub fn ex_style(h: HWND) -> u32 {
    // SAFETY: reads a window long of any handle (0 for a dead one).
    unsafe { GetWindowLongPtrW(h, GWL_EXSTYLE) as u32 }
}

pub fn is_cloaked(h: HWND) -> bool {
    let mut cloaked = 0u32;
    // SAFETY: `cloaked` is a writable u32 and its size is passed with it, as
    // `DWMWA_CLOAKED` requires.
    let read = unsafe {
        DwmGetWindowAttribute(h, DWMWA_CLOAKED, &mut cloaked as *mut u32 as *mut c_void, size_of::<u32>() as u32)
    };
    read.is_ok() && cloaked != 0
}

/// `GetWindowRect`: the outer rect, invisible resize border included.
pub fn outer_rect(h: HWND) -> Option<PixelRect> {
    let mut r = RECT::default();
    // SAFETY: `r` is a writable RECT for the call.
    unsafe { GetWindowRect(h, &mut r) }.ok()?;
    Some(pixel_rect(r))
}

/// `DWMWA_EXTENDED_FRAME_BOUNDS`: what the user sees.
pub fn frame_bounds(h: HWND) -> Option<PixelRect> {
    let mut r = RECT::default();
    // SAFETY: `r` is a writable RECT and its size is passed with it, as
    // `DWMWA_EXTENDED_FRAME_BOUNDS` requires.
    unsafe {
        DwmGetWindowAttribute(
            h,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            &mut r as *mut RECT as *mut c_void,
            size_of::<RECT>() as u32,
        )
    }
    .ok()?;
    Some(pixel_rect(r))
}

/// Where a minimized window comes back to, in screen pixels (see
/// `listing::restored_rect`). `MonitorFromWindow` answers for the restored
/// rect of a minimized window.
pub fn restored_outer_rect(h: HWND) -> Option<PixelRect> {
    let mut wp = WINDOWPLACEMENT { length: size_of::<WINDOWPLACEMENT>() as u32, ..Default::default() };
    // SAFETY: `wp` is a writable WINDOWPLACEMENT with `length` set.
    unsafe { GetWindowPlacement(h, &mut wp) }.ok()?;
    let normal = pixel_rect(wp.rcNormalPosition);
    // SAFETY: takes any handle; NEAREST always returns a monitor.
    let monitor = unsafe { MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST) };
    let mut mi = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
    // SAFETY: `mi` is a writable MONITORINFO with `cbSize` set.
    if !unsafe { GetMonitorInfoW(monitor, &mut mi) }.as_bool() {
        return Some(normal);
    }
    Some(restored_rect(normal, pixel_rect(mi.rcMonitor), pixel_rect(mi.rcWork)))
}
