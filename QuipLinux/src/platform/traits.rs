use crate::protocol::types::Rect;
use std::fmt;

/// Information about a raw window from the display server
#[derive(Debug, Clone)]
pub struct RawWindowInfo {
    pub window_id: u64,
    pub title: String,
    pub app_name: String,
    pub app_class: String,
    pub pid: u32,
    pub bounds: Rect,
}

/// Information about a display/monitor
#[derive(Debug, Clone)]
pub struct DisplayInfo {
    pub id: String,
    pub name: String,
    pub frame: Rect,
    pub is_primary: bool,
}

/// Errors from platform operations
#[derive(Debug)]
pub enum PlatformError {
    NotAvailable(String),
    CommandFailed(String),
    WindowNotFound(u64),
    Other(String),
}

impl fmt::Display for PlatformError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAvailable(msg) => write!(f, "not available: {msg}"),
            Self::CommandFailed(msg) => write!(f, "command failed: {msg}"),
            Self::WindowNotFound(id) => write!(f, "window {id} not found"),
            Self::Other(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for PlatformError {}

pub type PlatformResult<T> = Result<T, PlatformError>;

/// Backend for enumerating and managing windows
pub trait WindowBackend: Send + Sync {
    /// Enumerate all visible terminal windows
    fn list_windows(&self) -> PlatformResult<Vec<RawWindowInfo>>;

    /// Get display/monitor information
    fn list_displays(&self) -> PlatformResult<Vec<DisplayInfo>>;

    /// Focus/raise a specific window
    fn focus_window(&self, window_id: u64) -> PlatformResult<()>;

    /// Move and resize a window to absolute coordinates
    fn move_resize_window(&self, window_id: u64, x: i32, y: i32, w: u32, h: u32) -> PlatformResult<()>;
}

/// Backend for injecting keystrokes into windows
pub trait InputBackend: Send + Sync {
    /// Type text into a specific window, optionally pressing Return after
    fn send_text(&self, window_id: u64, text: &str, press_return: bool) -> PlatformResult<()>;

    /// Send a special keystroke (e.g., "ctrl+c", "return")
    fn send_keystroke(&self, window_id: u64, key: &str) -> PlatformResult<()>;

    /// Spawn a new terminal window in a directory, running `claude` inside tmux
    fn spawn_terminal(&self, terminal: &str, directory: &str) -> PlatformResult<()>;

    /// Read terminal content from a window (select-all, copy, read clipboard, deselect)
    fn read_content(&self, window_id: u64) -> PlatformResult<String>;

    /// Capture a screenshot of a window, returned as base64-encoded PNG
    fn capture_screenshot(&self, window_id: u64) -> PlatformResult<String>;
}

/// Known terminal emulators and their WM_CLASS / app_id values
pub const TERMINAL_CLASSES: &[&str] = &[
    "kitty",
    "Alacritty",
    "alacritty",
    "org.wezfurlong.wezterm",
    "wezterm",
    "foot",
    "foot-client",
    "gnome-terminal-server",
    "gnome-terminal",
    "org.gnome.Terminal",
    "konsole",
    "xterm",
    "xfce4-terminal",
    "tilix",
    "terminator",
    "sakura",
    "st",
    "st-256color",
    "urxvt",
    "ghostty",
    "com.mitchellh.ghostty",
];

/// Check if a WM_CLASS or app_id belongs to a known terminal emulator
pub fn is_terminal_class(class: &str) -> bool {
    TERMINAL_CLASSES.iter().any(|&tc| {
        class.eq_ignore_ascii_case(tc) || class.contains(tc)
    })
}
