//! The Win32 backend. Listing (windows, displays, foreground, shell) is
//! real; acting on windows (focus, input, move, minimize, close) answers
//! `NotImplemented` until those parts land (spec 5.2 - 5.4).
//!
//! Every call blocks and runs on a platform lane (`platform::lanes`). The
//! listing rules themselves are pure, in `platform::listing` and
//! `services::classify`; this module only reads what Windows reports.

mod display;
mod process;
mod window;

use std::collections::HashMap;
use std::sync::Mutex;

use windows::Win32::Foundation::HWND;
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

use crate::platform::listing::{keeps_window, rejected_by, ListingFacts};
use crate::platform::traits::{
    FocusStep, InputBackend, PlatformDisplay, PlatformError, PlatformResult, PlatformWindow, WindowBackend, WindowMove,
    WindowRef,
};
use crate::services::classify::{self, Proc};
use crate::services::keys::KeyChord;
use crate::services::multiline_policy::Shell;

pub use display::effective_dpis;
pub use process::snapshot as process_snapshot;
pub use window::handle_of;

/// `major.minor.build`, e.g. `10.0.26100`, from `RtlGetVersion`
/// (`GetVersionExW` reports 6.2 to an exe without a compatibility manifest).
pub fn os_version() -> Option<String> {
    use windows::Wdk::System::SystemServices::RtlGetVersion;
    use windows::Win32::System::SystemInformation::OSVERSIONINFOW;
    let mut v = OSVERSIONINFOW { dwOSVersionInfoSize: size_of::<OSVERSIONINFOW>() as u32, ..Default::default() };
    // SAFETY: `v` is a writable OSVERSIONINFOW whose size field says so.
    let status = unsafe { RtlGetVersion(&mut v) };
    status.is_ok().then(|| format!("{}.{}.{}", v.dwMajorVersion, v.dwMinorVersion, v.dwBuildNumber))
}

/// What `NotImplemented` says for the operations this backend does not do yet.
pub const NOT_IMPLEMENTED: &str = "the Win32 backend lists windows but cannot act on them yet (use --fake-platform)";

pub struct Win32Platform {
    /// Quip's own windows are never listed (spec 5.1).
    own_pid: Option<u32>,
    /// Exe path -> version-resource name. Read once per exe, not every poll.
    names: Mutex<HashMap<String, Option<String>>>,
}

impl Win32Platform {
    /// Also makes the process per-monitor DPI aware v2. `Quip.exe` already
    /// is (its manifest, see `build.rs`) and Windows refuses a second setting,
    /// which is fine; test binaries have no manifest and get it here.
    pub fn new() -> PlatformResult<Self> {
        // SAFETY: plain value argument; it fails harmlessly when the
        // awareness is already set.
        let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        // SAFETY: no arguments.
        let own_pid = unsafe { GetCurrentProcessId() };
        Ok(Self { own_pid: Some(own_pid), names: Mutex::new(HashMap::new()) })
    }

    /// Lists this process's windows too, for tests that make their own
    /// windows to exercise the filter. Call `list_windows` from the thread
    /// that created them (see `window`'s module doc).
    pub fn including_own_windows(mut self) -> Self {
        self.own_pid = None;
        self
    }

    fn app_name(&self, exe: &str) -> Option<String> {
        let mut names = self.names.lock().unwrap_or_else(|p| p.into_inner());
        names.entry(exe.to_string()).or_insert_with(|| process::display_name(exe)).clone()
    }

    /// What the filter reads about `h`. Quip's own windows get an empty title
    /// without `GetWindowTextW` (see `window`'s module doc).
    fn read(&self, h: HWND, pid: u32) -> RawWindow {
        let own = self.own_pid == Some(pid);
        RawWindow {
            pid,
            class_name: window::class_name(h),
            title: if own { String::new() } else { window::title(h) },
            visible: window::is_visible(h),
            has_owner: window::has_owner(h),
            ex_style: window::ex_style(h),
            cloaked: window::is_cloaked(h),
        }
    }

    fn describe(&self, handle: u64, procs: &[Proc]) -> Option<PlatformWindow> {
        let h = window::hwnd(handle);
        let pid = window::owner_pid(h);
        if pid == 0 {
            return None;
        }
        let RawWindow { class_name, title, .. } = {
            let raw = self.read(h, pid);
            if !keeps_window(&raw.facts(self.own_pid)) {
                return None;
            }
            raw
        };

        let exe_path = process::exe_path(pid);
        let host = classify::terminal_host(&class_name, exe_path.as_deref());
        let shells = host.map(|t| classify::console_programs(t, pid, procs)).unwrap_or_default();
        let product = match (&host, &exe_path) {
            (None, Some(exe)) => self.app_name(exe),
            _ => None,
        };
        let c = classify::classify(&class_name, exe_path.as_deref(), product.as_deref(), &shells);

        let is_minimized = window::is_minimized(h);
        let (visible, outer) = if is_minimized {
            // DWM has no frame bounds for an iconic window: both rects are
            // the restored outer rect.
            let r = window::restored_outer_rect(h)?;
            (r, r)
        } else {
            let outer = window::outer_rect(h)?;
            (window::frame_bounds(h).unwrap_or(outer), outer)
        };
        Some(PlatformWindow {
            handle,
            pid,
            title,
            class_name,
            exe_path,
            app: c.app,
            terminal: c.terminal,
            shell: c.shell,
            visible,
            outer,
            is_minimized,
            is_maximized: !is_minimized && window::is_maximized(h),
        })
    }

    /// Every top-level window of class `class_name`, listed or not, one line
    /// each: the facts the filter reads, the owner's exe and the verdict
    /// (`listed`, the rule that dropped it, `no owner pid` or `no rect`).
    /// For failure messages: it says why a window someone expected is
    /// missing.
    pub fn explain_class(&self, class_name: &str) -> String {
        let procs = process::snapshot().unwrap_or_default();
        let handles = match window::top_level_windows() {
            Ok(h) => h,
            Err(e) => return format!("{e}\n"),
        };
        let mut out = String::new();
        for handle in handles {
            let h = window::hwnd(handle);
            if window::class_name(h) != class_name {
                continue;
            }
            let pid = window::owner_pid(h);
            let raw = self.read(h, pid);
            let verdict = match rejected_by(&raw.facts(self.own_pid)) {
                _ if pid == 0 => "no owner pid",
                Some(rule) => rule,
                None if self.describe(handle, &procs).is_none() => "no rect",
                None => "listed",
            };
            out.push_str(&format!(
                "{handle:#x} pid={pid} exe={:?} title={:?} visible={} owned={} ex_style={:#x} cloaked={} verdict={verdict}\n",
                process::exe_path(pid).unwrap_or_default(),
                raw.title,
                raw.visible,
                raw.has_owner,
                raw.ex_style,
                raw.cloaked,
            ));
        }
        if out.is_empty() {
            out.push_str(&format!("no top-level {class_name} window at all\n"));
        }
        out
    }

    /// The window `w` names, if it still exists and `w.pid` still owns it
    /// (HWND values are reused).
    fn live(&self, w: WindowRef) -> PlatformResult<windows::Win32::Foundation::HWND> {
        let h = window::hwnd(w.handle);
        if window::is_window(h) && window::owner_pid(h) == w.pid {
            Ok(h)
        } else {
            Err(PlatformError::WindowGone)
        }
    }
}

/// The filter's inputs for one window, owned (see `ListingFacts`).
struct RawWindow {
    pid: u32,
    class_name: String,
    title: String,
    visible: bool,
    has_owner: bool,
    ex_style: u32,
    cloaked: bool,
}

impl RawWindow {
    fn facts(&self, own_pid: Option<u32>) -> ListingFacts<'_> {
        ListingFacts {
            pid: self.pid,
            own_pid,
            visible: self.visible,
            title: &self.title,
            has_owner: self.has_owner,
            ex_style: self.ex_style,
            cloaked: self.cloaked,
            class_name: &self.class_name,
        }
    }
}

fn ni<T>() -> PlatformResult<T> {
    Err(PlatformError::NotImplemented(NOT_IMPLEMENTED))
}

impl WindowBackend for Win32Platform {
    fn list_windows(&self) -> PlatformResult<Vec<PlatformWindow>> {
        // One snapshot per poll serves every terminal in it.
        let procs = process::snapshot()?;
        Ok(window::top_level_windows()?.into_iter().filter_map(|h| self.describe(h, &procs)).collect())
    }

    fn list_displays(&self) -> PlatformResult<Vec<PlatformDisplay>> {
        display::list()
    }

    fn foreground_window(&self) -> PlatformResult<Option<WindowRef>> {
        // SAFETY: no arguments; returns null when nothing is in front.
        let h = unsafe { GetForegroundWindow() };
        if h.is_invalid() {
            return Ok(None);
        }
        let pid = window::owner_pid(h);
        Ok((pid != 0).then(|| WindowRef { handle: window::handle_of(h), pid }))
    }

    fn current_shell(&self, w: WindowRef) -> PlatformResult<Option<Shell>> {
        let h = self.live(w)?;
        let class_name = window::class_name(h);
        let exe_path = process::exe_path(w.pid);
        let Some(host) = classify::terminal_host(&class_name, exe_path.as_deref()) else { return Ok(None) };
        let procs = process::snapshot()?;
        Ok(Some(classify::resolve_shell(&classify::console_programs(host, w.pid, &procs))))
    }

    fn bring_to_foreground(&self, _window: WindowRef) -> PlatformResult<FocusStep> {
        ni()
    }
    fn move_windows(&self, moves: &[WindowMove]) -> Vec<PlatformResult<()>> {
        moves.iter().map(|_| ni()).collect()
    }
    fn minimize(&self, _window: WindowRef) -> PlatformResult<()> {
        ni()
    }
    fn close(&self, _window: WindowRef) -> PlatformResult<()> {
        ni()
    }
}

impl InputBackend for Win32Platform {
    fn send_units(&self, _window: WindowRef, _units: &[u16]) -> PlatformResult<usize> {
        ni()
    }
    fn press_key(&self, _window: WindowRef, _chord: KeyChord) -> PlatformResult<usize> {
        ni()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acting_on_a_window_says_what_is_missing() {
        let Ok(p) = Win32Platform::new() else { panic!("Win32Platform::new failed") };
        let w = WindowRef { handle: 1, pid: 1 };
        assert!(matches!(p.close(w), Err(PlatformError::NotImplemented(m)) if m.contains("--fake-platform")));
        assert!(matches!(p.send_units(w, &[65]), Err(PlatformError::NotImplemented(_))));
    }

    #[test]
    fn a_dead_window_is_gone() {
        let Ok(p) = Win32Platform::new() else { panic!("Win32Platform::new failed") };
        assert_eq!(p.current_shell(WindowRef { handle: 0, pid: 4242 }), Err(PlatformError::WindowGone));
    }
}
