use std::process::Command;
use std::thread;
use std::time::Duration;

use crate::platform::traits::{InputBackend, PlatformError, PlatformResult};

/// Which tool to use for synthetic input on Wayland.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InputTool {
    Ydotool,
    Wtype,
}

/// Detected Wayland compositor type (mirrors the one in windows.rs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Compositor {
    Sway,
    Hyprland,
    Kde,
    Gnome,
    Unknown,
}

pub struct WaylandInputBackend {
    tool: Option<InputTool>,
    compositor: Compositor,
}

impl WaylandInputBackend {
    pub fn new() -> Self {
        let compositor = Self::detect_compositor();

        let tool = if Self::is_in_path("ydotool") {
            Some(InputTool::Ydotool)
        } else if Self::is_in_path("wtype") {
            Some(InputTool::Wtype)
        } else {
            None
        };

        Self { tool, compositor }
    }

    fn detect_compositor() -> Compositor {
        if std::env::var("SWAYSOCK").is_ok() {
            return Compositor::Sway;
        }
        if std::env::var("HYPRLAND_INSTANCE_SIGNATURE").is_ok() {
            return Compositor::Hyprland;
        }
        let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_uppercase();
        if desktop.contains("KDE") {
            return Compositor::Kde;
        }
        if desktop.contains("GNOME") {
            return Compositor::Gnome;
        }
        Compositor::Unknown
    }

    fn is_in_path(program: &str) -> bool {
        Command::new("which")
            .arg(program)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn tool(&self) -> PlatformResult<InputTool> {
        self.tool.ok_or_else(|| {
            PlatformError::NotAvailable(
                "no input tool available; install ydotool or wtype".into(),
            )
        })
    }

    /// Focus a window by id before injecting input.
    fn focus(&self, window_id: u64) -> PlatformResult<()> {
        match self.compositor {
            Compositor::Sway => {
                let arg = format!("[con_id={window_id}] focus");
                Self::run_cmd("swaymsg", &[&arg], "swaymsg focus")
            }
            Compositor::Hyprland => {
                let arg = format!("focuswindow address:0x{window_id:x}");
                Self::run_cmd("hyprctl", &["dispatch", &arg], "hyprctl focus")
            }
            Compositor::Kde => {
                let kde_id = super::windows::kde_id_from_hash(window_id);
                Self::run_cmd("kdotool", &["windowactivate", &kde_id], "kdotool windowactivate")
            }
            Compositor::Gnome => {
                let script = format!(
                    "global.get_window_actors().forEach(a => {{ \
                        if (a.meta_window.get_id() == {window_id}) \
                            a.meta_window.activate(global.get_current_time()); \
                    }})"
                );
                Self::run_cmd("gdbus", &[
                    "call", "--session",
                    "--dest", "org.gnome.Shell",
                    "--object-path", "/org/gnome/Shell",
                    "--method", "org.gnome.Shell.Eval",
                    &script,
                ], "gdbus Eval focus")
            }
            Compositor::Unknown => {
                Err(PlatformError::NotAvailable(
                    "no supported Wayland compositor for window focus".into(),
                ))
            }
        }
    }

    fn run_cmd(program: &str, args: &[&str], context: &str) -> PlatformResult<()> {
        let output = Command::new(program)
            .args(args)
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("{context}: {e}")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "{context} failed: {stderr}"
            )));
        }
        Ok(())
    }

    /// Small delay to let the compositor finish focus switch before typing.
    fn focus_delay() {
        thread::sleep(Duration::from_millis(50));
    }

    /// Map a logical key name to the representation expected by ydotool.
    fn map_key_ydotool(key: &str) -> String {
        match key.to_lowercase().as_str() {
            "return" | "enter" => "enter".to_string(),
            other => other.to_string(),
        }
    }

    /// Map a logical key name to wtype arguments.
    ///
    /// Returns a list of arguments to pass to wtype. For modifier combos like
    /// "ctrl+c" this becomes ["-M", "ctrl", "-k", "c"].
    fn map_key_wtype(key: &str) -> Vec<String> {
        let lower = key.to_lowercase();
        let special = match lower.as_str() {
            "return" | "enter" => return vec!["-k".into(), "Return".into()],
            _ => &lower,
        };

        if let Some(idx) = special.rfind('+') {
            let modifier = &special[..idx];
            let base = &special[idx + 1..];
            vec![
                "-M".into(),
                modifier.to_string(),
                "-k".into(),
                base.to_string(),
            ]
        } else {
            vec!["-k".into(), special.to_string()]
        }
    }
}

impl InputBackend for WaylandInputBackend {
    fn send_text(
        &self,
        window_id: u64,
        text: &str,
        press_return: bool,
    ) -> PlatformResult<()> {
        let tool = self.tool()?;
        self.focus(window_id)?;
        Self::focus_delay();

        match tool {
            InputTool::Ydotool => {
                let output = Command::new("ydotool")
                    .args(["type", text])
                    .output()
                    .map_err(|e| {
                        PlatformError::CommandFailed(format!("ydotool type: {e}"))
                    })?;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(PlatformError::CommandFailed(format!(
                        "ydotool type failed: {stderr}"
                    )));
                }
                if press_return {
                    let output = Command::new("ydotool")
                        .args(["key", "enter"])
                        .output()
                        .map_err(|e| {
                            PlatformError::CommandFailed(format!("ydotool key enter: {e}"))
                        })?;
                    if !output.status.success() {
                        let stderr = String::from_utf8_lossy(&output.stderr);
                        return Err(PlatformError::CommandFailed(format!(
                            "ydotool key enter failed: {stderr}"
                        )));
                    }
                }
            }
            InputTool::Wtype => {
                let output = Command::new("wtype")
                    .arg(text)
                    .output()
                    .map_err(|e| {
                        PlatformError::CommandFailed(format!("wtype: {e}"))
                    })?;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(PlatformError::CommandFailed(format!(
                        "wtype failed: {stderr}"
                    )));
                }
                if press_return {
                    let output = Command::new("wtype")
                        .args(["-k", "Return"])
                        .output()
                        .map_err(|e| {
                            PlatformError::CommandFailed(format!("wtype -k Return: {e}"))
                        })?;
                    if !output.status.success() {
                        let stderr = String::from_utf8_lossy(&output.stderr);
                        return Err(PlatformError::CommandFailed(format!(
                            "wtype Return failed: {stderr}"
                        )));
                    }
                }
            }
        }

        Ok(())
    }

    fn send_keystroke(&self, window_id: u64, key: &str) -> PlatformResult<()> {
        let tool = self.tool()?;
        self.focus(window_id)?;
        Self::focus_delay();

        match tool {
            InputTool::Ydotool => {
                let mapped = Self::map_key_ydotool(key);
                let output = Command::new("ydotool")
                    .args(["key", &mapped])
                    .output()
                    .map_err(|e| {
                        PlatformError::CommandFailed(format!("ydotool key: {e}"))
                    })?;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(PlatformError::CommandFailed(format!(
                        "ydotool key failed: {stderr}"
                    )));
                }
            }
            InputTool::Wtype => {
                let args = Self::map_key_wtype(key);
                let output = Command::new("wtype")
                    .args(&args)
                    .output()
                    .map_err(|e| {
                        PlatformError::CommandFailed(format!("wtype: {e}"))
                    })?;
                if !output.status.success() {
                    let stderr = String::from_utf8_lossy(&output.stderr);
                    return Err(PlatformError::CommandFailed(format!(
                        "wtype keystroke failed: {stderr}"
                    )));
                }
            }
        }

        Ok(())
    }

    fn spawn_terminal(&self, terminal: &str, directory: &str) -> PlatformResult<()> {
        Command::new(terminal)
            .current_dir(directory)
            .spawn()
            .map_err(|e| {
                PlatformError::CommandFailed(format!("spawn terminal '{terminal}': {e}"))
            })?;
        Ok(())
    }
}
