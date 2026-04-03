use std::process::Command;

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

impl InputBackend for X11InputBackend {
    fn send_text(&self, window_id: u64, text: &str, press_return: bool) -> PlatformResult<()> {
        let wid_str = window_id.to_string();

        let output = Command::new("xdotool")
            .args(["type", "--clearmodifiers", "--window", &wid_str, text])
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
                .args(["key", "--window", &wid_str, "Return"])
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

        let output = Command::new("xdotool")
            .args(["key", "--window", &wid_str, mapped])
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
        Command::new(terminal)
            .current_dir(directory)
            .spawn()
            .map_err(|e| {
                PlatformError::CommandFailed(format!("failed to spawn {terminal}: {e}"))
            })?;

        Ok(())
    }

    fn read_content(&self, window_id: u64) -> PlatformResult<String> {
        let wid_str = window_id.to_string();

        // Save current clipboard
        let old_clip = Command::new("xclip")
            .args(["-selection", "clipboard", "-o"])
            .output()
            .ok()
            .and_then(|o| if o.status.success() { Some(o.stdout) } else { None });

        // Select all: Ctrl+Shift+A (works in most terminals)
        let _ = Command::new("xdotool")
            .args(["key", "--window", &wid_str, "ctrl+shift+a"])
            .output();

        std::thread::sleep(std::time::Duration::from_millis(100));

        // Copy: Ctrl+Shift+C
        let _ = Command::new("xdotool")
            .args(["key", "--window", &wid_str, "ctrl+shift+c"])
            .output();

        std::thread::sleep(std::time::Duration::from_millis(100));

        // Read clipboard
        let clip_output = Command::new("xclip")
            .args(["-selection", "clipboard", "-o"])
            .output()
            .map_err(|e| PlatformError::CommandFailed(format!("xclip read: {e}")))?;

        let content = String::from_utf8_lossy(&clip_output.stdout).to_string();

        // Deselect: press Escape then Right arrow to clear selection without moving cursor
        let _ = Command::new("xdotool")
            .args(["key", "--window", &wid_str, "Escape"])
            .output();

        // Restore old clipboard
        if let Some(old) = old_clip {
            let mut child = Command::new("xclip")
                .args(["-selection", "clipboard", "-i"])
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
}
