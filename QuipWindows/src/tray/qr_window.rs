//! The pairing QR window (spec 6): one small top-level window on the tray
//! thread, in Quip's own process, so the window lister never lists it
//! (it drops Quip's pid before reading any title).
//!
//! It shows the QR of the `quip://pair?…` link (`tray::qr`), and the URL and
//! the PIN as text for typing them in by hand. Esc or the close button closes
//! it; "Show pairing QR…" while it is open brings the same window back to
//! the front with fresh content. The modules are painted with GDI
//! rectangles, scaled to the window's DPI.
//!
//! State is thread-local and only touched with `try_borrow*`, never held
//! across a call that can re-enter the window procedure.

use std::cell::{Cell, RefCell};
use std::time::{Duration, Instant};

use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{
    GetLastError, COLORREF, ERROR_CLASS_ALREADY_EXISTS, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM,
};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, DrawTextW, EndPaint, FillRect, InvalidateRect,
    SelectObject, SetBkMode, SetTextColor, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DT_CENTER,
    DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER, FW_NORMAL, HDC, HGDIOBJ, OUT_DEFAULT_PRECIS, PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForSystem, GetDpiForWindow};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect, GetSystemMetrics, IsWindow,
    IsWindowVisible, PeekMessageW, PostMessageW, RegisterClassExW, SetForegroundWindow, SetWindowPos, ShowWindow,
    TranslateMessage, CS_HREDRAW, CS_VREDRAW, HWND_TOP, MSG, PM_REMOVE, SM_CXSCREEN, SM_CYSCREEN, SWP_NOACTIVATE,
    SWP_NOZORDER, SW_SHOWNORMAL, WINDOW_EX_STYLE, WM_DESTROY, WM_DPICHANGED, WM_KEYDOWN, WM_PAINT, WNDCLASSEXW,
    WS_CAPTION, WS_OVERLAPPED, WS_SYSMENU,
};

use super::menu::grouped_pin;
use super::qr::{PairingQr, QUIET_ZONE};
use crate::platform::traits::WindowBackend;
use crate::platform::win32::{handle_of, Win32Platform};

const CLASS: PCWSTR = w!("QuipPairingQrWindow");
pub const TITLE: &str = "Quip — pair your iPhone";
/// `VK_ESCAPE`.
const VK_ESCAPE: usize = 0x1B;
/// Client size at 96 DPI: the QR square, then three text lines.
const QR_SIDE_96: i32 = 340;
const LINE_96: i32 = 24;
const TEXT_LINES: i32 = 3;

/// What the window shows: a QR, or why there is none.
pub type Content = Result<PairingQr, String>;

thread_local! {
    static WINDOW: Cell<Option<HWND>> = const { Cell::new(None) };
    static CONTENT: RefCell<Option<Content>> = const { RefCell::new(None) };
}

fn style() -> windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE {
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU
}

fn scaled(v: i32, dpi: u32) -> i32 {
    v * dpi as i32 / 96
}

/// The open window, if any.
pub fn open_window() -> Option<HWND> {
    // SAFETY: takes any handle value and only reports whether it is a window.
    WINDOW.get().filter(|h| unsafe { IsWindow(*h) }.as_bool())
}

fn set_content(content: Content) -> Result<(), String> {
    CONTENT.with(|c| match c.try_borrow_mut() {
        Ok(mut g) => {
            *g = Some(content);
            Ok(())
        }
        Err(_) => Err("the QR window is busy".to_string()),
    })
}

/// Shows `content`, reusing the open window (brought to the front) or
/// opening one. Call on the thread that pumps the tray's messages.
pub fn show(content: Content) -> Result<HWND, String> {
    set_content(content)?;
    if let Some(h) = open_window() {
        // SAFETY: our own live window.
        unsafe {
            let _ = InvalidateRect(h, None, true);
            let _ = ShowWindow(h, SW_SHOWNORMAL);
            let _ = SetForegroundWindow(h);
        }
        return Ok(h);
    }
    let h = create()?;
    WINDOW.set(Some(h));
    // SAFETY: the window was just created on this thread.
    unsafe {
        let _ = ShowWindow(h, SW_SHOWNORMAL);
        let _ = SetForegroundWindow(h);
    }
    Ok(h)
}

/// New content for the open window (a new PIN); nothing when it is closed.
pub fn refresh(content: Content) {
    if let Some(h) = open_window() {
        if set_content(content).is_ok() {
            // SAFETY: our own live window.
            let _ = unsafe { InvalidateRect(h, None, true) };
        }
    }
}

/// Closes the window if it is open.
pub fn close() {
    if let Some(h) = open_window() {
        // SAFETY: our own window, on its thread; WM_DESTROY clears `WINDOW`.
        let _ = unsafe { DestroyWindow(h) };
    }
    WINDOW.set(None);
}

fn create() -> Result<HWND, String> {
    // SAFETY: null module name = this exe.
    let module = unsafe { GetModuleHandleW(None) }.map_err(|e| e.to_string())?;
    let instance = HINSTANCE::from(module);
    let class = WNDCLASSEXW {
        cbSize: size_of::<WNDCLASSEXW>() as u32,
        style: CS_HREDRAW | CS_VREDRAW,
        lpfnWndProc: Some(wndproc),
        hInstance: instance,
        lpszClassName: CLASS,
        ..Default::default()
    };
    // SAFETY: `class` is fully initialized and its strings are static; a
    // second registration fails with ERROR_CLASS_ALREADY_EXISTS, which is
    // fine.
    if unsafe { RegisterClassExW(&class) } == 0 && unsafe { GetLastError() } != ERROR_CLASS_ALREADY_EXISTS {
        return Err(format!("cannot register the QR window class: {}", windows::core::Error::from_win32()));
    }
    // SAFETY: no arguments.
    let dpi = unsafe { GetDpiForSystem() };
    let (w, h) = outer_size(dpi);
    // SAFETY: plain value arguments.
    let (sw, sh) = unsafe { (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)) };
    // SAFETY: the class is registered above; the title outlives the call;
    // no parent, menu or create parameter.
    unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE(0),
            CLASS,
            &HSTRING::from(TITLE),
            style(),
            ((sw - w) / 2).max(0),
            ((sh - h) / 2).max(0),
            w,
            h,
            None,
            None,
            instance,
            None,
        )
    }
    .map_err(|e| format!("cannot open the QR window: {e}"))
}

/// The window size for the client area at `dpi`.
fn outer_size(dpi: u32) -> (i32, i32) {
    let side = scaled(QR_SIDE_96, dpi);
    let mut r = RECT { left: 0, top: 0, right: side, bottom: side + scaled(LINE_96, dpi) * TEXT_LINES };
    // SAFETY: `r` is writable; plain value arguments.
    let _ = unsafe { AdjustWindowRectExForDpi(&mut r, style(), false, WINDOW_EX_STYLE(0), dpi) };
    (r.right - r.left, r.bottom - r.top)
}

fn draw_line(hdc: HDC, text: &str, mut r: RECT) {
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    // SAFETY: `wide` and `r` are writable buffers that outlive the call.
    unsafe { DrawTextW(hdc, &mut wide, &mut r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX) };
}

fn paint(hwnd: HWND) {
    let mut ps = PAINTSTRUCT::default();
    // SAFETY: inside WM_PAINT for our window; `ps` is writable.
    let hdc = unsafe { BeginPaint(hwnd, &mut ps) };
    let mut client = RECT::default();
    // SAFETY: our window; `client` is writable.
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    // SAFETY: our window.
    let dpi = unsafe { GetDpiForWindow(hwnd) }.max(96);
    let line = scaled(LINE_96, dpi);
    // SAFETY: plain value arguments; both brushes are deleted below.
    let (white, black) = unsafe { (CreateSolidBrush(COLORREF(0x00FF_FFFF)), CreateSolidBrush(COLORREF(0))) };
    // SAFETY: a valid DC, rect and brush.
    unsafe { FillRect(hdc, &client, white) };
    let text_top = client.bottom - line * TEXT_LINES;
    // SAFETY: a constant face name; the font is deselected and deleted below.
    let font = unsafe {
        CreateFontW(
            -scaled(14, dpi),
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET.0 as u32,
            OUT_DEFAULT_PRECIS.0 as u32,
            CLIP_DEFAULT_PRECIS.0 as u32,
            CLEARTYPE_QUALITY.0 as u32,
            0,
            w!("Segoe UI"),
        )
    };
    // SAFETY: a valid DC and font.
    let old = unsafe { SelectObject(hdc, HGDIOBJ(font.0)) };
    // SAFETY: a valid DC.
    unsafe {
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, COLORREF(0));
    }
    let row = |i: i32| RECT {
        left: client.left,
        top: text_top + line * i,
        right: client.right,
        bottom: text_top + line * (i + 1),
    };
    CONTENT.with(|c| {
        let Ok(g) = c.try_borrow() else { return };
        match g.as_ref() {
            Some(Ok(q)) => {
                let modules = (q.matrix.width() + 2 * QUIET_ZONE) as i32;
                let side = (client.right - client.left).min(text_top - client.top);
                let px = (side / modules).max(1);
                let x0 = client.left + ((client.right - client.left) - px * modules) / 2 + px * QUIET_ZONE as i32;
                let y0 = client.top + ((text_top - client.top) - px * modules) / 2 + px * QUIET_ZONE as i32;
                for y in 0..q.matrix.width() {
                    for x in 0..q.matrix.width() {
                        if q.matrix.is_dark(x, y) {
                            let (l, t) = (x0 + px * x as i32, y0 + px * y as i32);
                            let r = RECT { left: l, top: t, right: l + px, bottom: t + px };
                            // SAFETY: a valid DC, rect and brush.
                            unsafe { FillRect(hdc, &r, black) };
                        }
                    }
                }
                draw_line(hdc, "Scan with the Quip app on your iPhone", row(0));
                draw_line(hdc, &q.url, row(1));
                draw_line(hdc, &format!("PIN {}", grouped_pin(&q.pin)), row(2));
            }
            Some(Err(why)) => {
                let r = RECT { left: client.left, top: client.top, right: client.right, bottom: text_top };
                draw_line(hdc, "No pairing QR", r);
                draw_line(hdc, why, row(1));
            }
            None => {}
        }
    });
    // SAFETY: restores the DC's font, then frees what was created above;
    // `ps` came from BeginPaint.
    unsafe {
        SelectObject(hdc, old);
        let _ = DeleteObject(HGDIOBJ(font.0));
        let _ = DeleteObject(HGDIOBJ(white.0));
        let _ = DeleteObject(HGDIOBJ(black.0));
        let _ = EndPaint(hwnd, &ps);
    }
}

extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_PAINT => {
            paint(hwnd);
            LRESULT(0)
        }
        WM_KEYDOWN if wparam.0 == VK_ESCAPE => {
            // SAFETY: our own window, on its thread.
            let _ = unsafe { DestroyWindow(hwnd) };
            LRESULT(0)
        }
        WM_DPICHANGED => {
            // SAFETY: for WM_DPICHANGED, lparam points at the suggested
            // window rect, valid for the duration of the message.
            let r = unsafe { *(lparam.0 as *const RECT) };
            // SAFETY: our own window; plain value arguments.
            let _ = unsafe {
                SetWindowPos(
                    hwnd,
                    HWND_TOP,
                    r.left,
                    r.top,
                    r.right - r.left,
                    r.bottom - r.top,
                    SWP_NOZORDER | SWP_NOACTIVATE,
                )
            };
            LRESULT(0)
        }
        WM_DESTROY => {
            // Not the tray: the message loop keeps running.
            if WINDOW.get() == Some(hwnd) {
                WINDOW.set(None);
            }
            LRESULT(0)
        }
        // SAFETY: the arguments are the ones Windows passed in.
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// Dispatches this thread's messages for `d`, or until `done` is true.
pub fn pump(d: Duration, done: impl Fn() -> bool) {
    let until = Instant::now() + d;
    let mut msg = MSG::default();
    while Instant::now() < until && !done() {
        // SAFETY: `msg` is writable; any window of this thread.
        while unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) }.as_bool() {
            // SAFETY: `msg` was just filled by PeekMessageW.
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Opens the window with `content`, checks that it is shown, that a second
/// "Show" reuses it, that the lister leaves it out (while the same lister
/// including Quip's own windows does find it, so the check is not vacuous),
/// and that Esc closes it. Always closed afterwards. For the Win32 tests
/// and `--selftest`; call on a thread with no other window of this module.
pub fn check_open_list_close(content: Content) -> Result<(), String> {
    let result = (|| {
        let a = show(content.clone())?;
        pump(Duration::from_millis(300), || false);
        // SAFETY: any handle value.
        if !unsafe { IsWindowVisible(a) }.as_bool() {
            return Err("the QR window is not visible after Show".into());
        }
        let b = show(content)?;
        if a != b {
            return Err("a second Show opened a second window".into());
        }
        let handle = handle_of(a);
        let normal = Win32Platform::new().map_err(|e| e.to_string())?;
        let listed = normal.list_windows().map_err(|e| format!("list_windows: {e}"))?;
        if listed.iter().any(|w| w.handle == handle) {
            return Err("the QR window is in the window listing".into());
        }
        let all = Win32Platform::new().map_err(|e| e.to_string())?.including_own_windows();
        let listed = all.list_windows().map_err(|e| format!("list_windows: {e}"))?;
        if !listed.iter().any(|w| w.handle == handle) {
            return Err("the lister including Quip's own windows does not see the QR window either".into());
        }
        // SAFETY: our own window; a posted key press, as Esc would be.
        unsafe { PostMessageW(a, WM_KEYDOWN, WPARAM(VK_ESCAPE), LPARAM(0)) }.map_err(|e| e.to_string())?;
        // SAFETY: any handle value.
        pump(Duration::from_secs(2), || !unsafe { IsWindow(a) }.as_bool());
        if open_window().is_some() {
            return Err("Esc did not close the QR window".into());
        }
        Ok(())
    })();
    close();
    result
}
