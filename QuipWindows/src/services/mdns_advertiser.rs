//! Bonjour advertising (spec 3.1, 6), as `QuipMac/Services/BonjourAdvertiser.swift`
//! does it: service type `_quip._tcp.` in `local.`, instance name
//! `Quip <PC name>`, the listening port, and TXT `did=<deviceID>`. The phone
//! (`QuipiOS/Services/BonjourBrowser.swift`) resolves the service to an IPv4
//! address and folds it into an existing backend row with the same `did`
//! instead of adding a second one.
//!
//! Advertised only on the PC's LAN addresses (RFC 1918, virtual adapters
//! already dropped by `local_addresses::interface_ipv4s`): every other
//! interface is switched off in the daemon, so no vEthernet / WSL / Docker /
//! loopback address is announced. Tailscale carries no multicast, so it is
//! left out too; the phone reaches the PC there through its saved URL.
//!
//! The rules (name, host name, TXT, addresses) are pure and tested on the
//! Mac; `MdnsAdvertiser` uses `mdns-sd` (as `QuipLinux/src/services/mdns_advertiser.rs`).
//! Only the real host advertises (`app::run`); `--fake-platform` never does.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};

use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};

use crate::services::local_addresses::is_rfc1918_ipv4;

/// `_quip._tcp.` in the `local.` domain, as `mdns-sd` spells it.
pub const SERVICE_TYPE: &str = "_quip._tcp.local.";
/// The TXT key the phone folds rows by.
pub const TXT_DEVICE_ID: &str = "did";
/// A DNS label holds at most 63 bytes.
const MAX_LABEL: usize = 63;

/// `Quip <PC name>`, cut to one DNS label (63 bytes, on a char boundary).
pub fn service_name(pc_name: &str) -> String {
    let pc = pc_name.trim();
    let pc = if pc.is_empty() { "Windows PC" } else { pc };
    let mut name = format!("Quip {pc}");
    while name.len() > MAX_LABEL {
        name.pop();
    }
    name
}

/// `<label>.local.` for the PC: letters, digits and `-` only (anything else
/// becomes `-`), at most 63 bytes, `quip-pc` when nothing usable is left.
pub fn host_name(pc_name: &str) -> String {
    let label: String = pc_name
        .split('.')
        .next()
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .take(MAX_LABEL)
        .collect();
    let label = label.trim_matches('-');
    let label = if label.is_empty() || label.eq_ignore_ascii_case("localhost") { "quip-pc" } else { label };
    format!("{label}.local.")
}

/// TXT record: `did=<deviceID>`, nothing else (the Mac's record).
pub fn txt(device_id: &str) -> HashMap<String, String> {
    HashMap::from([(TXT_DEVICE_ID.to_string(), device_id.to_string())])
}

/// The addresses to announce on: the LAN ones (RFC 1918), in order, once
/// each.
pub fn advertised_ips(addresses: &[Ipv4Addr]) -> Vec<Ipv4Addr> {
    let mut out: Vec<Ipv4Addr> = Vec::new();
    for a in addresses {
        if is_rfc1918_ipv4(&a.to_string()) && !out.contains(a) {
            out.push(*a);
        }
    }
    out
}

/// What one advertisement says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Advert {
    pub name: String,
    pub host: String,
    pub ips: Vec<Ipv4Addr>,
    pub port: u16,
    pub txt: HashMap<String, String>,
}

impl Advert {
    /// `None` when the PC has no LAN address (nothing to announce on).
    pub fn new(pc_name: &str, addresses: &[Ipv4Addr], port: u16, device_id: &str) -> Option<Advert> {
        let ips = advertised_ips(addresses);
        if ips.is_empty() {
            return None;
        }
        Some(Advert { name: service_name(pc_name), host: host_name(pc_name), ips, port, txt: txt(device_id) })
    }
}

/// A registered service. Unregistered, and the daemon stopped, on drop.
pub struct MdnsAdvertiser {
    daemon: ServiceDaemon,
    fullname: String,
}

impl MdnsAdvertiser {
    /// Starts the daemon on `advert.ips` only and registers the service.
    pub fn start(advert: &Advert) -> Result<Self, String> {
        let daemon = ServiceDaemon::new().map_err(|e| format!("cannot start mDNS: {e}"))?;
        let ips: Vec<IpAddr> = advert.ips.iter().map(|ip| IpAddr::V4(*ip)).collect();
        // Later selections win: everything off, then the LAN addresses on.
        daemon.disable_interface(IfKind::All).map_err(|e| format!("mDNS interface selection: {e}"))?;
        daemon.enable_interface(ips.clone()).map_err(|e| format!("mDNS interface selection: {e}"))?;
        let info =
            ServiceInfo::new(SERVICE_TYPE, &advert.name, &advert.host, &ips[..], advert.port, advert.txt.clone())
                .map_err(|e| format!("mDNS service record: {e}"))?;
        let fullname = info.get_fullname().to_string();
        if let Err(e) = daemon.register(info) {
            let _ = daemon.shutdown();
            return Err(format!("mDNS register: {e}"));
        }
        Ok(Self { daemon, fullname })
    }

    /// The registered instance, `Quip <PC name>._quip._tcp.local.`.
    pub fn fullname(&self) -> &str {
        &self.fullname
    }
}

impl Drop for MdnsAdvertiser {
    fn drop(&mut self) {
        // The goodbye packets go out from the daemon thread; wait briefly
        // for them so a Quit says goodbye before the process ends.
        if let Ok(rx) = self.daemon.unregister(&self.fullname) {
            let _ = rx.recv_timeout(std::time::Duration::from_secs(1));
        }
        let _ = self.daemon.shutdown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(s: &str) -> Ipv4Addr {
        s.parse().unwrap()
    }

    #[test]
    fn service_type_and_txt_match_the_mac() {
        // BonjourAdvertiser.swift: type "_quip._tcp.", domain "local.", TXT "did".
        assert_eq!(SERVICE_TYPE, "_quip._tcp.local.");
        let t = txt("6BA7B810-9DAD-41D1-80B4-00C04FD430C8");
        assert_eq!(t.len(), 1);
        assert_eq!(t["did"], "6BA7B810-9DAD-41D1-80B4-00C04FD430C8");
    }

    #[test]
    fn service_name_is_quip_and_the_pc_name() {
        assert_eq!(service_name("DESK-01"), "Quip DESK-01");
        assert_eq!(service_name("  "), "Quip Windows PC");
        let long = service_name(&"é".repeat(40));
        assert!(long.len() <= 63 && long.starts_with("Quip é"), "{long}");
    }

    #[test]
    fn host_name_is_one_dns_label_in_local() {
        assert_eq!(host_name("DESK-01"), "DESK-01.local.");
        assert_eq!(host_name("desk.corp.example"), "desk.local.");
        assert_eq!(host_name("Owner's PC"), "Owner-s-PC.local.");
        assert_eq!(host_name(""), "quip-pc.local.");
        assert_eq!(host_name("localhost"), "quip-pc.local.");
        assert_eq!(host_name(&"a".repeat(80)).len(), 63 + ".local.".len());
    }

    #[test]
    fn only_lan_addresses_are_announced() {
        let all = [ip("100.101.1.2"), ip("192.168.1.20"), ip("169.254.3.4"), ip("8.8.8.8"), ip("10.0.0.5")];
        assert_eq!(advertised_ips(&all), [ip("192.168.1.20"), ip("10.0.0.5")]);
        assert_eq!(advertised_ips(&[ip("10.0.0.5"), ip("10.0.0.5")]), [ip("10.0.0.5")]);
    }

    #[test]
    fn a_vethernet_address_never_reaches_the_advert() {
        use crate::services::local_addresses::{real_ipv4s, AdapterAddress};
        let adapters = [
            AdapterAddress { name: "Ethernet".into(), description: String::new(), ip: ip("192.168.1.20") },
            AdapterAddress {
                name: "vEthernet (WSL)".into(),
                description: "Hyper-V Virtual Ethernet Adapter".into(),
                ip: ip("172.24.80.1"),
            },
        ];
        let a = Advert::new("DESK-01", &real_ipv4s(&adapters), 8765, "did-1").unwrap();
        assert_eq!(a.ips, [ip("192.168.1.20")]);
        assert_eq!((a.name.as_str(), a.host.as_str(), a.port), ("Quip DESK-01", "DESK-01.local.", 8765));
    }

    #[test]
    fn no_lan_address_means_no_advert() {
        assert_eq!(Advert::new("DESK-01", &[ip("100.101.1.2")], 8765, "d"), None);
        assert_eq!(Advert::new("DESK-01", &[], 8765, "d"), None);
    }
}
