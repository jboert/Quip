use crate::protocol::types::{Rect, WindowFrame, WindowState};

/// A window managed by Quip
#[derive(Debug, Clone)]
pub struct ManagedWindow {
    /// Unique identifier: "{app_class}.{window_id}"
    pub id: String,
    /// Window title
    pub name: String,
    /// Application name
    pub app: String,
    /// Directory path or secondary info
    pub subtitle: String,
    /// WM_CLASS or app_id
    pub app_class: String,
    /// Whether this window participates in layouts
    pub is_enabled: bool,
    /// Hex color from palette
    pub assigned_color: String,
    /// Process ID
    pub pid: u32,
    /// X11 window ID or Wayland compositor ID
    pub window_id: u64,
    /// Current window bounds in absolute pixels
    pub bounds: Rect,
}

impl ManagedWindow {
    /// Convert to WindowState for protocol messages.
    /// Frame is normalized to 0-1 relative to the given screen bounds.
    pub fn to_window_state(&self, state: &str, screen_bounds: &Rect) -> WindowState {
        let frame = self.bounds.to_normalized(screen_bounds);
        WindowState {
            id: self.id.clone(),
            name: self.name.clone(),
            app: if self.subtitle.is_empty() {
                self.app.clone()
            } else {
                self.subtitle.clone()
            },
            enabled: self.is_enabled,
            frame,
            state: state.to_string(),
            color: self.assigned_color.clone(),
        }
    }
}

/// Rich, vibrant color palette for window identification (matches Mac)
pub const COLOR_PALETTE: &[&str] = &[
    "#F5A623", "#4A90D9", "#7ED321", "#D0021B", "#9013FE",
    "#50E3C2", "#BD10E0", "#B8E986", "#F8E71C", "#FF6B6B",
];
