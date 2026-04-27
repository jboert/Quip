use std::collections::HashMap;
use std::process::Command;
use std::sync::RwLock;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::platform::traits::{
    DisplayInfo, PlatformError, PlatformResult, RawWindowInfo, WindowBackend,
};
use crate::protocol::types::Rect;

fn is_in_path(program: &str) -> bool {
    Command::new("which").arg(program).output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Global mapping from hashed u64 IDs back to KDE UUID strings.
/// kdotool uses UUIDs like {xxx-xxx} but our trait uses u64 window IDs.
static KDE_ID_MAP: std::sync::LazyLock<RwLock<HashMap<u64, String>>> =
    std::sync::LazyLock::new(|| RwLock::new(HashMap::new()));

/// Look up the original KDE UUID string from a hashed u64 window ID.
pub fn kde_id_from_hash(hash: u64) -> String {
    KDE_ID_MAP
        .read()
        .unwrap()
        .get(&hash)
        .cloned()
        .unwrap_or_default()
}

/// Detected Wayland compositor type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Compositor {
    Sway,
    Hyprland,
    Kde,
    Gnome,
    Unknown,
}

pub struct WaylandWindowBackend {
    compositor: Compositor,
}

impl WaylandWindowBackend {
    pub fn new() -> Self {
        let compositor = Self::detect_compositor();
        tracing::info!("Detected Wayland compositor: {:?}", compositor);
        Self { compositor }
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

            if class.is_empty() {
                return;
            }

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
                // Wayland compositors generally hide off-workspace windows
                // from list APIs already; default true and let the filter
                // logic on the broadcast side trust that.
                is_on_visible_screen: true,
            });
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
            if class.is_empty() {
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
                is_on_visible_screen: true,
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

    // ── KDE — try kdotool, fall back to KWin scripting via D-Bus ──────

    fn list_windows_kde(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        // Try kdotool first (fast, if installed)
        if is_in_path("kdotool") {
            return self.list_windows_kdotool();
        }
        // Fall back to KWin scripting via D-Bus (no external tools needed)
        self.list_windows_kwin_script()
    }

    fn list_windows_kdotool(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        let output = Command::new("kdotool")
            .args(["search", ""])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("kdotool search: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "kdotool search failed: {stderr}"
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut windows = Vec::new();

        for id_str in stdout.lines() {
            let id_str = id_str.trim();
            if id_str.is_empty() {
                continue;
            }
            let window_id = Self::hash_kde_id(id_str);
            KDE_ID_MAP.write().unwrap().insert(window_id, id_str.to_string());

            let title = Self::kdotool_get(id_str, "getwindowname").unwrap_or_default();
            let class = Self::kdotool_get(id_str, "getwindowclassname").unwrap_or_default();
            let pid: u32 = Self::kdotool_get(id_str, "getwindowpid")
                .and_then(|s| s.parse().ok())
                .unwrap_or(0);
            let bounds = Self::kdotool_get_geometry(id_str).unwrap_or(Rect {
                x: 0, y: 0, width: 0, height: 0,
            });

            if class.is_empty() {
                continue;
            }

            windows.push(RawWindowInfo {
                window_id,
                title,
                app_name: class.clone(),
                app_class: class,
                pid,
                bounds,
                is_on_visible_screen: true,
            });
        }

        Ok(windows)
    }

    /// Enumerate windows using KWin's built-in scripting API via D-Bus.
    /// This works on any KDE Plasma installation without extra tools.
    fn list_windows_kwin_script(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        // Generate a unique marker so we can find our output in the journal
        let marker = format!("QUIP_ENUM_{}", SystemTime::now()
            .duration_since(UNIX_EPOCH).unwrap_or_default().as_millis());

        // Write a temporary KWin script that dumps window info via console.info
        let script = format!(
            r#"(function() {{
    var clients = workspace.windowList();
    var lines = [];
    for (var i = 0; i < clients.length; i++) {{
        var c = clients[i];
        if (!c.normalWindow) continue;
        var geo = c.frameGeometry;
        lines.push(c.internalId + "\t" + c.caption + "\t" + c.resourceClass + "\t" + c.pid + "\t" + geo.x + "," + geo.y + "," + geo.width + "," + geo.height);
    }}
    console.info("{0}:" + lines.join("\\n"));
}})();"#,
            marker
        );

        let script_path = "/tmp/quip_kwin_enum.js";
        std::fs::write(script_path, &script)
            .map_err(|e| PlatformError::CommandFailed(format!("write script: {e}")))?;

        let plugin_name = format!("quip_enum_{}", std::process::id());

        // Unload any previous instance
        let _ = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   "/Scripting", "org.kde.kwin.Scripting.unloadScript",
                   &format!("string:{plugin_name}")])
            .output();

        // Load the script
        let load_output = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   "/Scripting", "org.kde.kwin.Scripting.loadScript",
                   &format!("string:{script_path}"), &format!("string:{plugin_name}")])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("dbus loadScript: {e}")))?;

        let load_stdout = String::from_utf8_lossy(&load_output.stdout);
        let script_id = load_stdout.lines()
            .filter_map(|l| l.trim().strip_prefix("int32 "))
            .next()
            .and_then(|s| s.trim().parse::<i32>().ok())
            .unwrap_or(-1);

        if script_id < 0 {
            return Err(PlatformError::CommandFailed("KWin script load failed".into()));
        }

        // Run the script
        let _ = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   &format!("/Scripting/Script{script_id}"), "org.kde.kwin.Script.run"])
            .output();

        // Small delay for script to execute and log
        std::thread::sleep(std::time::Duration::from_millis(150));

        // Read output from systemd journal
        let journal = Command::new("journalctl")
            .args(["--user", "-n", "50", "--output=cat", "--no-pager"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("journalctl: {e}")))?;

        let journal_output = String::from_utf8_lossy(&journal.stdout);

        // Unload the script
        let _ = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   "/Scripting", "org.kde.kwin.Scripting.unloadScript",
                   &format!("string:{plugin_name}")])
            .output();

        // Find our marker line. KWin's console.info outputs \n as literal
        // backslash-n in the journal, so we split on that.
        let data = journal_output.lines()
            .find_map(|line| line.strip_prefix(&format!("{marker}:")))
            .unwrap_or("");

        let mut windows = Vec::new();
        for entry in data.split("\\n") {
            let entry = entry.trim();
            if entry.is_empty() { continue; }
            let parts: Vec<&str> = entry.splitn(5, '\t').collect();
            if parts.len() < 5 { continue; }

            let kde_id = parts[0].trim();
            let title = parts[1].to_string();
            let class = parts[2].to_string();
            let pid: u32 = parts[3].parse().unwrap_or(0);

            // Parse geometry: "x,y,w,h"
            let geo_parts: Vec<&str> = parts[4].split(',').collect();
            let bounds = if geo_parts.len() == 4 {
                Rect {
                    x: geo_parts[0].parse::<f64>().unwrap_or(0.0) as i32,
                    y: geo_parts[1].parse::<f64>().unwrap_or(0.0) as i32,
                    width: geo_parts[2].parse::<f64>().unwrap_or(0.0) as u32,
                    height: geo_parts[3].parse::<f64>().unwrap_or(0.0) as u32,
                }
            } else {
                Rect { x: 0, y: 0, width: 0, height: 0 }
            };

            if class.is_empty() { continue; }

            let window_id = Self::hash_kde_id(kde_id);
            KDE_ID_MAP.write().unwrap().insert(window_id, kde_id.to_string());

            windows.push(RawWindowInfo {
                window_id,
                title,
                app_name: class.clone(),
                app_class: class,
                pid,
                bounds,
                is_on_visible_screen: true,
            });
        }

        Ok(windows)
    }

    fn kdotool_get(kde_id: &str, command: &str) -> Option<String> {
        let output = Command::new("kdotool")
            .args([command, kde_id])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if s.is_empty() { None } else { Some(s) }
    }

    fn kdotool_get_geometry(kde_id: &str) -> Option<Rect> {
        let output = Command::new("kdotool")
            .args(["getwindowgeometry", kde_id])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        // Output format:
        //   Position: X,Y
        //   Geometry: WxH
        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut x = 0i32;
        let mut y = 0i32;
        let mut w = 0u32;
        let mut h = 0u32;
        for line in stdout.lines() {
            let line = line.trim();
            if let Some(pos) = line.strip_prefix("Position:") {
                let pos = pos.trim();
                if let Some((xs, ys)) = pos.split_once(',') {
                    x = xs.trim().parse().unwrap_or(0);
                    y = ys.trim().parse().unwrap_or(0);
                }
            } else if let Some(geom) = line.strip_prefix("Geometry:") {
                let geom = geom.trim();
                if let Some((ws, hs)) = geom.split_once('x') {
                    w = ws.trim().parse().unwrap_or(0);
                    h = hs.trim().parse().unwrap_or(0);
                }
            }
        }
        Some(Rect { x, y, width: w, height: h })
    }

    /// Hash a KDE window UUID to a u64 for use as window_id.
    fn hash_kde_id(id: &str) -> u64 {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        let mut hasher = DefaultHasher::new();
        id.hash(&mut hasher);
        hasher.finish()
    }

    // ── GNOME (Window Commander extension via gdbus) ───────────────────

    fn list_windows_gnome(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        let output = Command::new("gdbus")
            .args([
                "call", "--session",
                "--dest", "org.gnome.Shell",
                "--object-path", "/org/gnome/Shell/Extensions/WindowCommander",
                "--method", "org.gnome.Shell.Extensions.WindowCommander.List",
            ])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("gdbus List: {e}")))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "Window Commander List failed (is the GNOME extension installed?): {stderr}"
            )));
        }

        // gdbus wraps the return value in parentheses: ('json_string',)
        let stdout = String::from_utf8_lossy(&output.stdout);
        let json_str = Self::extract_gdbus_string(&stdout)?;
        let arr: serde_json::Value = serde_json::from_str(&json_str)
            .map_err(|e| PlatformError::Other(format!("failed to parse Window Commander JSON: {e}")))?;

        let list = arr.as_array()
            .ok_or_else(|| PlatformError::Other("Window Commander List: expected array".into()))?;

        let mut windows = Vec::new();
        for entry in list {
            let id = entry["id"].as_u64().unwrap_or(0);
            let title = entry["title"].as_str().unwrap_or("").to_string();
            let class = entry["class"].as_str()
                .or_else(|| entry["wm_class"].as_str())
                .unwrap_or("").to_string();
            let pid = entry["pid"].as_u64().unwrap_or(0) as u32;

            if class.is_empty() {
                continue;
            }

            // Geometry may come from List or we fetch it separately.
            let bounds = if entry.get("x").is_some() {
                Rect {
                    x: entry["x"].as_i64().unwrap_or(0) as i32,
                    y: entry["y"].as_i64().unwrap_or(0) as i32,
                    width: entry["width"].as_u64().unwrap_or(0) as u32,
                    height: entry["height"].as_u64().unwrap_or(0) as u32,
                }
            } else {
                Self::gnome_get_frame_rect(id).unwrap_or(Rect {
                    x: 0, y: 0, width: 0, height: 0,
                })
            };

            windows.push(RawWindowInfo {
                window_id: id,
                title,
                app_name: class.clone(),
                app_class: class,
                pid,
                bounds,
                is_on_visible_screen: true,
            });
        }

        Ok(windows)
    }

    fn gnome_get_frame_rect(win_id: u64) -> Option<Rect> {
        let output = Command::new("gdbus")
            .args([
                "call", "--session",
                "--dest", "org.gnome.Shell",
                "--object-path", "/org/gnome/Shell/Extensions/WindowCommander",
                "--method", "org.gnome.Shell.Extensions.WindowCommander.GetFrameRect",
                &win_id.to_string(),
            ])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        let json_str = Self::extract_gdbus_string(&stdout).ok()?;
        let v: serde_json::Value = serde_json::from_str(&json_str).ok()?;
        Some(Rect {
            x: v["x"].as_i64()? as i32,
            y: v["y"].as_i64()? as i32,
            width: v["width"].as_u64()? as u32,
            height: v["height"].as_u64()? as u32,
        })
    }

    /// Extract the string payload from gdbus output like: ('json_string',)
    fn extract_gdbus_string(raw: &str) -> PlatformResult<String> {
        let trimmed = raw.trim();
        // gdbus wraps return in ('...',) — extract the inner string
        let inner = trimmed
            .strip_prefix("('").or_else(|| trimmed.strip_prefix("(\""))
            .and_then(|s| s.strip_suffix("',)").or_else(|| s.strip_suffix("\",)")))
            .unwrap_or(trimmed);
        // Unescape any escaped quotes
        Ok(inner.replace("\\'", "'").replace("\\\"", "\""))
    }

    // ── Display listing fallback (xrandr) ──────────────────────────────

    fn list_displays_xrandr(&self) -> PlatformResult<Vec<DisplayInfo>> {
        let output = Command::new("xrandr")
            .arg("--query")
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xrandr: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xrandr exited with {}", output.status
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut displays = Vec::new();

        for line in stdout.lines() {
            if !line.contains(" connected") {
                continue;
            }
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() < 3 {
                continue;
            }
            let name = parts[0].to_string();
            let is_primary = parts.contains(&"primary");

            let geometry = parts.iter().find(|p| p.contains('x') && p.contains('+'));
            let Some(geom) = geometry else { continue };
            let Some(rect) = Self::parse_xrandr_geometry(geom) else { continue };

            displays.push(DisplayInfo {
                id: name.clone(),
                name,
                frame: rect,
                is_primary,
            });
        }

        Ok(displays)
    }

    /// Run a command and return Ok(()) on success, or an error with stderr.
    fn run_command(program: &str, args: &[&str], context: &str) -> PlatformResult<()> {
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

    /// Run a one-shot KWin script via D-Bus (no output needed).
    /// Public alias for use from the input module.
    pub fn kwin_script_run_pub(script_body: &str) -> PlatformResult<()> {
        Self::kwin_script_run(script_body)
    }

    fn kwin_script_run(script_body: &str) -> PlatformResult<()> {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let seq = COUNTER.fetch_add(1, Ordering::Relaxed);

        let script_path = format!("/tmp/quip_kwin_action_{seq}.js");
        let plugin_name = format!("quip_act_{}_{seq}", std::process::id());

        std::fs::write(&script_path, script_body)
            .map_err(|e| PlatformError::CommandFailed(format!("write kwin script: {e}")))?;

        // Unload any prior instance with this name (shouldn't exist, but safety)
        let _ = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   "/Scripting", "org.kde.kwin.Scripting.unloadScript",
                   &format!("string:{plugin_name}")])
            .output();

        let load_output = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   "/Scripting", "org.kde.kwin.Scripting.loadScript",
                   &format!("string:{script_path}"),
                   &format!("string:{plugin_name}")])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("dbus loadScript: {e}")))?;

        let load_stdout = String::from_utf8_lossy(&load_output.stdout);
        let script_id = load_stdout.lines()
            .filter_map(|l| l.trim().strip_prefix("int32 "))
            .next()
            .and_then(|s| s.trim().parse::<i32>().ok())
            .unwrap_or(-1);

        if script_id < 0 {
            let _ = std::fs::remove_file(&script_path);
            return Err(PlatformError::CommandFailed("KWin script load failed".into()));
        }

        let _ = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   &format!("/Scripting/Script{script_id}"), "org.kde.kwin.Script.run"])
            .output();

        // Small delay to let script execute
        std::thread::sleep(std::time::Duration::from_millis(50));

        // Unload and clean up
        let _ = Command::new("dbus-send")
            .args(["--session", "--dest=org.kde.KWin", "--print-reply",
                   "/Scripting", "org.kde.kwin.Scripting.unloadScript",
                   &format!("string:{plugin_name}")])
            .output();
        let _ = std::fs::remove_file(&script_path);

        Ok(())
    }

    /// Parse xrandr geometry string like "1920x1080+0+0" into a Rect.
    fn parse_xrandr_geometry(geom: &str) -> Option<Rect> {
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
}

impl WindowBackend for WaylandWindowBackend {
    fn list_windows(&self) -> PlatformResult<Vec<RawWindowInfo>> {
        match self.compositor {
            Compositor::Sway => self.list_windows_sway(),
            Compositor::Hyprland => self.list_windows_hyprland(),
            Compositor::Kde => self.list_windows_kde(),
            Compositor::Gnome => self.list_windows_gnome(),
            Compositor::Unknown => {
                tracing::warn!("no supported Wayland compositor detected");
                Ok(Vec::new())
            }
        }
    }

    fn list_displays(&self) -> PlatformResult<Vec<DisplayInfo>> {
        match self.compositor {
            Compositor::Sway => self.list_displays_sway(),
            Compositor::Hyprland => self.list_displays_hyprland(),
            Compositor::Kde | Compositor::Gnome => self.list_displays_xrandr(),
            Compositor::Unknown => {
                tracing::warn!("no supported Wayland compositor detected for display enumeration");
                Ok(Vec::new())
            }
        }
    }

    fn focus_window(&self, window_id: u64) -> PlatformResult<()> {
        match self.compositor {
            Compositor::Sway => {
                let arg = format!("[con_id={window_id}] focus");
                Self::run_command("swaymsg", &[&arg], "swaymsg focus")
            }
            Compositor::Hyprland => {
                let arg = format!("focuswindow address:0x{window_id:x}");
                Self::run_command("hyprctl", &["dispatch", &arg], "hyprctl focus")
            }
            Compositor::Kde => {
                let id = kde_id_from_hash(window_id);
                if is_in_path("kdotool") {
                    Self::run_command("kdotool", &["windowactivate", &id], "kdotool windowactivate")
                } else {
                    Self::kwin_script_run(&format!(
                        r#"(function() {{
                            var clients = workspace.windowList();
                            for (var i = 0; i < clients.length; i++) {{
                                if (String(clients[i].internalId) === "{id}") {{
                                    workspace.activeWindow = clients[i];
                                    break;
                                }}
                            }}
                        }})();"#
                    ))
                }
            }
            Compositor::Gnome => {
                // Window Commander doesn't have a dedicated focus/activate method,
                // but we can use the GNOME Shell Eval interface.
                let script = format!(
                    "global.get_window_actors().forEach(a => {{ \
                        if (a.meta_window.get_id() == {window_id}) \
                            a.meta_window.activate(global.get_current_time()); \
                    }})"
                );
                Self::run_command("gdbus", &[
                    "call", "--session",
                    "--dest", "org.gnome.Shell",
                    "--object-path", "/org/gnome/Shell",
                    "--method", "org.gnome.Shell.Eval",
                    &script,
                ], "gdbus Eval focus")
            }
            Compositor::Unknown => {
                Err(PlatformError::NotAvailable(
                    "no supported Wayland compositor for focus_window".into(),
                ))
            }
        }
    }

    fn move_resize_window(
        &self,
        window_id: u64,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
    ) -> PlatformResult<()> {
        match self.compositor {
            Compositor::Sway => {
                let cmd = format!(
                    "[con_id={wid}] floating enable; \
                     [con_id={wid}] move position {x} {y}; \
                     [con_id={wid}] resize set {w} {h}",
                    wid = window_id,
                );
                Self::run_command("swaymsg", &[&cmd], "swaymsg move_resize")
            }
            Compositor::Hyprland => {
                let addr = format!("address:0x{window_id:x}");
                let move_arg = format!("exact {x} {y},{addr}");
                Self::run_command("hyprctl", &["dispatch", "movewindowpixel", &move_arg], "hyprctl move")?;
                let resize_arg = format!("exact {w} {h},{addr}");
                Self::run_command("hyprctl", &["dispatch", "resizewindowpixel", &resize_arg], "hyprctl resize")
            }
            Compositor::Kde => {
                let id = kde_id_from_hash(window_id);
                if is_in_path("kdotool") {
                    Self::run_command("kdotool", &["windowmove", &id, &x.to_string(), &y.to_string()], "kdotool windowmove")?;
                    Self::run_command("kdotool", &["windowsize", &id, &w.to_string(), &h.to_string()], "kdotool windowsize")
                } else {
                    Self::kwin_script_run(&format!(
                        r#"(function() {{
                            var clients = workspace.windowList();
                            for (var i = 0; i < clients.length; i++) {{
                                var c = clients[i];
                                if (String(c.internalId) === "{id}") {{
                                    c.frameGeometry = {{x: {x}, y: {y}, width: {w}, height: {h}}};
                                    break;
                                }}
                            }}
                        }})();"#
                    ))
                }
            }
            Compositor::Gnome => {
                Self::run_command("gdbus", &[
                    "call", "--session",
                    "--dest", "org.gnome.Shell",
                    "--object-path", "/org/gnome/Shell/Extensions/WindowCommander",
                    "--method", "org.gnome.Shell.Extensions.WindowCommander.Place",
                    &window_id.to_string(),
                    &(x as u32).to_string(),
                    &(y as u32).to_string(),
                    &w.to_string(),
                    &h.to_string(),
                ], "Window Commander Place")
            }
            Compositor::Unknown => {
                Err(PlatformError::NotAvailable(
                    "no supported Wayland compositor for move_resize_window".into(),
                ))
            }
        }
    }

    fn batch_move_resize(&self, moves: &[(u64, i32, i32, u32, u32)]) -> PlatformResult<()> {
        // Only KDE without kdotool benefits from batching into a single KWin script
        if self.compositor != Compositor::Kde || is_in_path("kdotool") {
            // Default: individual calls
            for &(wid, x, y, w, h) in moves {
                self.move_resize_window(wid, x, y, w, h)?;
            }
            return Ok(());
        }

        // Build a single KWin script that moves all windows at once
        let mut script = String::from("(function() {\n    var clients = workspace.windowList();\n    var map = {};\n    for (var i = 0; i < clients.length; i++) { map[String(clients[i].internalId)] = clients[i]; }\n");
        for &(wid, x, y, w, h) in moves {
            let id = kde_id_from_hash(wid);
            script.push_str(&format!(
                "    if (map[\"{id}\"]) map[\"{id}\"].frameGeometry = {{x: {x}, y: {y}, width: {w}, height: {h}}};\n"
            ));
        }
        script.push_str("})();");

        Self::kwin_script_run(&script)
    }
}
