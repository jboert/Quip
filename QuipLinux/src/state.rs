use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use crate::models::managed_window::{ManagedWindow, COLOR_PALETTE};
use crate::models::settings::AppSettings;
use crate::platform::traits::{DisplayInfo, InputBackend, RawWindowInfo, WindowBackend};
use crate::protocol::messages::{LayoutUpdate, WindowState};
use crate::protocol::types::{Rect, TerminalState};
use crate::services::state_detector::StateDetector;

/// Shared application state, accessible from both tokio tasks and the GTK UI thread.
pub struct AppState {
    // --- Window state ---
    pub windows: Vec<ManagedWindow>,
    pub custom_order: Vec<String>,
    pub displays: Vec<DisplayInfo>,

    // --- Terminal state detection ---
    pub state_detector: StateDetector,

    // --- Connection state ---
    pub ws_running: bool,
    pub ws_client_count: usize,
    pub mdns_advertising: bool,
    pub tunnel_running: bool,
    pub tunnel_url: String,
    pub tunnel_ws_url: String,

    // --- Settings ---
    pub settings: AppSettings,

    // --- Internal ---
    color_index: usize,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            windows: Vec::new(),
            custom_order: Vec::new(),
            displays: Vec::new(),
            state_detector: StateDetector::new(5.0),
            ws_running: false,
            ws_client_count: 0,
            mdns_advertising: false,
            tunnel_running: false,
            tunnel_url: String::new(),
            tunnel_ws_url: String::new(),
            settings: AppSettings::load(),
            color_index: 0,
        }
    }

    /// Refresh displays from the window backend
    pub fn refresh_displays(&mut self, backend: &dyn WindowBackend) {
        match backend.list_displays() {
            Ok(displays) => self.displays = displays,
            Err(e) => tracing::warn!("Failed to refresh displays: {e}"),
        }
    }

    /// Refresh window list from the window backend, preserving existing state
    pub fn refresh_windows(&mut self, backend: &dyn WindowBackend) {
        let raw_windows = match backend.list_windows() {
            Ok(w) => w,
            Err(e) => {
                tracing::warn!("Failed to refresh windows: {e}");
                return;
            }
        };

        let mut refreshed = Vec::new();

        for raw in &raw_windows {
            let window_id = format!("{}.{}", raw.app_class, raw.window_id);

            if let Some(existing) = self.windows.iter().find(|w| w.id == window_id) {
                // Preserve existing state
                refreshed.push(ManagedWindow {
                    id: window_id,
                    name: raw.title.clone(),
                    app: raw.app_name.clone(),
                    subtitle: existing.subtitle.clone(),
                    app_class: raw.app_class.clone(),
                    is_enabled: existing.is_enabled,
                    assigned_color: existing.assigned_color.clone(),
                    pid: raw.pid,
                    window_id: raw.window_id,
                    bounds: raw.bounds,
                });
            } else {
                refreshed.push(ManagedWindow {
                    id: window_id,
                    name: raw.title.clone(),
                    app: raw.app_name.clone(),
                    subtitle: String::new(),
                    app_class: raw.app_class.clone(),
                    is_enabled: false,
                    assigned_color: self.assign_color().to_string(),
                    pid: raw.pid,
                    window_id: raw.window_id,
                    bounds: raw.bounds,
                });
            }
        }

        // Sort by custom order
        if !self.custom_order.is_empty() {
            let mut ordered = Vec::new();
            for id in &self.custom_order {
                if let Some(w) = refreshed.iter().find(|w| &w.id == id) {
                    ordered.push(w.clone());
                }
            }
            for w in &refreshed {
                if !self.custom_order.contains(&w.id) {
                    ordered.push(w.clone());
                    self.custom_order.push(w.id.clone());
                }
            }
            let active_ids: std::collections::HashSet<_> = refreshed.iter().map(|w| &w.id).collect();
            self.custom_order.retain(|id| active_ids.contains(id));
            self.windows = ordered;
        } else {
            self.custom_order = refreshed.iter().map(|w| w.id.clone()).collect();
            self.windows = refreshed;
        }

        // Auto-track terminal windows for state detection
        self.update_tracking();
    }

    /// Refresh subtitle info (extract directory from window titles)
    pub fn refresh_subtitles(&mut self) {
        for window in &mut self.windows {
            // Many terminals put the directory in the title
            // Common formats: "user@host:~/dir", "~/dir - terminal", "dir — zsh"
            let name = &window.name;
            if let Some(dir) = extract_directory_from_title(name) {
                window.subtitle = dir;
            }
        }
    }

    /// Build a LayoutUpdate message for broadcasting
    pub fn build_layout_update(&self) -> LayoutUpdate {
        let display = self.displays.iter().find(|d| d.is_primary)
            .or_else(|| self.displays.first());
        let screen_bounds = display
            .map(|d| d.frame)
            .unwrap_or(Rect { x: 0, y: 0, width: 1920, height: 1080 });

        let states: Vec<WindowState> = self.windows.iter()
            .filter(|w| w.is_enabled)
            .map(|w| {
                let state = self.state_detector.get_state(&w.id)
                    .unwrap_or(TerminalState::Neutral);
                w.to_window_state(state.as_str(), &screen_bounds)
            })
            .collect();

        let monitor_name = display.map(|d| d.name.clone()).unwrap_or_else(|| "Display 1".into());
        LayoutUpdate::new(monitor_name, states)
    }

    /// Toggle window enabled state
    pub fn toggle_window(&mut self, window_id: &str, enabled: bool) {
        if let Some(w) = self.windows.iter_mut().find(|w| w.id == window_id) {
            w.is_enabled = enabled;
        }
    }

    /// Focus a window
    pub fn focus_window(&self, window_id: &str, backend: &dyn WindowBackend) {
        if let Some(w) = self.windows.iter().find(|w| w.id == window_id) {
            if let Err(e) = backend.focus_window(w.window_id) {
                tracing::warn!("Failed to focus window {}: {e}", window_id);
            }
        }
    }

    /// Get enabled windows
    pub fn enabled_windows(&self) -> Vec<&ManagedWindow> {
        self.windows.iter().filter(|w| w.is_enabled).collect()
    }

    fn assign_color(&mut self) -> &str {
        let color = COLOR_PALETTE[self.color_index % COLOR_PALETTE.len()];
        self.color_index += 1;
        color
    }

    fn update_tracking(&mut self) {
        // Track all windows by their PID for state detection
        let current_ids: std::collections::HashSet<String> =
            self.windows.iter().map(|w| w.id.clone()).collect();

        // Remove stale
        let stale: Vec<String> = self.state_detector.tracked_ids()
            .filter(|id| !current_ids.contains(*id))
            .map(|s| s.to_string())
            .collect();
        for id in stale {
            self.state_detector.untrack(&id);
        }

        // Add new
        for window in &self.windows {
            if !self.state_detector.is_tracked(&window.id) {
                self.state_detector.track(&window.id, window.pid);
            }
        }
    }
}

pub type SharedState = Arc<RwLock<AppState>>;

pub fn new_shared_state() -> SharedState {
    Arc::new(RwLock::new(AppState::new()))
}

/// Try to extract a directory name from a terminal window title
fn extract_directory_from_title(title: &str) -> Option<String> {
    // Format: "user@host:~/Projects/foo"
    if let Some(colon_pos) = title.find(':') {
        let path_part = &title[colon_pos + 1..];
        let path = path_part.split_whitespace().next().unwrap_or(path_part);
        if let Some(last_slash) = path.rfind('/') {
            let dir = &path[last_slash + 1..];
            if !dir.is_empty() {
                return Some(dir.to_string());
            }
        }
    }

    // Format: "dirname — zsh" or "dirname - terminal"
    for sep in &[" — ", " - ", " – "] {
        if let Some(pos) = title.find(sep) {
            let candidate = title[..pos].trim();
            if !candidate.is_empty() && !candidate.contains(' ') {
                return Some(candidate.to_string());
            }
        }
    }

    None
}
