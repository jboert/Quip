use crate::protocol::types::Rect;
use crate::protocol::messages::WindowState;

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
    /// True if the window is on the active workspace / desktop. Used by
    /// the mirror-desktop filter to drop disabled terminals on other
    /// workspaces from the broadcast — the iPhone shouldn't see "ghost"
    /// terminals it can't actually interact with right now.
    pub is_on_visible_screen: bool,
}

impl ManagedWindow {
    /// Convert to WindowState for protocol messages.
    /// Frame is normalized to 0-1 relative to the given screen bounds.
    pub fn to_window_state(&self, state: &str, screen_bounds: &Rect, is_thinking: bool) -> WindowState {
        self.to_window_state_with_mode(state, screen_bounds, is_thinking, None)
    }

    pub fn to_window_state_with_mode(
        &self,
        state: &str,
        screen_bounds: &Rect,
        is_thinking: bool,
        claude_mode: Option<String>,
    ) -> WindowState {
        let frame = self.bounds.to_normalized(screen_bounds);
        WindowState {
            id: self.id.clone(),
            name: self.name.clone(),
            app: self.app.clone(),
            folder: if self.subtitle.is_empty() {
                None
            } else {
                Some(self.subtitle.clone())
            },
            enabled: self.is_enabled,
            frame,
            state: state.to_string(),
            color: self.assigned_color.clone(),
            is_thinking,
            claude_mode,
        }
    }
}

/// Rich, vibrant color palette for window identification (matches Mac)
pub const COLOR_PALETTE: &[&str] = &[
    "#F5A623", "#4A90D9", "#7ED321", "#D0021B", "#9013FE",
    "#50E3C2", "#BD10E0", "#B8E986", "#F8E71C", "#FF6B6B",
];
