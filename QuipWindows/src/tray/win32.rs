//! The tray (spec 6): a notification-area icon and its menu, on the main
//! thread's message loop.
//!
//! The icon belongs to a hidden tool window created here, in Quip's own
//! process, so the window lister never reads its title (it drops Quip's pid
//! first). The pairing QR window (`qr_window`) lives on this thread too. The thread only reads cheap host state (phone count, PIN, the
//! show-all flag, the Run value, the adapter addresses) and hands work to
//! the host: no `Platform` call ever runs here, so a slow `SendInput` on the
//! input lane cannot freeze the menu. Republishing after "Show all apps"
//! runs on the tokio runtime.
//!
//! The menu is rebuilt each time it opens (`menu::build`). If the taskbar is
//! not up yet (an early login start), the icon is retried every 2 s and
//! re-added whenever Explorer restarts (`TaskbarCreated`).

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::sync::Arc;

use windows::core::{w, HSTRING, PCWSTR};
use windows::Win32::Foundation::{
    GetLastError, GlobalFree, ERROR_CLASS_ALREADY_EXISTS, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM,
};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_SHOWTIP, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY, NIM_SETVERSION,
    NINF_KEY, NIN_SELECT, NOTIFYICONDATAW, NOTIFYICON_VERSION_4, NOTIFY_ICON_DATA_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyIcon, DestroyMenu, DestroyWindow,
    DispatchMessageW, GetCursorPos, GetMessageW, KillTimer, MessageBoxW, PostMessageW, PostQuitMessage,
    RegisterClassExW, RegisterWindowMessageW, SetForegroundWindow, SetTimer, TrackPopupMenuEx, TranslateMessage, HICON,
    HMENU, MB_ICONERROR, MB_OK, MENU_ITEM_FLAGS, MF_CHECKED, MF_GRAYED, MF_SEPARATOR, MF_STRING, MSG, TPM_NONOTIFY,
    TPM_RETURNCMD, TPM_RIGHTBUTTON, WINDOW_STYLE, WM_APP, WM_CONTEXTMENU, WM_DESTROY, WM_NULL, WM_TIMER, WNDCLASSEXW,
    WS_EX_TOOLWINDOW, WS_POPUP,
};

use super::menu::{self, Action, Entry, TrayStatus};
use super::qr::pairing_qr;
use super::{autostart, icon, qr_window};
use crate::host::Host;
use crate::services::local_addresses::interface_ipv4s;
use crate::services::pin_store;
use crate::services::quip_log::Severity;

/// What the tray needs from the running app.
#[derive(Clone)]
pub struct TrayApp {
    pub host: Arc<Host>,
    pub rt: tokio::runtime::Handle,
    /// This `Quip.exe`, for the Run value.
    pub exe: PathBuf,
    pub log_dir: PathBuf,
    pub port: u16,
}

/// The notify icon's callback message.
pub const CALLBACK: u32 = WM_APP + 1;
pub const ICON_ID: u32 = 1;
const RETRY_TIMER: usize = 1;
const RETRY_MS: u32 = 2000;
const CLASS: PCWSTR = w!("QuipTrayWindow");
const CF_UNICODETEXT: u32 = 13;

/// An error before (or instead of) the tray: stderr and a message box.
pub fn show_error(text: &str) {
    eprintln!("Quip: {text}");
    // SAFETY: both strings outlive the call; no owner window.
    unsafe { MessageBoxW(None, &HSTRING::from(text), w!("Quip"), MB_OK | MB_ICONERROR) };
}

/// The hidden window the icon reports to. Never shown; destroyed on drop.
pub struct HiddenWindow(HWND);

impl HiddenWindow {
    /// Call on the thread that will pump its messages.
    pub fn new() -> Result<Self, String> {
        // SAFETY: null module name = this exe.
        let module = unsafe { GetModuleHandleW(None) }.map_err(|e| e.to_string())?;
        let instance = HINSTANCE::from(module);
        let class = WNDCLASSEXW {
            cbSize: size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: instance,
            lpszClassName: CLASS,
            ..Default::default()
        };
        // SAFETY: `class` is fully initialized and its strings are static.
        // A second registration (a test making a second window) fails with
        // ERROR_CLASS_ALREADY_EXISTS, which is fine.
        if unsafe { RegisterClassExW(&class) } == 0 && unsafe { GetLastError() } != ERROR_CLASS_ALREADY_EXISTS {
            return Err(format!("cannot register the tray window class: {}", windows::core::Error::from_win32()));
        }
        // SAFETY: the class is registered above; a zero-size popup that is
        // never shown, no parent, no create parameter.
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_TOOLWINDOW,
                CLASS,
                w!("Quip"),
                WINDOW_STYLE(WS_POPUP.0),
                0,
                0,
                0,
                0,
                None,
                None,
                instance,
                None,
            )
        }
        .map_err(|e| format!("cannot create the tray window: {e}"))?;
        Ok(Self(hwnd))
    }

    pub fn hwnd(&self) -> HWND {
        self.0
    }
}

impl Drop for HiddenWindow {
    fn drop(&mut self) {
        // SAFETY: our own window; failing (already destroyed) is harmless.
        let _ = unsafe { DestroyWindow(self.0) };
    }
}

/// One notification-area icon. Removed on drop.
pub struct NotifyIcon {
    hwnd: HWND,
    id: u32,
}

fn icon_data(hwnd: HWND, id: u32, flags: NOTIFY_ICON_DATA_FLAGS) -> NOTIFYICONDATAW {
    NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: id,
        uFlags: flags,
        ..Default::default()
    }
}

fn set_tip(d: &mut NOTIFYICONDATAW, tip: &str) {
    let wide: Vec<u16> = tip.encode_utf16().take(d.szTip.len() - 1).collect();
    d.szTip[..wide.len()].copy_from_slice(&wide);
    d.szTip[wide.len()] = 0;
}

impl NotifyIcon {
    /// Adds the icon, reporting to `hwnd` with `CALLBACK` (version 4 events).
    pub fn add(hwnd: HWND, id: u32, icon: HICON, tip: &str) -> Result<Self, String> {
        let mut d = icon_data(hwnd, id, NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
        d.uCallbackMessage = CALLBACK;
        d.hIcon = icon;
        set_tip(&mut d, tip);
        // SAFETY: `d` is a fully initialized NOTIFYICONDATAW of its own size.
        if !unsafe { Shell_NotifyIconW(NIM_ADD, &d) }.as_bool() {
            return Err("the notification area refused the icon (is the taskbar running?)".into());
        }
        d.Anonymous.uVersion = NOTIFYICON_VERSION_4;
        // SAFETY: as above.
        let _ = unsafe { Shell_NotifyIconW(NIM_SETVERSION, &d) };
        Ok(Self { hwnd, id })
    }

    /// Whether Windows still has icon `id` of `hwnd` (a modify succeeds only
    /// on an icon that exists).
    pub fn is_present(hwnd: HWND, id: u32, tip: &str) -> bool {
        let mut d = icon_data(hwnd, id, NIF_TIP | NIF_SHOWTIP);
        set_tip(&mut d, tip);
        // SAFETY: as in `add`.
        unsafe { Shell_NotifyIconW(NIM_MODIFY, &d) }.as_bool()
    }
}

impl Drop for NotifyIcon {
    fn drop(&mut self) {
        let d = icon_data(self.hwnd, self.id, NOTIFY_ICON_DATA_FLAGS(0));
        // SAFETY: as in `add`; deleting an icon Explorer already dropped
        // fails harmlessly.
        let _ = unsafe { Shell_NotifyIconW(NIM_DELETE, &d) };
    }
}

struct Tray {
    app: TrayApp,
    hwnd: HWND,
    icon: HICON,
    notify: Option<NotifyIcon>,
}

thread_local! {
    static TRAY: RefCell<Option<Tray>> = const { RefCell::new(None) };
    static MENU_OPEN: Cell<bool> = const { Cell::new(false) };
    static TASKBAR_CREATED: Cell<u32> = const { Cell::new(0) };
}

/// (Re)adds the icon. A failure is logged once per attempt series and
/// retried by the timer.
fn add_icon() {
    TRAY.with(|t| {
        let Ok(mut guard) = t.try_borrow_mut() else { return };
        let Some(tray) = guard.as_mut() else { return };
        tray.notify = None;
        // The tooltip names the build (spec 9, owner check 1).
        match NotifyIcon::add(tray.hwnd, ICON_ID, tray.icon, &crate::build_info::product_line()) {
            Ok(n) => {
                tray.notify = Some(n);
                // SAFETY: our window and timer id; no timer is fine.
                let _ = unsafe { KillTimer(tray.hwnd, RETRY_TIMER) };
            }
            Err(e) => {
                tray.app.host.logs.ws(Severity::Warn, &format!("tray: {e}; retrying every {} s", RETRY_MS / 1000));
                // SAFETY: our window; replaces any timer with this id.
                unsafe { SetTimer(tray.hwnd, RETRY_TIMER, RETRY_MS, None) };
            }
        }
    });
}

fn app() -> Option<TrayApp> {
    TRAY.with(|t| t.try_borrow().ok().and_then(|g| g.as_ref().map(|tray| tray.app.clone())))
}

/// What the menu shows now.
fn status(app: &TrayApp) -> TrayStatus {
    let start_with_windows =
        autostart::read().ok().flatten().is_some_and(|value| autostart::points_at(&value, &app.exe));
    TrayStatus {
        phones: app.host.authenticated_count(),
        pin: app.host.pin(),
        addresses: interface_ipv4s(),
        port: app.port,
        show_all_apps: app.host.state().show_all_apps(),
        start_with_windows,
    }
}

fn append(menu: HMENU, flags: MENU_ITEM_FLAGS, id: usize, label: &str) {
    // SAFETY: `menu` is a live popup menu; the label outlives the call.
    let _ = unsafe { AppendMenuW(menu, flags, id, &HSTRING::from(label)) };
}

/// Shows `entries` at the cursor and returns the chosen action.
fn track(hwnd: HWND, entries: &[Entry]) -> Option<Action> {
    // SAFETY: no arguments.
    let menu = unsafe { CreatePopupMenu() }.ok()?;
    for e in entries {
        match e {
            Entry::Info(label) => append(menu, MF_STRING | MF_GRAYED, 0, label),
            Entry::Item { action, label, enabled, checked } => {
                let mut flags = MF_STRING;
                if !enabled {
                    flags |= MF_GRAYED;
                }
                if *checked {
                    flags |= MF_CHECKED;
                }
                append(menu, flags, action.id() as usize, label);
            }
            // SAFETY: `menu` is live; a separator has no text.
            Entry::Separator => unsafe {
                let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
            },
        }
    }
    let mut pt = POINT::default();
    // SAFETY: `pt` is writable; `menu` and `hwnd` are ours. Making the
    // window foreground first is what lets a click elsewhere close the
    // menu; the WM_NULL afterwards is the documented companion.
    let chosen = unsafe {
        let _ = GetCursorPos(&mut pt);
        let _ = SetForegroundWindow(hwnd);
        let cmd = TrackPopupMenuEx(menu, (TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY).0, pt.x, pt.y, hwnd, None);
        let _ = PostMessageW(hwnd, WM_NULL, WPARAM(0), LPARAM(0));
        let _ = DestroyMenu(menu);
        cmd.0
    };
    Action::from_id(chosen as u32)
}

/// Puts `text` on the clipboard as Unicode text.
pub fn copy_to_clipboard(hwnd: HWND, text: &str) -> Result<(), String> {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    // SAFETY: the clipboard is opened and closed here; the memory block is
    // sized for `wide`, filled while locked, and either handed to the
    // clipboard (which then owns it) or freed.
    unsafe {
        OpenClipboard(hwnd).map_err(|e| format!("cannot open the clipboard: {e}"))?;
        let result = (|| {
            EmptyClipboard().map_err(|e| e.to_string())?;
            let mem = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2).map_err(|e| e.to_string())?;
            let dst = GlobalLock(mem) as *mut u16;
            if dst.is_null() {
                let _ = GlobalFree(mem);
                return Err("cannot lock clipboard memory".to_string());
            }
            std::ptr::copy_nonoverlapping(wide.as_ptr(), dst, wide.len());
            let _ = GlobalUnlock(mem);
            if let Err(e) = SetClipboardData(CF_UNICODETEXT, HANDLE(mem.0)) {
                let _ = GlobalFree(mem);
                return Err(e.to_string());
            }
            Ok(())
        })();
        let _ = CloseClipboard();
        result
    }
}

fn perform(hwnd: HWND, app: &TrayApp, action: Action) {
    let host = &app.host;
    match action {
        Action::CopyPin => {
            if let Err(e) = copy_to_clipboard(hwnd, &host.pin()) {
                host.logs.ws(Severity::Warn, &format!("tray: PIN not copied: {e}"));
            }
        }
        Action::ShowPairingQr => {
            if let Err(e) = qr_window::show(pairing_qr(&interface_ipv4s(), app.port, &host.pin())) {
                host.logs.ws(Severity::Error, &format!("tray: {e}"));
                show_error(&e);
            }
        }
        Action::NewPin => {
            host.replace_pin(pin_store::generate(&mut rand::rng()));
            qr_window::refresh(pairing_qr(&interface_ipv4s(), app.port, &host.pin()));
        }
        Action::ToggleShowAllApps => {
            let on = !host.state().show_all_apps();
            let h = host.clone();
            app.rt.spawn(async move { h.set_show_all_apps(on) });
        }
        Action::ToggleStartWithWindows => {
            let on = autostart::read().ok().flatten().is_some_and(|v| autostart::points_at(&v, &app.exe));
            let result = if on { autostart::remove() } else { autostart::write(&autostart::run_value(&app.exe)) };
            match result {
                Ok(()) => {
                    host.logs.ws(Severity::Info, &format!("tray: start with Windows {}", if on { "off" } else { "on" }))
                }
                Err(e) => {
                    host.logs.ws(Severity::Error, &format!("tray: {e}"));
                    show_error(&e);
                }
            }
        }
        Action::OpenLogsFolder => {
            let dir = app.log_dir.clone();
            std::thread::spawn(move || {
                let _ = std::fs::create_dir_all(&dir);
                let _ = std::process::Command::new("explorer.exe").arg(&dir).spawn();
            });
        }
        Action::Quit => {
            host.logs.ws(Severity::Info, "tray: quit");
            qr_window::close();
            TRAY.with(|t| {
                if let Ok(mut g) = t.try_borrow_mut() {
                    if let Some(tray) = g.as_mut() {
                        tray.notify = None;
                    }
                }
            });
            // SAFETY: our window; WM_DESTROY then ends the loop.
            let _ = unsafe { DestroyWindow(hwnd) };
        }
    }
}

fn on_icon_event(hwnd: HWND, event: u32) {
    let opens = event == WM_CONTEXTMENU || event == NIN_SELECT || event == (NIN_SELECT | NINF_KEY);
    if !opens || MENU_OPEN.get() {
        return;
    }
    let Some(app) = app() else { return };
    MENU_OPEN.set(true);
    let chosen = track(hwnd, &menu::build(&status(&app)));
    MENU_OPEN.set(false);
    if let Some(action) = chosen {
        perform(hwnd, &app, action);
    }
}

extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let taskbar_created = TASKBAR_CREATED.get();
    match msg {
        CALLBACK => {
            on_icon_event(hwnd, (lparam.0 as u32) & 0xFFFF);
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == RETRY_TIMER => {
            add_icon();
            LRESULT(0)
        }
        WM_DESTROY => {
            if app().is_some() {
                // SAFETY: plain value argument.
                unsafe { PostQuitMessage(0) };
            }
            LRESULT(0)
        }
        m if taskbar_created != 0 && m == taskbar_created => {
            add_icon();
            LRESULT(0)
        }
        // SAFETY: the arguments are the ones Windows passed in.
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

/// Runs the tray until "Quit Quip". On the main thread.
pub fn run(app: TrayApp) -> Result<(), String> {
    let window = HiddenWindow::new()?;
    let hwnd = window.hwnd();
    let icon = icon::create()?;
    // SAFETY: a constant name.
    TASKBAR_CREATED.set(unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) });
    app.host.logs.ws(Severity::Info, &format!("tray: running, logs in {}", app.log_dir.display()));
    TRAY.with(|t| *t.borrow_mut() = Some(Tray { app, hwnd, icon, notify: None }));
    add_icon();
    let mut msg = MSG::default();
    // SAFETY: `msg` is writable; 0 is WM_QUIT and -1 an error, both end it.
    while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {
        // SAFETY: `msg` was just filled by GetMessageW.
        unsafe {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    if let Some(tray) = TRAY.with(|t| t.borrow_mut().take()) {
        drop(tray.notify);
        // SAFETY: the icon was created by `icon::create` and is no longer
        // shown.
        let _ = unsafe { DestroyIcon(tray.icon) };
    }
    drop(window);
    Ok(())
}
