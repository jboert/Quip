use std::process::Command;

use crate::protocol::messages::MacSettingsPane;

/// Linux equivalent of `NSWorkspace.shared.open(x-apple.systempreferences:...)`.
///
/// The wire message is named `open_mac_settings_pane` for iOS-app
/// compatibility, but the panes here map to Linux equivalents:
///
/// * `accessibility` ↔ KDE: Input/Keyboard, GNOME: Accessibility settings
///   (closest analog to "let this app type for you" — actual ydotool/wtype
///   permissions are configured at the user-group level, not GUI)
/// * `screenRecording` ↔ xdg-desktop-portal screencast permissions
///   (KDE: Permissions; GNOME: Privacy → Screen)
/// * `automation` ↔ no Linux equivalent — opens generic Settings
///
/// Uses `xdg-open` with falls-back-to-best-guess so this works across
/// KDE, GNOME, Sway, and XFCE. Spawns asynchronously — the user opening
/// the settings shouldn't block the WS handler thread.
pub fn open_pane(pane: MacSettingsPane) {
    let candidates = candidates_for(pane);
    std::thread::spawn(move || {
        for cmd in candidates {
            let parts: Vec<&str> = cmd.split_whitespace().collect();
            if parts.is_empty() {
                continue;
            }
            let r = Command::new(parts[0]).args(&parts[1..]).spawn();
            if r.is_ok() {
                return;
            }
        }
        tracing::warn!("open_pane: no settings opener succeeded for {:?}", pane);
    });
}

fn candidates_for(pane: MacSettingsPane) -> Vec<String> {
    let kde = std::env::var("KDE_FULL_SESSION").is_ok()
        || std::env::var("XDG_CURRENT_DESKTOP")
            .map(|v| v.to_ascii_lowercase().contains("kde"))
            .unwrap_or(false);
    let gnome = std::env::var("XDG_CURRENT_DESKTOP")
        .map(|v| v.to_ascii_lowercase().contains("gnome"))
        .unwrap_or(false);

    let mut out: Vec<String> = Vec::new();
    match pane {
        MacSettingsPane::Accessibility => {
            if kde {
                // KDE Plasma 6 / 5
                out.push("kcmshell6 kcm_accessibility".into());
                out.push("kcmshell5 kcm_accessibility".into());
            }
            if gnome {
                out.push("gnome-control-center universal-access".into());
            }
            out.push("xdg-open settings:accessibility".into());
        }
        MacSettingsPane::ScreenRecording => {
            if kde {
                // Plasma's permission center / screencast control
                out.push("kcmshell6 kcm_kded".into());
                out.push("kcmshell6 kcm_xdgportals".into());
                out.push("kcmshell5 kcm_kded".into());
            }
            if gnome {
                out.push("gnome-control-center privacy".into());
            }
            out.push("xdg-open settings:privacy".into());
        }
        MacSettingsPane::Automation => {
            // No real Linux equivalent — drop the user in generic Settings.
            if kde {
                out.push("systemsettings".into());
                out.push("systemsettings5".into());
            }
            if gnome {
                out.push("gnome-control-center".into());
            }
            out.push("xdg-open settings:".into());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_includes_xdg_open_fallback_for_every_pane() {
        for pane in [
            MacSettingsPane::Accessibility,
            MacSettingsPane::ScreenRecording,
            MacSettingsPane::Automation,
        ] {
            let c = candidates_for(pane);
            assert!(
                c.iter().any(|s| s.starts_with("xdg-open") || s.contains("control-center") || s.contains("kcmshell")),
                "no opener for {pane:?}: {c:?}"
            );
        }
    }

    #[test]
    fn candidates_for_kde_accessibility_includes_kcm() {
        std::env::set_var("XDG_CURRENT_DESKTOP", "KDE");
        let c = candidates_for(MacSettingsPane::Accessibility);
        assert!(c.iter().any(|s| s.contains("kcmshell")), "no kcmshell candidate for KDE: {c:?}");
    }
}
