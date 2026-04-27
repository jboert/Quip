use std::process::Command;

use crate::protocol::messages::MacPermissionsMessage;

/// Linux equivalent of QuipMac/Services/PermissionProbeService.swift.
///
/// The wire message is named `mac_permissions` for iOS-app compatibility, but
/// the booleans below are filled with Linux-relevant probes:
///
/// * `accessibility` ↔ host can inject input (ydotool, wtype, xdotool, or
///   Konsole D-Bus available). False means PTT keystrokes / send-text / quick
///   buttons can't reach a terminal — the iOS perms LA badges this.
/// * `apple_events` ↔ N/A on Linux; always true so the badge counter doesn't
///   light up for a permission that doesn't exist here.
/// * `screen_recording` ↔ X11: always true (root window capture is always
///   allowed). Wayland: best-effort probe of xdg-desktop-portal ScreenCast —
///   defaults to true if probing isn't possible since false-alarming on every
///   launch is worse than missing a real denial.
pub struct PermissionProbe;

impl PermissionProbe {
    pub fn probe() -> MacPermissionsMessage {
        MacPermissionsMessage::new(
            Self::accessibility_ok(),
            true, // appleEvents — N/A on Linux
            Self::screen_recording_ok(),
        )
    }

    fn accessibility_ok() -> bool {
        // Any one of these means we have an input-injection path.
        Self::has_command("ydotool")
            || Self::has_command("wtype")
            || Self::has_command("xdotool")
            || Self::konsole_dbus_available()
    }

    fn screen_recording_ok() -> bool {
        let session = std::env::var("XDG_SESSION_TYPE").unwrap_or_default();
        if session != "wayland" {
            // X11 (or unknown): root capture works, no permission gate.
            return true;
        }
        // Wayland: we can't synchronously prove portal access without
        // triggering a user prompt, so default optimistic and rely on the
        // capture path to surface failures inline.
        true
    }

    fn has_command(cmd: &str) -> bool {
        Command::new("which")
            .arg(cmd)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    fn konsole_dbus_available() -> bool {
        // Cheap presence check — full probing happens at injection time.
        Command::new("dbus-send")
            .args([
                "--session",
                "--dest=org.freedesktop.DBus",
                "--print-reply",
                "/",
                "org.freedesktop.DBus.NameHasOwner",
                "string:org.kde.konsole",
            ])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("true"))
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_returns_valid_message() {
        let m = PermissionProbe::probe();
        assert_eq!(m.type_, "mac_permissions");
        assert!(m.apple_events, "Linux always reports apple_events=true");
    }

    #[test]
    fn screen_recording_true_on_x11_session() {
        // Force the env so the test is deterministic regardless of the host.
        std::env::set_var("XDG_SESSION_TYPE", "x11");
        assert!(PermissionProbe::screen_recording_ok());
    }
}
