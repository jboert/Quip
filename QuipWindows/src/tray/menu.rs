//! The tray menu (spec 6) as data. It is rebuilt from the host's state each
//! time the menu opens, so the phone count, PIN and addresses are current.
//! Pure, so the labels and toggles are tested on the Mac; `tray::win32` only
//! turns the entries into a popup menu.

use std::net::Ipv4Addr;

use crate::services::local_addresses::lan_and_tailscale;
use crate::services::settings::DEFAULT_PORT;

/// What a clickable entry does. The value is the Win32 menu item id.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    CopyPin = 1,
    ShowPairingQr = 2,
    NewPin = 3,
    ToggleShowAllApps = 4,
    ToggleStartWithWindows = 5,
    OpenLogsFolder = 6,
    Quit = 7,
}

impl Action {
    pub const ALL: [Action; 7] = [
        Action::CopyPin,
        Action::ShowPairingQr,
        Action::NewPin,
        Action::ToggleShowAllApps,
        Action::ToggleStartWithWindows,
        Action::OpenLogsFolder,
        Action::Quit,
    ];

    pub fn id(self) -> u32 {
        self as u32
    }

    /// The action for a menu item id; `None` for 0 (menu dismissed) or an
    /// unknown id.
    pub fn from_id(id: u32) -> Option<Action> {
        Self::ALL.into_iter().find(|a| a.id() == id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Entry {
    /// Shown greyed, does nothing.
    Info(String),
    Item {
        action: Action,
        label: String,
        enabled: bool,
        checked: bool,
    },
    Separator,
}

/// What the menu shows, read from the host when it opens.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrayStatus {
    /// Authenticated phones.
    pub phones: usize,
    pub pin: String,
    /// The PC's IPv4 addresses, virtual adapters already dropped.
    pub addresses: Vec<Ipv4Addr>,
    /// The port the host listens on.
    pub port: u16,
    pub show_all_apps: bool,
    pub start_with_windows: bool,
}

/// `Quip — 1 phone connected`.
pub fn status_line(phones: usize) -> String {
    match phones {
        0 => "Quip — no phones connected".to_string(),
        1 => "Quip — 1 phone connected".to_string(),
        n => format!("Quip — {n} phones connected"),
    }
}

/// The PIN in groups of four, `1234 5678`, so it is easy to read out.
pub fn grouped_pin(pin: &str) -> String {
    let chars: Vec<char> = pin.chars().collect();
    chars.chunks(4).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join(" ")
}

/// `LAN 192.168.1.20 · Tailscale 100.101.1.2`. The port is shown only when
/// it is not the default 8765.
pub fn addresses_line(addresses: &[Ipv4Addr], port: u16) -> String {
    let (lan, tailscale) = lan_and_tailscale(addresses);
    let show = |ips: &[Ipv4Addr]| {
        ips.iter()
            .map(|ip| if port == DEFAULT_PORT { ip.to_string() } else { format!("{ip}:{port}") })
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mut parts = Vec::new();
    if !lan.is_empty() {
        parts.push(format!("LAN {}", show(&lan)));
    }
    if !tailscale.is_empty() {
        parts.push(format!("Tailscale {}", show(&tailscale)));
    }
    if parts.is_empty() {
        "No LAN or Tailscale address".to_string()
    } else {
        parts.join(" · ")
    }
}

/// Spec 6, top to bottom. "New PIN" says that it disconnects the phones
/// (`Host::replace_pin`), so nobody presses it expecting the Mac's
/// behaviour.
pub fn build(s: &TrayStatus) -> Vec<Entry> {
    let item =
        |action, label: &str, enabled, checked| Entry::Item { action, label: label.to_string(), enabled, checked };
    vec![
        Entry::Info(status_line(s.phones)),
        item(Action::CopyPin, &format!("PIN {} (click copies)", grouped_pin(&s.pin)), true, false),
        Entry::Info(addresses_line(&s.addresses, s.port)),
        Entry::Separator,
        item(Action::ShowPairingQr, "Show pairing QR…", true, false),
        item(Action::NewPin, "New PIN (disconnects phones)", true, false),
        Entry::Separator,
        item(Action::ToggleShowAllApps, "Show all apps", true, s.show_all_apps),
        item(Action::ToggleStartWithWindows, "Start with Windows", true, s.start_with_windows),
        item(Action::OpenLogsFolder, "Open logs folder", true, false),
        Entry::Separator,
        item(Action::Quit, "Quit Quip", true, false),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status() -> TrayStatus {
        TrayStatus {
            phones: 1,
            pin: "12345678".into(),
            addresses: vec![Ipv4Addr::new(192, 168, 1, 20), Ipv4Addr::new(100, 101, 1, 2)],
            port: 8765,
            show_all_apps: false,
            start_with_windows: true,
        }
    }

    fn labels(entries: &[Entry]) -> Vec<String> {
        entries
            .iter()
            .map(|e| match e {
                Entry::Info(s) => s.clone(),
                Entry::Item { label, .. } => label.clone(),
                Entry::Separator => "-".into(),
            })
            .collect()
    }

    #[test]
    fn the_menu_lists_spec_6_in_order() {
        assert_eq!(
            labels(&build(&status())),
            vec![
                "Quip — 1 phone connected",
                "PIN 1234 5678 (click copies)",
                "LAN 192.168.1.20 · Tailscale 100.101.1.2",
                "-",
                "Show pairing QR…",
                "New PIN (disconnects phones)",
                "-",
                "Show all apps",
                "Start with Windows",
                "Open logs folder",
                "-",
                "Quit Quip",
            ]
        );
    }

    #[test]
    fn toggles_carry_their_state_and_every_item_is_enabled() {
        let checked = |entries: &[Entry], a: Action| {
            entries.iter().find_map(|e| match e {
                Entry::Item { action, checked, enabled, .. } if *action == a => Some((*checked, *enabled)),
                _ => None,
            })
        };
        let mut s = status();
        let e = build(&s);
        assert_eq!(checked(&e, Action::ToggleShowAllApps), Some((false, true)));
        assert_eq!(checked(&e, Action::ToggleStartWithWindows), Some((true, true)));
        assert_eq!(checked(&e, Action::ShowPairingQr), Some((false, true)));
        assert_eq!(checked(&e, Action::NewPin), Some((false, true)));
        s.show_all_apps = true;
        s.start_with_windows = false;
        let e = build(&s);
        assert_eq!(checked(&e, Action::ToggleShowAllApps), Some((true, true)));
        assert_eq!(checked(&e, Action::ToggleStartWithWindows), Some((false, true)));
    }

    #[test]
    fn status_line_counts_phones() {
        assert_eq!(status_line(0), "Quip — no phones connected");
        assert_eq!(status_line(1), "Quip — 1 phone connected");
        assert_eq!(status_line(3), "Quip — 3 phones connected");
    }

    #[test]
    fn pin_is_grouped_by_four() {
        assert_eq!(grouped_pin("12345678"), "1234 5678");
        assert_eq!(grouped_pin("123456"), "1234 56");
        assert_eq!(grouped_pin(""), "");
    }

    #[test]
    fn addresses_line_shows_only_lan_and_tailscale() {
        let a = |s: &str| s.parse::<Ipv4Addr>().unwrap();
        assert_eq!(addresses_line(&[], 8765), "No LAN or Tailscale address");
        assert_eq!(addresses_line(&[a("8.8.8.8")], 8765), "No LAN or Tailscale address");
        assert_eq!(addresses_line(&[a("10.0.0.5"), a("192.168.1.20")], 8765), "LAN 10.0.0.5, 192.168.1.20");
        assert_eq!(addresses_line(&[a("100.64.0.1")], 8765), "Tailscale 100.64.0.1");
        assert_eq!(addresses_line(&[a("10.0.0.5")], 9000), "LAN 10.0.0.5:9000");
    }

    #[test]
    fn action_ids_round_trip_and_zero_is_no_action() {
        for a in Action::ALL {
            assert_eq!(Action::from_id(a.id()), Some(a));
        }
        assert_eq!(Action::from_id(0), None);
        assert_eq!(Action::from_id(99), None);
    }
}
