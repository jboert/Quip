use std::fs;
use std::io::Write;

use tracing::{error, warn};

/// Set the terminal background color for the PTY attached to the given PID.
pub fn set_background_color(pid: u32, hex_color: &str) {
    let Some(pty_path) = find_pty(pid) else {
        warn!("Could not find PTY for pid {pid}");
        return;
    };

    let rgb = hex_to_osc_rgb(hex_color);
    let sequence = format!("\x1b]11;{rgb}\x1b\\");

    if let Err(e) = write_to_pty(&pty_path, sequence.as_bytes()) {
        error!("Failed to set background color on {pty_path}: {e}");
    }
}

/// Reset the terminal background color to the default for the PTY attached to the given PID.
pub fn reset_background_color(pid: u32) {
    let Some(pty_path) = find_pty(pid) else {
        warn!("Could not find PTY for pid {pid}");
        return;
    };

    let sequence = "\x1b]111\x1b\\";

    if let Err(e) = write_to_pty(&pty_path, sequence.as_bytes()) {
        error!("Failed to reset background color on {pty_path}: {e}");
    }
}

/// Find the PTY device for a process by reading /proc/{pid}/fd/0.
fn find_pty(pid: u32) -> Option<String> {
    let fd_path = format!("/proc/{pid}/fd/0");
    match fs::read_link(&fd_path) {
        Ok(target) => {
            let target_str = target.to_string_lossy().to_string();
            if target_str.starts_with("/dev/pts/") {
                Some(target_str)
            } else {
                warn!("fd/0 for pid {pid} points to {target_str}, not a PTY");
                None
            }
        }
        Err(e) => {
            warn!("Could not readlink {fd_path}: {e}");
            None
        }
    }
}

/// Convert a hex color like "#001430" to OSC RGB format "rgb:00/14/30".
fn hex_to_osc_rgb(hex: &str) -> String {
    let hex = hex.trim_start_matches('#');
    if hex.len() < 6 {
        warn!("Invalid hex color: #{hex}, using black");
        return "rgb:00/00/00".to_string();
    }
    let r = &hex[0..2];
    let g = &hex[2..4];
    let b = &hex[4..6];
    format!("rgb:{r}/{g}/{b}")
}

/// Write raw bytes to a PTY device file.
fn write_to_pty(path: &str, data: &[u8]) -> std::io::Result<()> {
    let mut file = fs::OpenOptions::new().write(true).open(path)?;
    file.write_all(data)?;
    file.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hex_to_osc_rgb() {
        assert_eq!(hex_to_osc_rgb("#001430"), "rgb:00/14/30");
        assert_eq!(hex_to_osc_rgb("FF00AA"), "rgb:FF/00/AA");
        assert_eq!(hex_to_osc_rgb("#240040"), "rgb:24/00/40");
    }

    #[test]
    fn test_hex_to_osc_rgb_short_input() {
        assert_eq!(hex_to_osc_rgb("#F0"), "rgb:00/00/00");
    }
}
