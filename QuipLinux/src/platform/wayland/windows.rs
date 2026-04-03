use std::process::Command;

use crate::platform::traits::{
    is_terminal_class, DisplayInfo, PlatformError, PlatformResult, RawWindowInfo, WindowBackend,
};
use crate::protocol::types::Rect;

pub struct WaylandWindowBackend {
    is_sway: bool,
    is_hyprland: bool,
}

impl WaylandWindowBackend {
    pub fn new() -> Self {
        let is_sway = std::env::var("SWAYSOCK").is_ok();
        let is_hyprland = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").is_ok();
        Self {
            is_sway,
            is_hyprland,
        }
    }

    /// Recursively collect terminal windows from the sway IPC tree.
    fn collect_sway_windows(node: &serde_json::Value, out: &mut Vec<RawWindowInfo>) {
        // A "con" node with an app_id or window_properties is a leaf window.
        let node_type = node["type"].as_str().unwrap_or("");
        if node_type == "con" || node_type == "floating_con" {
            // Native Wayland windows have app_id; Xwayland windows have window_properties.class.
            let app_id = node["app_id"]
                .as_str()
                .unwrap_or("")
                .to_string();
            let xwayland_class = node["window_properties"]["class"]
                .as_str()
                .unwrap_or("")
                .to_string();

            let class = if !app_id.is_empty() {
                app_id.clone()
            } else {
                xwayland_class.clone()
            };

            // Only include terminal windows that have an actual class.
            if !class.is_empty() && is_terminal_class(&class) {
                let id = node["id"].as_u64().unwrap_or(0);
                let name = node["name"].as_str().unwrap_or("").to_string();
                let pid = node["pid"].as_u64().unwrap_or(0) as u32;
                let rect = &node["rect"];
                let x = rect["x"].as_i64().unwrap_or(0) as i32;
                let y = rect["y"].as_i64().unwrap_or(0) as i32;
                let w = rect["width"].as_u64().unwrap_or(0) as u32;
                let h = rect["height"].as_u64().unwrap_or(0) as u32;

                out.push(RawWindowInfo {
                    window_id: id,
                    title: name,
                    app_name: class.clone(),
                    app_class: class,
                    pid,
                    bounds: Rect {
                        x,
                        y,
                        width: w,
                        height: h,
                    },
                });
            }
        }

        // Recurse into child nodes and floating_nodes.
        if let Some(nodes) = node["nodes"].as_array() {
            for child in nodes {
                Self::collect_sway_windows(child, out);
            }
        }
        if let Some(nodes) = node["floating_nodes"].as_array() {
            for child in nodes {
                Self::collect_sway_windows(child, out);
            }
        }
    }

    fn list_windows_sway(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        let output = Command::new("swaymsg")
            .args(["-t", "get_tree", "-r"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("swaymsg get_tree: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "swaymsg get_tree failed: {stderr}"
            )));
        }

        let tree: serde_json::Value = serde_json::from_slice(&output.stdout)
            .map_err(|e| PlatformError::Other(format!("failed to parse sway tree: {e}")))?;

        let mut windows = Vec::new();
        Self::collect_sway_windows(&tree, &mut windows);
        Ok(windows)
    }

    fn list_windows_hyprland(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        let output = Command::new("hyprctl")
            .args(["clients", "-j"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("hyprctl clients: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "hyprctl clients failed: {stderr}"
            )));
        }

        let clients: serde_json::Value = serde_json::from_slice(&output.stdout)
            .map_err(|e| PlatformError::Other(format!("failed to parse hyprctl clients: {e}")))?;

        let arr = clients
            .as_array()
            .ok_or_else(|| PlatformError::Other("hyprctl clients: expected array".into()))?;

        let mut windows = Vec::new();
        for client in arr {
            let class = client["class"].as_str().unwrap_or("").to_string();
            if class.is_empty() || !is_terminal_class(&class) {
                continue;
            }

            // Hyprland address is a hex string like "0x5678abcd"; parse the numeric part.
            let addr_str = client["address"].as_str().unwrap_or("0x0");
            let addr = u64::from_str_radix(addr_str.trim_start_matches("0x"), 16).unwrap_or(0);

            let title = client["title"].as_str().unwrap_or("").to_string();
            let pid = client["pid"].as_u64().unwrap_or(0) as u32;

            let at = client["at"].as_array();
            let size = client["size"].as_array();
            let x = at.and_then(|a| a.first()?.as_i64()).unwrap_or(0) as i32;
            let y = at.and_then(|a| a.get(1)?.as_i64()).unwrap_or(0) as i32;
            let w = size.and_then(|a| a.first()?.as_u64()).unwrap_or(0) as u32;
            let h = size.and_then(|a| a.get(1)?.as_u64()).unwrap_or(0) as u32;

            windows.push(RawWindowInfo {
                window_id: addr,
                title,
                app_name: class.clone(),
                app_class: class,
                pid,
                bounds: Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                },
            });
        }

        Ok(windows)
    }

    fn list_displays_sway(&self) -> PlatformResult<Vec<DisplayInfo>> {
        let output = Command::new("swaymsg")
            .args(["-t", "get_outputs", "-r"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("swaymsg get_outputs: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "swaymsg get_outputs failed: {stderr}"
            )));
        }

        let outputs: serde_json::Value = serde_json::from_slice(&output.stdout)
            .map_err(|e| PlatformError::Other(format!("failed to parse sway outputs: {e}")))?;

        let arr = outputs
            .as_array()
            .ok_or_else(|| PlatformError::Other("sway outputs: expected array".into()))?;

        let mut displays = Vec::new();
        for out in arr {
            let active = out["active"].as_bool().unwrap_or(false);
            if !active {
                continue;
            }

            let name = out["name"].as_str().unwrap_or("unknown").to_string();
            let focused = out["focused"].as_bool().unwrap_or(false);
            let rect = &out["rect"];
            let x = rect["x"].as_i64().unwrap_or(0) as i32;
            let y = rect["y"].as_i64().unwrap_or(0) as i32;
            let w = rect["width"].as_u64().unwrap_or(0) as u32;
            let h = rect["height"].as_u64().unwrap_or(0) as u32;

            displays.push(DisplayInfo {
                id: name.clone(),
                name,
                frame: Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                },
                is_primary: focused,
            });
        }

        Ok(displays)
    }

    fn list_displays_hyprland(&self) -> PlatformResult<Vec<DisplayInfo>> {
        let output = Command::new("hyprctl")
            .args(["monitors", "-j"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("hyprctl monitors: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "hyprctl monitors failed: {stderr}"
            )));
        }

        let monitors: serde_json::Value = serde_json::from_slice(&output.stdout)
            .map_err(|e| PlatformError::Other(format!("failed to parse hyprctl monitors: {e}")))?;

        let arr = monitors
            .as_array()
            .ok_or_else(|| PlatformError::Other("hyprctl monitors: expected array".into()))?;

        let mut displays = Vec::new();
        for mon in arr {
            let name = mon["name"].as_str().unwrap_or("unknown").to_string();
            let focused = mon["focused"].as_bool().unwrap_or(false);
            let x = mon["x"].as_i64().unwrap_or(0) as i32;
            let y = mon["y"].as_i64().unwrap_or(0) as i32;
            let w = mon["width"].as_u64().unwrap_or(0) as u32;
            let h = mon["height"].as_u64().unwrap_or(0) as u32;

            displays.push(DisplayInfo {
                id: name.clone(),
                name,
                frame: Rect {
                    x,
                    y,
                    width: w,
                    height: h,
                },
                is_primary: focused,
            });
        }

        Ok(displays)
    }
}

impl WindowBackend for WaylandWindowBackend {
    fn list_windows(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        if self.is_sway {
            return self.list_windows_sway();
        }
        if self.is_hyprland {
            return self.list_windows_hyprland();
        }
        tracing::warn!("no supported Wayland compositor detected (need sway or Hyprland)");
        Ok(Vec::new())
    }

    fn list_displays(&self) -> PlatformResult<Vec<DisplayInfo>> {
        if self.is_sway {
            return self.list_displays_sway();
        }
        if self.is_hyprland {
            return self.list_displays_hyprland();
        }
        tracing::warn!("no supported Wayland compositor detected for display enumeration");
        Ok(Vec::new())
    }

    fn focus_window(&self, window_id: u64) -> PlatformResult<()> {
        if self.is_sway {
            let arg = format!("[con_id={window_id}] focus");
            let output = Command::new("swaymsg")
                .arg(&arg)
                .output()
                .map_err(|e| PlatformError::CommandFailed(format!("swaymsg focus: {e}")))?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(PlatformError::CommandFailed(format!(
                    "swaymsg focus failed: {stderr}"
                )));
            }
            return Ok(());
        }
        if self.is_hyprland {
            let arg = format!("focuswindow address:0x{window_id:x}");
            let output = Command::new("hyprctl")
                .args(["dispatch", &arg])
                .output()
                .map_err(|e| PlatformError::CommandFailed(format!("hyprctl focus: {e}")))?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(PlatformError::CommandFailed(format!(
                    "hyprctl focus failed: {stderr}"
                )));
            }
            return Ok(());
        }
        Err(PlatformError::NotAvailable(
            "no supported Wayland compositor for focus_window".into(),
        ))
    }

    fn move_resize_window(
        &self,
        window_id: u64,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
    ) -> PlatformResult<()> {
        if self.is_sway {
            // Chain: enable floating, move to position, then resize.
            let cmd = format!(
                "[con_id={wid}] floating enable; \
                 [con_id={wid}] move position {x} {y}; \
                 [con_id={wid}] resize set {w} {h}",
                wid = window_id,
                x = x,
                y = y,
                w = w,
                h = h,
            );
            let output = Command::new("swaymsg")
                .arg(&cmd)
                .output()
                .map_err(|e| {
                    PlatformError::CommandFailed(format!("swaymsg move_resize: {e}"))
                })?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(PlatformError::CommandFailed(format!(
                    "swaymsg move_resize failed: {stderr}"
                )));
            }
            return Ok(());
        }
        if self.is_hyprland {
            let addr = format!("address:0x{window_id:x}");
            // Move window to exact pixel position.
            let move_arg = format!("exact {x} {y},{addr}");
            let output = Command::new("hyprctl")
                .args(["dispatch", "movewindowpixel", &move_arg])
                .output()
                .map_err(|e| {
                    PlatformError::CommandFailed(format!("hyprctl movewindowpixel: {e}"))
                })?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(PlatformError::CommandFailed(format!(
                    "hyprctl movewindowpixel failed: {stderr}"
                )));
            }
            // Resize window to exact pixel dimensions.
            let resize_arg = format!("exact {w} {h},{addr}");
            let output = Command::new("hyprctl")
                .args(["dispatch", "resizewindowpixel", &resize_arg])
                .output()
                .map_err(|e| {
                    PlatformError::CommandFailed(format!("hyprctl resizewindowpixel: {e}"))
                })?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                return Err(PlatformError::CommandFailed(format!(
                    "hyprctl resizewindowpixel failed: {stderr}"
                )));
            }
            return Ok(());
        }
        Err(PlatformError::NotAvailable(
            "no supported Wayland compositor for move_resize_window".into(),
        ))
    }
}
