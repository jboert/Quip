use std::process::Command;

use base64::Engine;
use crate::platform::traits::{InputBackend, PlatformError, PlatformResult};

/// X11 input backend using `xdotool` subprocesses.
pub struct X11InputBackend;

impl X11InputBackend {
    #[allow(unused)]
    pub fn new() -> Self {
        Self
    }
}

/// Map human-friendly key names to xdotool key names.
fn map_key_name(key: &str) -> &str {
    match key {
        "return" | "enter" => "Return",
        "escape" | "esc" => "Escape",
        "tab" => "Tab",
        "space" => "space",
        "backspace" => "BackSpace",
        "delete" => "Delete",
        "up" => "Up",
        "down" => "Down",
        "left" => "Left",
        "right" => "Right",
        // Pass through combos like "ctrl+c" and already-correct names unchanged.
        other => other,
    }
}

/// Try to read terminal content via tmux by finding the pane for a given window PID.
/// Returns None if the window isn't running in tmux.
fn try_tmux_capture(window_pid: u64) -> Option<String> {
    // Get the PTS of the window's _NET_WM_PID
    let pid_str = window_pid.to_string();

    // Find shell children of this PID and their PTS devices
    let children = Command::new("pgrep")
        .args(["-P", &pid_str])
        .output()
        .ok()?;
    let child_pids: Vec<String> = String::from_utf8_lossy(&children.stdout)
        .lines()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // For each child, check its PTS and look for a tmux pane
    let panes_output = Command::new("tmux")
        .args(["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        .output()
        .ok()?;
    if !panes_output.status.success() {
        return None;
    }
    let panes_text = String::from_utf8_lossy(&panes_output.stdout);

    // Walk the process tree down from window PID to find any process with a PTS
    // that matches a tmux pane
    fn find_tmux_pane(pid: &str, panes: &str, depth: u8) -> Option<String> {
        if depth > 5 {
            return None;
        }

        // Check this PID's PTS
        let fd_path = format!("/proc/{}/fd/0", pid);
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

        // Check children
        let children = Command::new("pgrep")
            .args(["-P", pid])
            .output()
            .ok()?;
        for child_pid in String::from_utf8_lossy(&children.stdout).lines() {
            let child_pid = child_pid.trim();
            if !child_pid.is_empty() {
                if let Some(pane) = find_tmux_pane(child_pid, panes, depth + 1) {
                    return Some(pane);
                }
            }
        }

        None
    }

    let pane_id = find_tmux_pane(&pid_str, &panes_text, 0)?;

    // Capture the pane's scrollback (last 200 lines)
    let capture = Command::new("tmux")
        .args(["capture-pane", "-t", &pane_id, "-p", "-S", "-200"])
        .output()
        .ok()?;
    if capture.status.success() {
        Some(String::from_utf8_lossy(&capture.stdout).to_string())
    } else {
        None
    }
}

/// Get the _NET_WM_PID for an X11 window ID
fn get_window_pid(window_id: u64) -> Option<u64> {
    let wid_hex = format!("0x{:x}", window_id);
    let output = Command::new("xprop")
        .args(["-id", &wid_hex, "_NET_WM_PID"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    // Format: "_NET_WM_PID(CARDINAL) = 12345"
    text.split('=').nth(1)?.trim().parse().ok()
}

impl InputBackend for X11InputBackend {
    fn send_text(&self, window_id: u64, text: &str, press_return: bool) -> PlatformResult<()> {
        let wid_str = window_id.to_string();

        // Focus the window first — xdotool --window doesn't reliably
        // deliver to GTK3 terminals like Terminator
        let _ = Command::new("xdotool")
            .args(["windowactivate", "--sync", &wid_str])
            .output();

        let output = Command::new("xdotool")
            .args(["type", "--clearmodifiers", text])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xdotool type: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xdotool type failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        if press_return {
            let output = Command::new("xdotool")
                .args(["key", "--clearmodifiers", "Return"])
                .output()
                .map_err(|e| PlatformError::CommandFailed(format!("xdotool key Return: {e}")))?;

            if !output.status.success() {
                return Err(PlatformError::CommandFailed(format!(
                    "xdotool key Return failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                )));
            }
        }

        Ok(())
    }

    fn send_keystroke(&self, window_id: u64, key: &str) -> PlatformResult<()> {
        let wid_str = window_id.to_string();
        let mapped = map_key_name(key);

        // Focus the window first and wait for it, then send the key to the
        // active window. Using --window alone doesn't reliably deliver keys
        // to terminal emulators on X11.
        let _ = Command::new("xdotool")
            .args(["windowactivate", "--sync", &wid_str])
            .output();

        let output = Command::new("xdotool")
            .args(["key", "--clearmodifiers", mapped])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xdotool key: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "xdotool key {mapped} failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        Ok(())
    }

    fn spawn_terminal(&self, terminal: &str, directory: &str) -> PlatformResult<()> {
        // Generate a unique tmux session name from the directory basename
        let dir_name = std::path::Path::new(directory)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("quip");
        let session_name = format!("quip-{}", dir_name);

        // The shell command to run inside the terminal:
        // Start a tmux session and run claude inside it
        let tmux_cmd = format!(
            "tmux new-session -s '{}' -c '{}' 'claude' 2>/dev/null || tmux new-session -c '{}' 'claude'",
            session_name, directory, directory
        );

        // Most terminals support -e for executing a command
        let result = match terminal {
            "kitty" => Command::new(terminal)
                .args(["--directory", directory, "sh", "-c", &tmux_cmd])
                .spawn(),
            "alacritty" => Command::new(terminal)
                .args(["--working-directory", directory, "-e", "sh", "-c", &tmux_cmd])
                .spawn(),
            "wezterm" | "wezterm-gui" => Command::new(terminal)
                .args(["start", "--cwd", directory, "--", "sh", "-c", &tmux_cmd])
                .spawn(),
            "foot" => Command::new(terminal)
                .args(["--working-directory", directory, "sh", "-c", &tmux_cmd])
                .spawn(),
            "gnome-terminal" => Command::new(terminal)
                .args(["--working-directory", directory, "--", "sh", "-c", &tmux_cmd])
                .spawn(),
            "konsole" => Command::new(terminal)
                .args(["--workdir", directory, "-e", "sh", "-c", &tmux_cmd])
                .spawn(),
            // terminator, xterm, xfce4-terminal, tilix, and others
            _ => Command::new(terminal)
                .args(["-e", &format!("sh -c '{}'", tmux_cmd.replace('\'', "'\\''"))])
                .current_dir(directory)
                .spawn(),
        };

        result.map_err(|e| {
            PlatformError::CommandFailed(format!("failed to spawn {terminal}: {e}"))
        })?;

        Ok(())
    }

    fn read_content(&self, window_id: u64) -> PlatformResult<String> {
        // Try tmux first — reliable, gets scrollback, no keybinding issues
        if let Some(pid) = get_window_pid(window_id) {
            if let Some(content) = try_tmux_capture(pid) {
                return Ok(content);
            }
        }

        // Fallback: return empty (screenshot will be the primary content)
        Ok(String::new())
    }

    fn capture_screenshot(&self, window_id: u64) -> PlatformResult<String> {
        let wid_hex = format!("0x{:x}", window_id);
        let output = Command::new("import")
            .args(["-silent", "-window", &wid_hex, "png:-"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("import screenshot: {e}")))?;

        if !output.status.success() {
            return Err(PlatformError::CommandFailed(format!(
                "import screenshot failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        Ok(base64::engine::general_purpose::STANDARD.encode(&output.stdout))
    }
}
