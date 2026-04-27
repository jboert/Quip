use std::collections::HashMap;
use std::process::Command;
use std::sync::Mutex;

use crate::platform::traits::{
    is_terminal_class, DisplayInfo, PlatformError, PlatformResult, RawWindowInfo, WindowBackend,
};
use crate::protocol::types::Rect;

/// X11 window backend using `wmctrl` and `xdotool` subprocesses.
pub struct X11WindowBackend {
    /// Cache of window id -> WM_CLASS to avoid repeated xprop calls.
    wm_class_cache: Mutex<HashMap<u64, String>>,
}

impl X11WindowBackend {
    pub fn new() -> Self {
        Self {
            wm_class_cache: Mutex::new(HashMap::new()),
        }
    }

    /// Look up the WM_CLASS for a window, using the cache when available.
    fn get_wm_class(&self, window_id: u64) -> PlatformResult<String> {
        // Check cache first.
        {
            let cache = self.wm_class_cache.lock().map_err(|e| {
                PlatformError::Other(format!("failed to lock wm_class cache: {e}"))
            })?;
            if let Some(class) = cache.get(&window_id) {
                return Ok(class.clone());
            }
        }

        let wid_hex = format!("0x{window_id:x}");
        let output = Command::new("xprop")
            .args(["-id", &wid_hex, "WM_CLASS"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xprop: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xprop exited with {}",
                output.status
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        // Format: WM_CLASS(STRING) = "instance", "class"
        let class = parse_wm_class(&stdout);

        let mut cache = self.wm_class_cache.lock().map_err(|e| {
            PlatformError::Other(format!("failed to lock wm_class cache: {e}"))
        })?;
        cache.insert(window_id, class.clone());

        Ok(class)
    }
}

/// Parse WM_CLASS from xprop output.
/// Input format: `WM_CLASS(STRING) = "instance", "class"`
/// Returns the class name (second value), or the instance name if only one is present.
fn parse_wm_class(line: &str) -> String {
    let Some((_prefix, values)) = line.split_once('=') else {
        return String::new();
    };
    let parts: Vec<&str> = values.split(',').collect();
    // Prefer the second value (class name) over the first (instance name).
    let raw = if parts.len() >= 2 { parts[1] } else { parts[0] };
    raw.trim().trim_matches('"').to_string()
}

/// Parse a hex window id (with or without 0x prefix) into a u64.
fn parse_window_id(s: &str) -> Option<u64> {
    let s = s.strip_prefix("0x").unwrap_or(s);
    u64::from_str_radix(s, 16).ok()
}

/// Current desktop number, or None if `wmctrl -d` is unavailable. Output
/// of `wmctrl -d` flags the active desktop with a `*` in column 2.
fn current_x11_desktop() -> Option<i32> {
    let output = Command::new("wmctrl").arg("-d").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    for line in stdout.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() >= 2 && fields[1] == "*" {
            return fields[0].parse().ok();
        }
    }
    None
}

#[cfg(test)]
mod parse_tests {
    use super::*;

    #[test]
    fn parses_wm_class_two_values() {
        assert_eq!(parse_wm_class(r#"WM_CLASS(STRING) = "konsole", "konsole""#), "konsole");
    }

    #[test]
    fn parses_wm_class_one_value() {
        // Some apps only set one value; we fall back to it.
        assert_eq!(parse_wm_class(r#"WM_CLASS(STRING) = "kitty""#), "kitty");
    }
}

impl WindowBackend for X11WindowBackend {
    fn list_windows(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        let output = Command::new("wmctrl")
            .args(["-l", "-G", "-p"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("wmctrl -l -G -p: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "wmctrl exited with {}",
                output.status
            )));
        }

        // Active desktop number — used to flag which windows are on the
        // current workspace. wmctrl prints it with `*` next to the active
        // line; -1 means "sticky" (visible on every desktop) and counts as
        // visible too. Best-effort — falls back to "everything visible"
        // if wmctrl -d is unavailable.
        let active_desktop = current_x11_desktop();

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut windows = Vec::new();

        for line in stdout.lines() {
            // wmctrl -l -G -p columns: wid desktop pid x y w h hostname title...
            let fields: Vec<&str> = line.split_whitespace().collect();
            if fields.len() < 9 {
                continue;
            }

            let Some(window_id) = parse_window_id(fields[0]) else {
                continue;
            };
            let desktop: i32 = fields[1].parse().unwrap_or(-1);
            let pid: u32 = fields[2].parse().unwrap_or(0);
            let x: i32 = fields[3].parse().unwrap_or(0);
            let y: i32 = fields[4].parse().unwrap_or(0);
            let w: u32 = fields[5].parse().unwrap_or(0);
            let h: u32 = fields[6].parse().unwrap_or(0);
            // Everything after the 8th field (hostname) is the window title.
            let title = if fields.len() > 8 {
                fields[8..].join(" ")
            } else {
                String::new()
            };

            let wm_class = match self.get_wm_class(window_id) {
                Ok(c) => c,
                Err(_) => continue,
            };

            // Visible iff sticky (desktop == -1) or on the active desktop.
            // If we couldn't determine the active desktop, default to true.
            let is_on_visible_screen = match active_desktop {
                Some(active) => desktop == -1 || desktop == active,
                None => true,
            };

            windows.push(RawWindowInfo {
                window_id,
                title,
                app_name: wm_class.clone(),
                app_class: wm_class,
                pid,
                bounds: Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                },
                is_on_visible_screen,
            });
        }

        Ok(windows)
    }

    fn list_displays(&self) -> PlatformResult<Vec<DisplayInfo>> {
        let output = Command::new("xrandr")
            .arg("--query")
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xrandr: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xrandr exited with {}",
                output.status
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut displays = Vec::new();

        for line in stdout.lines() {
            // Look for lines like: "eDP-1 connected primary 1920x1080+0+0 ..."
            // or: "HDMI-1 connected 2560x1440+1920+0 ..."
            if !line.contains(" connected") {
                continue;
            }

            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 3 {
                continue;
            }

            let name = parts[0].to_string();
            let is_primary = parts.contains(&"primary");

            // Find the geometry token (WxH+X+Y).
            let geometry = parts.iter().find(|p| {
                p.contains('x') && p.contains('+')
            });

            let Some(geom) = geometry else {
                continue;
            };

            let Some(rect) = parse_geometry(geom) else {
                continue;
            };

            displays.push(DisplayInfo {
                id: name.clone(),
                name,
                frame: rect,
                is_primary,
            });
        }

        Ok(displays)
    }

    fn focus_window(&self, window_id: u64) -> PlatformResult<()> {
        let wid_str = window_id.to_string();
        let output = Command::new("xdotool")
            .args(["windowactivate", "--sync", &wid_str])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xdotool windowactivate: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::WindowNotFound(window_id));
        }

        Ok(())
    }

    fn move_resize_window(
        &self,
        window_id: u64,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
    ) -> PlatformResult<()> {
        let wid_hex = format!("0x{window_id:x}");
        let wid_str = window_id.to_string();

        // Remove decorations and maximized state via wmctrl so we can freely position.
        let _ = Command::new("wmctrl")
            .args([
                "-i",
                "-r",
                &wid_hex,
                "-b",
                "remove,maximized_vert,maximized_horz",
            ])
            .output();

        // Resize.
        let output = Command::new("xdotool")
            .args(["windowsize", &wid_str, &w.to_string(), &h.to_string()])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xdotool windowsize: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xdotool windowsize failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        // Move.
        let output = Command::new("xdotool")
            .args(["windowmove", &wid_str, &x.to_string(), &y.to_string()])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xdotool windowmove: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xdotool windowmove failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        Ok(())
    }
}

/// Parse an xrandr geometry string like "1920x1080+0+0" into a Rect.
fn parse_geometry(geom: &str) -> Option<Rect> {
    // Format: WxH+X+Y
    let (wh, rest) = geom.split_once('+')?;
    let (w_str, h_str) = wh.split_once('x')?;
    let (x_str, y_str) = rest.split_once('+')?;

    Some(Rect {
        x: x_str.parse().ok()?,
        y: y_str.parse().ok()?,
        width: w_str.parse().ok()?,
        height: h_str.parse().ok()?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_wm_class() {
        assert_eq!(
            parse_wm_class(r#"WM_CLASS(STRING) = "kitty", "kitty""#),
            "kitty"
        );
        assert_eq!(
            parse_wm_class(r#"WM_CLASS(STRING) = "alacritty", "Alacritty""#),
            "Alacritty"
        );
        assert_eq!(parse_wm_class(""), "");
    }

    #[test]
    fn test_parse_geometry() {
        let rect = parse_geometry("1920x1080+0+0").unwrap();
        assert_eq!(rect.x, 0);
        assert_eq!(rect.y, 0);
        assert_eq!(rect.width, 1920);
        assert_eq!(rect.height, 1080);

        let rect = parse_geometry("2560x1440+1920+0").unwrap();
        assert_eq!(rect.x, 1920);
        assert_eq!(rect.y, 0);
        assert_eq!(rect.width, 2560);
        assert_eq!(rect.height, 1440);
    }

    #[test]
    fn test_parse_window_id() {
        assert_eq!(parse_window_id("0x04000004"), Some(0x04000004));
        assert_eq!(parse_window_id("04000004"), Some(0x04000004));
    }
}
