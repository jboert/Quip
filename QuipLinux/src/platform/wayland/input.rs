use std::process::Command;
use std::thread;
use std::time::Duration;

use base64::Engine;

use crate::platform::traits::{InputBackend, PlatformError, PlatformResult};

/// Walk the process tree under `window_pid` and, if any descendant's
/// controlling terminal matches a tmux pane, return that pane's scrollback.
/// Returns `None` when there's no tmux pane to be found. Mirrors the X11 path.
fn try_tmux_capture(window_pid: u32) -> Option<String> {
    if window_pid == 0 {
        return None;
    }
    let panes_output = Command::new("tmux")
        .args(["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        .output()
        .ok()?;
    if !panes_output.status.success() {
        return None;
    }
    let panes_text = String::from_utf8_lossy(&panes_output.stdout).into_owned();

    fn walk(pid: &str, panes: &str, depth: u8) -> Option<String> {
        if depth > 5 {
            return None;
        }
        let fd_path = format!("/proc/{pid}/fd/0");
        if let Ok(pts) = std::fs::read_link(&fd_path) {
            let pts_str = pts.to_string_lossy();
            for line in panes.lines() {
                let mut parts = line.split_whitespace();
                if let (Some(tty), Some(pane_id)) = (parts.next(), parts.next()) {
                    if tty == pts_str.as_ref() {
                        return Some(pane_id.to_string());
                    }
                }
            }
        }
        let children = Command::new("pgrep").args(["-P", pid]).output().ok()?;
        for child in String::from_utf8_lossy(&children.stdout).lines() {
            let child = child.trim();
            if child.is_empty() {
                continue;
            }
            if let Some(found) = walk(child, panes, depth + 1) {
                return Some(found);
            }
        }
        None
    }

    let pane_id = walk(&window_pid.to_string(), &panes_text, 0)?;
    let capture = Command::new("tmux")
        .args(["capture-pane", "-t", &pane_id, "-p", "-S", "-200"])
        .output()
        .ok()?;
    if !capture.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&capture.stdout).into_owned())
}

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

        let tool = if Self::is_in_path("ydotool") && Self::ydotool_daemon_running() {
            Some(InputTool::Ydotool)
        } else if Self::is_in_path("wtype") {
            Some(InputTool::Wtype)
        } else {
            None
        };

        tracing::info!(
            "Wayland input backend: compositor={:?} tool={:?}",
            compositor,
            tool
        );

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

    fn ydotool_daemon_running() -> bool {
        // ydotool needs ydotoold running. A no-op key event is the fastest
        // smoke test — exits 0 if the daemon is reachable, 1 otherwise.
        Command::new("ydotool")
            .args(["key", ""])
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
                if Self::is_in_path("kdotool") {
                    Self::run_cmd("kdotool", &["windowactivate", &kde_id], "kdotool windowactivate")
                } else {
                    // Use KWin scripting to focus
                    super::windows::WaylandWindowBackend::kwin_script_run_pub(&format!(
                        r#"(function() {{
                            var clients = workspace.windowList();
                            for (var i = 0; i < clients.length; i++) {{
                                if (String(clients[i].internalId) === "{kde_id}") {{
                                    workspace.activeWindow = clients[i];
                                    break;
                                }}
                            }}
                        }})();"#
                    ))
                }
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

    /// Map a logical key name to raw ydotool keycodes. Returns a list of
    /// `<keycode>:<state>` args ready to pass to `ydotool key`. ydotool rejects
    /// symbolic names (anything non-numeric is silently treated as a delay),
    /// so everything has to go through raw Linux input-event-codes.
    /// See /usr/include/linux/input-event-codes.h for the KEY_* constants.
    fn map_key_ydotool(key: &str) -> Vec<String> {
        fn press(code: u32) -> Vec<String> {
            vec![format!("{code}:1"), format!("{code}:0")]
        }
        fn combo(modifier: u32, base: u32) -> Vec<String> {
            vec![
                format!("{modifier}:1"),
                format!("{base}:1"),
                format!("{base}:0"),
                format!("{modifier}:0"),
            ]
        }

        // Selected KEY_* codes from linux/input-event-codes.h
        const KEY_ESC: u32 = 1;
        const KEY_TAB: u32 = 15;
        const KEY_ENTER: u32 = 28;
        const KEY_LEFTCTRL: u32 = 29;
        const KEY_LEFTSHIFT: u32 = 42;
        const KEY_C: u32 = 46;
        const KEY_D: u32 = 32;
        const KEY_U: u32 = 22;
        const KEY_Y: u32 = 21;
        const KEY_N: u32 = 49;
        const KEY_LEFT: u32 = 105;
        const KEY_RIGHT: u32 = 106;
        const KEY_UP: u32 = 103;
        const KEY_DOWN: u32 = 108;
        const KEY_BACKSPACE: u32 = 14;
        const KEY_SPACE: u32 = 57;

        match key.to_lowercase().as_str() {
            "return" | "enter" => press(KEY_ENTER),
            "escape" | "esc" => press(KEY_ESC),
            "tab" => press(KEY_TAB),
            "backspace" => press(KEY_BACKSPACE),
            "space" => press(KEY_SPACE),
            "left" => press(KEY_LEFT),
            "right" => press(KEY_RIGHT),
            "up" => press(KEY_UP),
            "down" => press(KEY_DOWN),
            "y" => press(KEY_Y),
            "n" => press(KEY_N),
            "ctrl+c" => combo(KEY_LEFTCTRL, KEY_C),
            "ctrl+d" => combo(KEY_LEFTCTRL, KEY_D),
            // Ctrl+U — readline "kill to start of line"; wipes the prompt input
            // in one keystroke. Mac wires this as the `clear_input` quick action.
            "ctrl+u" => combo(KEY_LEFTCTRL, KEY_U),
            // Shift+Tab — Claude Code plan-mode cycle.
            "shift+tab" => combo(KEY_LEFTSHIFT, KEY_TAB),
            // Last-resort fallback: a single a-z character maps to its KEY_ code.
            // Anything else is passed through as-is so ydotool will at least log
            // "non-interpretable value" instead of us silently swallowing it.
            other => {
                if other.len() == 1 {
                    let ch = other.chars().next().unwrap();
                    if ch.is_ascii_lowercase() {
                        // KEY_A=30 ... KEY_Z=44 is NOT the alphabet order — the
                        // kernel uses QWERTY row order. Use a lookup table.
                        let qwerty: [(char, u32); 26] = [
                            ('a', 30), ('b', 48), ('c', 46), ('d', 32),
                            ('e', 18), ('f', 33), ('g', 34), ('h', 35),
                            ('i', 23), ('j', 36), ('k', 37), ('l', 38),
                            ('m', 50), ('n', 49), ('o', 24), ('p', 25),
                            ('q', 16), ('r', 19), ('s', 31), ('t', 20),
                            ('u', 22), ('v', 47), ('w', 17), ('x', 45),
                            ('y', 21), ('z', 44),
                        ];
                        if let Some(&(_, code)) = qwerty.iter().find(|(c, _)| *c == ch) {
                            return press(code);
                        }
                    }
                }
                vec![other.to_string()]
            }
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
            // wtype uses XKB key names; Tab is capitalized.
            "shift+tab" => return vec!["-M".into(), "shift".into(), "-k".into(), "Tab".into()],
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

    // ── Konsole D-Bus fallback (KDE without ydotool/wtype) ─────────────

    /// Find the Konsole D-Bus service name for a given window PID.
    fn find_konsole_service(pid: u32) -> Option<String> {
        // Konsole registers as org.kde.konsole-<PID>
        let service = format!("org.kde.konsole-{pid}");
        // Verify it exists
        let output = Command::new("dbus-send")
            .args(["--session", "--dest=org.freedesktop.DBus", "--print-reply",
                   "/", "org.freedesktop.DBus.NameHasOwner",
                   &format!("string:{service}")])
            .output()
            .ok()?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        if stdout.contains("true") {
            Some(service)
        } else {
            None
        }
    }

    /// Find which Konsole session corresponds to the window with the given KDE UUID.
    /// Walks /Windows/<N> to find the window matching our UUID, then gets its session.
    fn find_konsole_session(service: &str, window_id: u64) -> Option<String> {
        let kde_id = super::windows::kde_id_from_hash(window_id);

        // List windows
        let output = Command::new("/usr/lib64/qt6/bin/qdbus")
            .args([service, "/Windows"])
            .output()
            .ok()?;
        let stdout = String::from_utf8_lossy(&output.stdout);

        for line in stdout.lines() {
            let line = line.trim();
            if !line.starts_with("/Windows/") { continue; }

            // Get the current session for this window
            let session_output = Command::new("/usr/lib64/qt6/bin/qdbus")
                .args([service, line, "org.kde.konsole.Window.currentSession"])
                .output()
                .ok()?;
            let session_id = String::from_utf8_lossy(&session_output.stdout).trim().to_string();
            if !session_id.is_empty() {
                return Some(format!("/Sessions/{session_id}"));
            }
        }

        // Fallback: use the first session
        let output = Command::new("/usr/lib64/qt6/bin/qdbus")
            .args([service, "/Sessions"])
            .output()
            .ok()?;
        let stdout = String::from_utf8_lossy(&output.stdout);
        stdout.lines()
            .find(|l| l.starts_with("/Sessions/"))
            .map(|s| s.trim().to_string())
    }

    /// Send text to a Konsole window via D-Bus sendText.
    fn konsole_send_text(&self, window_id: u64, text: &str, press_return: bool) -> PlatformResult<()> {
        // Look up the PID for this window from shared state
        // The window_id is a hash — we need the PID. Read it from /proc or
        // use the KDE_ID_MAP to find the window, then look up PID from the
        // window enumeration. For now, try all running Konsole instances.
        // Claude Code's TUI only fires submit on CR (0x0D), not LF (0x0A) —
        // see the Mac fix (commit 9f1b531).
        let send_text = if press_return {
            format!("{text}\r")
        } else {
            text.to_string()
        };

        // Try to find Konsole service — enumerate D-Bus services matching org.kde.konsole-*
        let output = Command::new("dbus-send")
            .args(["--session", "--dest=org.freedesktop.DBus", "--print-reply",
                   "/", "org.freedesktop.DBus.ListNames"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("dbus ListNames: {e}")))?;

        let stdout = String::from_utf8_lossy(&output.stdout);
        let konsole_services: Vec<String> = stdout.lines()
            .filter_map(|l| {
                // Format: '      string "org.kde.konsole-12345"' or
                // '      string "org.kde.konsole"' on newer KDE/Fedora
                let trimmed = l.trim();
                let name = trimmed.strip_prefix("string \"")
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(trimmed);
                if name == "org.kde.konsole" || name.starts_with("org.kde.konsole-") {
                    Some(name.to_string())
                } else {
                    None
                }
            })
            .collect();

        if konsole_services.is_empty() {
            return Err(PlatformError::NotAvailable(
                "no Konsole D-Bus service found; install ydotool or wtype for non-Konsole terminals".into(),
            ));
        }

        // Find the right session
        for service in &konsole_services {
            if let Some(session) = Self::find_konsole_session(service, window_id) {
                let result = Command::new("dbus-send")
                    .args(["--session", "--type=method_call",
                           &format!("--dest={service}"),
                           &session,
                           "org.kde.konsole.Session.sendText",
                           &format!("string:{send_text}")])
                    .output();
                match result {
                    Ok(o) if o.status.success() => return Ok(()),
                    Ok(o) => {
                        let stderr = String::from_utf8_lossy(&o.stderr);
                        tracing::warn!("Konsole sendText failed: {stderr}");
                    }
                    Err(e) => tracing::warn!("Konsole sendText error: {e}"),
                }
            }
        }

        // Fallback: try first service, first session
        if let Some(service) = konsole_services.first() {
            let result = Command::new("dbus-send")
                .args(["--session", "--type=method_call",
                       &format!("--dest={service}"),
                       "/Sessions/1",
                       "org.kde.konsole.Session.sendText",
                       &format!("string:{send_text}")])
                .output()
                .map_err(|e| PlatformError::CommandFailed(format!("konsole sendText: {e}")))?;
            if result.status.success() {
                return Ok(());
            }
            let stderr = String::from_utf8_lossy(&result.stderr);
            return Err(PlatformError::CommandFailed(format!("konsole sendText: {stderr}")));
        }

        Err(PlatformError::NotAvailable("no input method available".into()))
    }

    /// Enumerate all currently registered `org.kde.konsole-*` D-Bus services.
    fn list_konsole_services() -> Vec<String> {
        let Ok(output) = Command::new("dbus-send")
            .args([
                "--session",
                "--dest=org.freedesktop.DBus",
                "--print-reply",
                "/",
                "org.freedesktop.DBus.ListNames",
            ])
            .output()
        else {
            return Vec::new();
        };
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|l| {
                let t = l.trim();
                let name = t.strip_prefix("string \"")
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(t);
                if name == "org.kde.konsole" || name.starts_with("org.kde.konsole-") {
                    Some(name.to_string())
                } else {
                    None
                }
            })
            .collect()
    }

    /// List session object paths (e.g. `/Sessions/1`) under a Konsole service.
    fn list_konsole_sessions(service: &str) -> Vec<String> {
        let Ok(output) = Command::new("/usr/lib64/qt6/bin/qdbus")
            .args([service])
            .output()
        else {
            return Vec::new();
        };
        if !output.status.success() {
            return Vec::new();
        }
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| l.starts_with("/Sessions/") && l != "/Sessions")
            .collect()
    }

    /// Fetch `Session.title(role)` via qdbus.
    fn konsole_session_title(service: &str, session_path: &str, role: u8) -> Option<String> {
        let role_str = role.to_string();
        let output = Command::new("/usr/lib64/qt6/bin/qdbus")
            .args([service, session_path, "org.kde.konsole.Session.title", &role_str])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    /// Find the `(service, session_path)` pair whose session title matches the
    /// given window title. Strips Konsole's `" — Konsole"` suffix before
    /// comparing, and tries both tab-title roles (0 and 1).
    fn konsole_find_session_by_title(window_title: &str) -> Option<(String, String)> {
        let target = window_title
            .strip_suffix(" — Konsole")
            .unwrap_or(window_title)
            .trim();
        if target.is_empty() {
            return None;
        }

        for service in Self::list_konsole_services() {
            for session in Self::list_konsole_sessions(&service) {
                for role in [1u8, 0u8] {
                    if let Some(t) = Self::konsole_session_title(&service, &session, role) {
                        if !t.is_empty() && (t == target || target.starts_with(&t) || t.starts_with(target)) {
                            return Some((service.clone(), session));
                        }
                    }
                }
            }
        }
        None
    }

    /// Produce a clear error for the case where Konsole is running but has
    /// not registered its scripting D-Bus service. This is the default on
    /// Konsole 25.04+ — the user has to opt in with `--enable-dbus`.
    fn konsole_unavailable_error(window_title: &str) -> PlatformError {
        let any_konsole_dbus = !Self::list_konsole_services().is_empty();
        if !any_konsole_dbus {
            PlatformError::NotAvailable(
                "Konsole has no D-Bus scripting interface. Recent Konsole \
                 versions disable it by default. Relaunch Konsole with \
                 `konsole --enable-dbus`, or install ydotool."
                    .into(),
            )
        } else {
            PlatformError::NotAvailable(format!(
                "no Konsole session matched window title '{window_title}' \
                 (try a unique tab title)"
            ))
        }
    }

    /// Send text to the Konsole session whose title matches `window_title`.
    fn konsole_send_text_matched(
        &self,
        window_title: &str,
        text: &str,
        press_return: bool,
    ) -> PlatformResult<()> {
        let (service, session) = Self::konsole_find_session_by_title(window_title)
            .ok_or_else(|| Self::konsole_unavailable_error(window_title))?;
        // Claude Code's TUI only fires submit on CR (0x0D), not LF (0x0A) —
        // same bug the Mac fix (commit 9f1b531) hit. Using \n leaves a blank
        // line under the text with the prompt unsubmitted.
        let payload = if press_return {
            format!("{text}\r")
        } else {
            text.to_string()
        };
        let output = Command::new("dbus-send")
            .args([
                "--session",
                "--type=method_call",
                "--print-reply",
                &format!("--dest={service}"),
                &session,
                "org.kde.konsole.Session.sendText",
                &format!("string:{payload}"),
            ])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("konsole sendText: {e}")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "konsole sendText {service}{session}: {stderr}"
            )));
        }
        Ok(())
    }

    /// Read visible terminal content from the Konsole session whose title
    /// matches `window_title`. No focus change, no clipboard hijack.
    fn konsole_read_content_matched(&self, window_title: &str) -> PlatformResult<String> {
        let (service, session) = Self::konsole_find_session_by_title(window_title)
            .ok_or_else(|| Self::konsole_unavailable_error(window_title))?;
        let output = Command::new("/usr/lib64/qt6/bin/qdbus")
            .args([&service, &session, "org.kde.konsole.Session.getAllDisplayedText"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("konsole getAllDisplayedText: {e}")))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(PlatformError::CommandFailed(format!(
                "konsole getAllDisplayedText {service}{session}: {stderr}"
            )));
        }
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// Map a keystroke name to a Konsole sendText payload, if supported.
    fn konsole_key_to_text(key: &str) -> Option<&'static str> {
        match key.to_lowercase().as_str() {
            // CR, not LF — Claude Code's TUI only submits on 0x0D.
            "return" | "enter" => Some("\r"),
            "tab" => Some("\t"),
            "backspace" => Some("\x7f"),
            "escape" => Some("\x1b"),
            "ctrl+c" => Some("\x03"),
            "ctrl+d" => Some("\x04"),
            "ctrl+u" => Some("\x15"), // NAK — readline "kill to start of line"
            "ctrl+z" => Some("\x1a"),
            // CSI back-tab — the standard escape sequence terminals send
            // for Shift+Tab. Used for Claude Code mode cycling.
            "shift+tab" => Some("\x1b[Z"),
            "y" => Some("y"),
            "n" => Some("n"),
            _ => None,
        }
    }

    /// Send a keystroke to Konsole via D-Bus.
    fn konsole_send_keystroke(&self, window_id: u64, key: &str) -> PlatformResult<()> {
        // Map key names to actual characters/escape sequences for sendText
        let text = match key.to_lowercase().as_str() {
            // CR, not LF — Claude Code's TUI only submits on 0x0D.
            "return" | "enter" => "\r",
            "tab" => "\t",
            "escape" => "\x1b",
            "ctrl+c" => "\x03",
            "ctrl+d" => "\x04",
            "ctrl+u" => "\x15",
            "ctrl+z" => "\x1a",
            "shift+tab" => "\x1b[Z",
            "y" => "y",
            "n" => "n",
            _ => {
                tracing::warn!("Unsupported keystroke for Konsole D-Bus: {key}");
                return Ok(());
            }
        };
        self.konsole_send_text(window_id, text, false)
    }
}

impl InputBackend for WaylandInputBackend {
    fn send_text(
        &self,
        window_id: u64,
        text: &str,
        press_return: bool,
    ) -> PlatformResult<()> {
        // On KDE without ydotool/wtype, use Konsole D-Bus directly
        if self.tool.is_none() && self.compositor == Compositor::Kde {
            return self.konsole_send_text(window_id, text, press_return);
        }

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
                    // KEY_ENTER = 28. ydotool silently ignores symbolic names.
                    let output = Command::new("ydotool")
                        .args(["key", "28:1", "28:0"])
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
        // On KDE without ydotool/wtype, use Konsole D-Bus directly
        if self.tool.is_none() && self.compositor == Compositor::Kde {
            return self.konsole_send_keystroke(window_id, key);
        }

        let tool = self.tool()?;
        self.focus(window_id)?;
        Self::focus_delay();

        match tool {
            InputTool::Ydotool => {
                let mapped = Self::map_key_ydotool(key);
                let output = Command::new("ydotool")
                    .arg("key")
                    .args(&mapped)
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
        let dir_name = std::path::Path::new(directory)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("quip");
        let session_name = format!("quip-{}", dir_name);

        let tmux_cmd = format!(
            "tmux new-session -s '{}' -c '{}' 'claude' 2>/dev/null || tmux new-session -c '{}' 'claude'",
            session_name, directory, directory
        );

        let result = match terminal {
            "foot" => Command::new(terminal)
                .args(["--working-directory", directory, "sh", "-c", &tmux_cmd])
                .spawn(),
            "kitty" => Command::new(terminal)
                .args(["--directory", directory, "sh", "-c", &tmux_cmd])
                .spawn(),
            "alacritty" => Command::new(terminal)
                .args(["--working-directory", directory, "-e", "sh", "-c", &tmux_cmd])
                .spawn(),
            "wezterm" | "wezterm-gui" => Command::new(terminal)
                .args(["start", "--cwd", directory, "--", "sh", "-c", &tmux_cmd])
                .spawn(),
            // Konsole 25.04+ doesn't register D-Bus unless asked, and D-Bus is
            // the only viable input-injection path on KDE Wayland (KWin has no
            // virtual-keyboard protocol for wtype, and ydotool needs uinput).
            "konsole" => Command::new(terminal)
                .args([
                    "--enable-dbus",
                    "--workdir",
                    directory,
                    "-e",
                    "sh",
                    "-c",
                    &tmux_cmd,
                ])
                .spawn(),
            _ => Command::new(terminal)
                .args(["-e", &format!("sh -c '{}'", tmux_cmd.replace('\'', "'\\''"))])
                .current_dir(directory)
                .spawn(),
        };

        result.map_err(|e| {
            PlatformError::CommandFailed(format!("spawn terminal '{terminal}': {e}"))
        })?;
        Ok(())
    }

    fn read_content(&self, window_id: u64) -> PlatformResult<String> {
        let tool = self.tool()?;
        self.focus(window_id)?;
        Self::focus_delay();

        // Save current clipboard
        let old_clip = Command::new("wl-paste")
            .args(["--no-newline"])
            .output()
            .ok()
            .and_then(|o| if o.status.success() { Some(o.stdout) } else { None });

        // Select all: Ctrl+Shift+A
        match tool {
            InputTool::Ydotool => {
                let _ = Command::new("ydotool")
                    .args(["key", "29:1", "42:1", "30:1", "30:0", "42:0", "29:0"]) // ctrl+shift+a
                    .output();
            }
            InputTool::Wtype => {
                let _ = Command::new("wtype")
                    .args(["-M", "ctrl", "-M", "shift", "-k", "a", "-m", "shift", "-m", "ctrl"])
                    .output();
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));

        // Copy: Ctrl+Shift+C
        match tool {
            InputTool::Ydotool => {
                let _ = Command::new("ydotool")
                    .args(["key", "29:1", "42:1", "46:1", "46:0", "42:0", "29:0"]) // ctrl+shift+c
                    .output();
            }
            InputTool::Wtype => {
                let _ = Command::new("wtype")
                    .args(["-M", "ctrl", "-M", "shift", "-k", "c", "-m", "shift", "-m", "ctrl"])
                    .output();
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));

        // Read clipboard
        let clip_output = Command::new("wl-paste")
            .args(["--no-newline"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("wl-paste: {e}")))?;

        let content = String::from_utf8_lossy(&clip_output.stdout).to_string();

        // Deselect
        match tool {
            InputTool::Ydotool => {
                let _ = Command::new("ydotool").args(["key", "1:1", "1:0"]).output(); // Escape
            }
            InputTool::Wtype => {
                let _ = Command::new("wtype").args(["-k", "Escape"]).output();
            }
        }

        // Restore old clipboard
        if let Some(old) = old_clip {
            let mut child = Command::new("wl-copy")
                .stdin(std::process::Stdio::piped())
                .spawn()
                .ok();
            if let Some(ref mut c) = child {
                use std::io::Write;
                if let Some(ref mut stdin) = c.stdin {
                    let _ = stdin.write_all(&old);
                }
                let _ = c.wait();
            }
        }

        Ok(content)
    }

    fn capture_screenshot(&self, window_id: u64) -> PlatformResult<String> {
        // `spectacle -a` captures the active window. Focus our target first so
        // the active window IS our target. On KDE without ydotool/wtype the
        // focus call goes through KWin scripting, which doesn't need a
        // keyboard protocol.
        let _ = self.focus(window_id);
        Self::focus_delay();

        let tmp_path = format!("/tmp/quip_screenshot_{}.png", std::process::id());
        let status = Command::new("spectacle")
            .args(["-a", "-b", "-n", "-e", "-S", "-o", &tmp_path])
            .status()
            .map_err(|e| PlatformError::CommandFailed(format!("spectacle: {e}")))?;
        if !status.success() {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(PlatformError::CommandFailed(
                "spectacle failed to capture active window".into(),
            ));
        }

        let bytes = std::fs::read(&tmp_path).map_err(|e| {
            PlatformError::CommandFailed(format!("read screenshot: {e}"))
        })?;
        let _ = std::fs::remove_file(&tmp_path);
        Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
    }

    fn send_text_with_hints(
        &self,
        window_id: u64,
        text: &str,
        press_return: bool,
        _pid: u32,
        title: &str,
        app_class: &str,
    ) -> PlatformResult<()> {
        // ydotool writes to /dev/uinput at the kernel level, bypassing Wayland
        // protocols entirely — it works on KWin even though wtype doesn't. So
        // we only take the Konsole D-Bus shortcut when ydotool is unavailable.
        let is_kde_konsole = self.compositor == Compositor::Kde
            && app_class.to_lowercase().contains("konsole");
        let has_ydotool = matches!(self.tool, Some(InputTool::Ydotool));
        if is_kde_konsole && !has_ydotool {
            return self.konsole_send_text_matched(title, text, press_return);
        }
        self.send_text(window_id, text, press_return)
    }

    fn send_keystroke_with_hints(
        &self,
        window_id: u64,
        key: &str,
        _pid: u32,
        title: &str,
        app_class: &str,
    ) -> PlatformResult<()> {
        let is_kde_konsole = self.compositor == Compositor::Kde
            && app_class.to_lowercase().contains("konsole");
        let has_ydotool = matches!(self.tool, Some(InputTool::Ydotool));
        if is_kde_konsole && !has_ydotool {
            let payload = Self::konsole_key_to_text(key).ok_or_else(|| {
                PlatformError::NotAvailable(format!(
                    "key '{key}' not supported via Konsole D-Bus"
                ))
            })?;
            return self.konsole_send_text_matched(title, payload, false);
        }
        self.send_keystroke(window_id, key)
    }

    fn read_content_with_hints(
        &self,
        window_id: u64,
        pid: u32,
        title: &str,
        app_class: &str,
    ) -> PlatformResult<String> {
        // Try tmux first, regardless of terminal — this is the best UX (full
        // scrollback, no focus steal) and works as long as the shell inside
        // the window is under tmux. The X11 backend does the same.
        if let Some(content) = try_tmux_capture(pid) {
            return Ok(content);
        }

        // On KDE + Konsole, do not fall back to the clipboard-based read:
        // that path focuses the window and types Ctrl+Shift+A/C via wtype,
        // which (a) steals focus and (b) fails on KWin. Try Konsole's D-Bus
        // scripting interface instead — only works if Konsole was launched
        // with `--enable-dbus` (the quip-spawned ones are).
        if self.compositor == Compositor::Kde && app_class.to_lowercase().contains("konsole") {
            return self.konsole_read_content_matched(title);
        }
        self.read_content(window_id)
    }
}
