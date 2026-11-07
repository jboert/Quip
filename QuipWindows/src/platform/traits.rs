//! What the host needs from the OS (spec 5), as two traits in the shape of
//! QuipLinux's `WindowBackend` / `InputBackend` (`QuipLinux/src/platform/traits.rs`).
//! Everything above `platform/` talks to these, never to Win32, so it all
//! runs on the Mac against `fake.rs`.
//!
//! Every method blocks (Win32 calls do). They are only ever called on the
//! platform lanes (`platform::lanes`), never on the tokio reactor.
//!
//! The safety rules live ABOVE this line, in `services::injector` and the
//! router, so a backend cannot get them wrong:
//! - every call names a window by `WindowRef` (handle AND owning pid). Windows
//!   reuses HWND values after a window closes, so a backend must check the pid
//!   still owns the handle before acting, and answer `WindowGone` if not;
//! - typing is one `send_units` call per `SendInput` batch, and the injector,
//!   not the backend, asks `foreground_window` before every batch and every
//!   key. A backend may check too, but nothing relies on it;
//! - `send_units` / `press_key` report how many inputs Windows inserted; a
//!   short count (UIPI: an elevated window ignores a normal-integrity sender)
//!   stops typing in the injector.

use std::fmt;

use crate::services::classify::TerminalHost;
use crate::services::keys::KeyChord;
use crate::services::layout::PixelRect;
use crate::services::multiline_policy::Shell;

/// A window as every platform call names it: the HWND plus the process that
/// owned it when it was listed. A handle alone is not enough: after a window
/// closes, Windows hands the same HWND value to a new window, maybe in another
/// process, and input meant for the old one would land in the new one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WindowRef {
    /// HWND as an integer.
    pub handle: u64,
    /// `GetWindowThreadProcessId` when listed.
    pub pid: u32,
}

/// One top-level window that passed the listing filter (spec 5.1).
///
/// A minimized window (`IsIconic`) reports its RESTORED rect in `visible` /
/// `outer` (Win32: `GetWindowPlacement().rcNormalPosition`, corrected for the
/// work-area offset), never the parking position at (-32000, -32000) that
/// `GetWindowRect` gives. It stays listed with `is_minimized`, so the phone
/// keeps showing it (flagged) where it will come back. The host also keeps a
/// minimized window in the broadcast set even if a backend gets this wrong.
#[derive(Debug, Clone, PartialEq)]
pub struct PlatformWindow {
    /// HWND as an integer.
    pub handle: u64,
    pub pid: u32,
    pub title: String,
    pub class_name: String,
    /// Full exe path, `None` when the process could not be opened.
    pub exe_path: Option<String>,
    /// From `classify`.
    pub app: String,
    pub terminal: Option<TerminalHost>,
    /// The shell behind a terminal (`None` for non-terminals).
    pub shell: Option<Shell>,
    /// `DWMWA_EXTENDED_FRAME_BOUNDS`: what the user sees.
    pub visible: PixelRect,
    /// `GetWindowRect`: what `SetWindowPos` takes (includes the invisible
    /// resize border).
    pub outer: PixelRect,
    pub is_minimized: bool,
    pub is_maximized: bool,
}

impl PlatformWindow {
    pub fn window_ref(&self) -> WindowRef {
        WindowRef { handle: self.handle, pid: self.pid }
    }
}

/// One monitor.
#[derive(Debug, Clone, PartialEq)]
pub struct PlatformDisplay {
    /// `MONITORINFOEXW.szDevice`, e.g. `\\.\DISPLAY1` (hashed for the wire).
    pub device_name: String,
    /// Human name for the phone's chip.
    pub name: String,
    pub bounds: PixelRect,
    /// `rcWork`: bounds minus the taskbar.
    pub work_area: PixelRect,
    pub is_primary: bool,
}

/// Which step of the spec 5.3 sequence put the window in front. M0 saw every
/// step needed at least once (one classic PowerShell only came up via Alt).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusStep {
    /// It already was the foreground window.
    AlreadyForeground,
    /// Step 2: a bare `SetForegroundWindow`.
    SetForeground,
    /// Step 3: `AttachThreadInput` + `BringWindowToTop` + `SetForegroundWindow`.
    AttachThreadInput,
    /// Step 4: synthetic Alt, then `SetForegroundWindow`.
    AltFallback,
}

impl FocusStep {
    pub fn as_str(self) -> &'static str {
        match self {
            FocusStep::AlreadyForeground => "already",
            FocusStep::SetForeground => "set_foreground",
            FocusStep::AttachThreadInput => "attach_thread_input",
            FocusStep::AltFallback => "alt_fallback",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlatformError {
    /// The window no longer exists.
    WindowGone,
    /// Every step of 5.3 failed; nothing was typed.
    FocusRefused,
    /// The foreground window changed between typing batches; `after_chars`
    /// characters had already landed (spec 5.4 step 4).
    FocusLost {
        after_chars: usize,
    },
    /// `SendInput` inserted fewer inputs than it was given (UIPI blocks input
    /// to an elevated window); `after_chars` characters had landed.
    InputBlocked {
        after_chars: usize,
    },
    /// The OS refused the operation (elevated window, UIPI).
    Refused(String),
    /// An operation the backend does not have yet.
    NotImplemented(&'static str),
    Failed(String),
}

impl fmt::Display for PlatformError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PlatformError::WindowGone => write!(f, "window is gone"),
            PlatformError::FocusRefused => write!(f, "Windows refused to focus the window"),
            PlatformError::FocusLost { after_chars } => write!(f, "focus lost after {after_chars} chars"),
            PlatformError::InputBlocked { after_chars } => write!(f, "input blocked after {after_chars} chars"),
            PlatformError::Refused(m) => write!(f, "refused: {m}"),
            PlatformError::NotImplemented(m) => write!(f, "not implemented: {m}"),
            PlatformError::Failed(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for PlatformError {}

pub type PlatformResult<T> = Result<T, PlatformError>;

/// One window of an arrange batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowMove {
    pub window: WindowRef,
    /// Target OUTER rect (border already compensated).
    pub outer: PixelRect,
    /// Minimized or maximized: `ShowWindow(SW_RESTORE)` first.
    pub restore_first: bool,
}

pub trait WindowBackend: Send + Sync {
    fn list_windows(&self) -> PlatformResult<Vec<PlatformWindow>>;
    fn list_displays(&self) -> PlatformResult<Vec<PlatformDisplay>>;
    /// The foreground window and its owning process, `None` when there is
    /// none. The injector compares this with its target before every batch.
    fn foreground_window(&self) -> PlatformResult<Option<WindowRef>>;
    /// The shell the user is typing into in `window` NOW (re-read at send
    /// time, not the last poll's answer), or `None` for a non-terminal. On
    /// Windows this walks the process snapshot from each console's shell down
    /// through its child processes (`classify::foreground_program`): a shell
    /// running `python`, `ssh` or `node` in the foreground is `Unknown`.
    fn current_shell(&self, window: WindowRef) -> PlatformResult<Option<Shell>>;
    /// The spec 5.3 sequence (restoring a minimized window first). `Err`
    /// means the window is NOT in front and nothing may be typed.
    fn bring_to_foreground(&self, window: WindowRef) -> PlatformResult<FocusStep>;
    /// `BeginDeferWindowPos` batch. One result per move, in order; a refused
    /// window does not stop the others.
    fn move_windows(&self, moves: &[WindowMove]) -> Vec<PlatformResult<()>>;
    fn minimize(&self, window: WindowRef) -> PlatformResult<()>;
    /// `PostMessage(WM_CLOSE)`. Never `TerminateProcess`.
    fn close(&self, window: WindowRef) -> PlatformResult<()>;
}

pub trait InputBackend: Send + Sync {
    /// ONE `SendInput` call: a `KEYEVENTF_UNICODE` down/up pair per UTF-16
    /// unit (`typing_plan` sizes the batches). Returns how many units were
    /// fully inserted (inputs inserted / 2); fewer than `units.len()` means
    /// Windows blocked the rest. Input goes to whatever window is in front:
    /// the caller has already checked that it is `window`.
    fn send_units(&self, window: WindowRef, units: &[u16]) -> PlatformResult<usize>;
    /// ONE `SendInput` call for a chord (modifiers down, key down/up,
    /// modifiers up). Returns the inputs inserted; fewer than
    /// `chord.input_count()` means it was blocked.
    fn press_key(&self, window: WindowRef, chord: KeyChord) -> PlatformResult<usize>;
}

/// Both halves, as one object the host holds.
pub trait Platform: WindowBackend + InputBackend {}
impl<T: WindowBackend + InputBackend> Platform for T {}
