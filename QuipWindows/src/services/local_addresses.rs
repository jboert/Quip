//! `DeviceIdentityMessage.localURLs` (spec 3.1).
//!
//! The gate is `NetworkClassifier.isRFC1918IPv4` (`Shared/NetworkClassifier.swift`,
//! via `WebSocketServer.isPrivateIPv4`): 10/8, 172.16-31/12, 192.168/16 only.
//! That is stricter than the spec's wording ("exclude 100.64/10 and
//! 169.254/16") and satisfies it: loopback, link-local, Tailscale CGNAT and
//! public addresses are all out.
//!
//! The Mac's extra `en*` interface-name gate has no Windows equivalent, but
//! Windows has the same problem it solves: virtual switches with RFC 1918
//! addresses the phone can never reach. Rule (`is_virtual_adapter`, Windows
//! only): drop an adapter whose friendly name (the `name` `if-addrs` reports
//! on Windows, `IP_ADAPTER_ADDRESSES.FriendlyName`, e.g. `vEthernet (WSL)`)
//! or description, case-insensitively,
//! - starts with `vEthernet` (every Hyper-V switch: WSL 2, Docker Desktop,
//!   Windows Sandbox, the Default Switch), or
//! - contains `WSL`, `Hyper-V`, `Docker`, `VirtualBox`, `VMware` or
//!   `Loopback` (VM host-only adapters, `Npcap Loopback Adapter`).
//!
//! `if-addrs` exposes only the friendly name; `websocket_urls_for` also takes
//! a description so the Win32 lister (M2, `GetAdaptersAddresses`) can pass
//! one. A user-renamed adapter can slip through; the cost is one dead URL in
//! `localURLs`, which the phone already tolerates.

use std::net::Ipv4Addr;

/// `NetworkClassifier.isRFC1918IPv4`: exactly four decimal octets in 0..=255.
pub fn is_rfc1918_ipv4(ip: &str) -> bool {
    let parts: Vec<i64> = ip.split('.').filter_map(|p| p.parse::<i64>().ok()).collect();
    if parts.len() != 4 || ip.split('.').count() != 4 || !parts.iter().all(|p| (0..=255).contains(p)) {
        return false;
    }
    match (parts[0], parts[1]) {
        (10, _) => true,
        (172, b) => (16..=31).contains(&b),
        (192, 168) => true,
        _ => false,
    }
}

/// One `ws://<ip>:<port>` per private IPv4, in order, without duplicates.
pub fn websocket_urls(addresses: &[Ipv4Addr], port: u16) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for a in addresses {
        let ip = a.to_string();
        if !is_rfc1918_ipv4(&ip) {
            continue;
        }
        let url = format!("ws://{ip}:{port}");
        if !out.contains(&url) {
            out.push(url);
        }
    }
    out
}

/// The module rule: a Windows virtual switch or VM adapter, by name or
/// description.
pub fn is_virtual_adapter(name: &str, description: &str) -> bool {
    const MARKERS: [&str; 6] = ["wsl", "hyper-v", "docker", "virtualbox", "vmware", "loopback"];
    [name, description].iter().any(|s| {
        let l = s.to_lowercase();
        l.starts_with("vethernet") || MARKERS.iter().any(|m| l.contains(m))
    })
}

/// One adapter address as the OS reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterAddress {
    pub name: String,
    pub description: String,
    pub ip: Ipv4Addr,
}

/// `websocket_urls` over the adapters that are not virtual (pure: the
/// Windows rule, testable on the Mac).
pub fn websocket_urls_for(adapters: &[AdapterAddress], port: u16) -> Vec<String> {
    websocket_urls(&real_ipv4s(adapters), port)
}

/// The addresses of the adapters that are not virtual, in order.
pub fn real_ipv4s(adapters: &[AdapterAddress]) -> Vec<Ipv4Addr> {
    adapters.iter().filter(|a| !is_virtual_adapter(&a.name, &a.description)).map(|a| a.ip).collect()
}

/// Non-loopback IPv4 addresses of interfaces that are up, from the OS, with
/// the virtual adapters dropped (the rule is written for Windows names; on
/// the Mac, where only `--fake-platform` runs, nothing real matches it).
pub fn interface_ipv4s() -> Vec<Ipv4Addr> {
    let adapters: Vec<AdapterAddress> = match if_addrs::get_if_addrs() {
        Ok(ifs) => ifs
            .into_iter()
            .filter(|i| !i.is_loopback())
            .filter_map(|i| match i.ip() {
                std::net::IpAddr::V4(ip) => {
                    Some(AdapterAddress { name: i.name.clone(), description: String::new(), ip })
                }
                std::net::IpAddr::V6(_) => None,
            })
            .collect(),
        Err(_) => vec![],
    };
    real_ipv4s(&adapters)
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/LocalAddressesTests.swift` (classifier half) plus the
    //! Windows-only exclusions.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn testAcceptsRFC1918Ranges() {
        for ip in ["10.0.0.5", "10.255.255.255", "192.168.1.50", "172.16.0.1", "172.31.255.1"] {
            assert!(is_rfc1918_ipv4(ip), "{ip}");
        }
    }

    #[test]
    fn testRejectsNonLAN() {
        for ip in ["127.0.0.1", "169.254.1.1", "100.101.102.103", "172.32.0.1", "172.15.0.1", "8.8.8.8"] {
            assert!(!is_rfc1918_ipv4(ip), "{ip}");
        }
    }

    #[test]
    fn testRejectsMalformed() {
        for ip in ["not.an.ip.addr", "192.168.1", "192.168.1.256", "", "192.168.1.1.1", "192.168..1"] {
            assert!(!is_rfc1918_ipv4(ip), "{ip}");
        }
    }

    #[test]
    fn tailscale_and_link_local_never_reach_local_urls() {
        let addrs: Vec<Ipv4Addr> = ["100.64.0.1", "100.127.255.254", "169.254.10.20", "192.168.1.20", "10.1.2.3"]
            .iter()
            .map(|s| s.parse().unwrap())
            .collect();
        assert_eq!(websocket_urls(&addrs, 8765), ["ws://192.168.1.20:8765", "ws://10.1.2.3:8765"]);
    }

    #[test]
    fn urls_use_the_given_port_and_dedupe() {
        let a: Ipv4Addr = "192.168.0.9".parse().unwrap();
        assert_eq!(websocket_urls(&[a, a], 8799), ["ws://192.168.0.9:8799"]);
    }

    fn ad(name: &str, description: &str, ip: &str) -> AdapterAddress {
        AdapterAddress { name: name.into(), description: description.into(), ip: ip.parse().unwrap() }
    }

    #[test]
    fn virtual_adapters_are_dropped_by_name_or_description() {
        let adapters = [
            ad("Ethernet", "Intel(R) Ethernet Connection I219-V", "192.168.1.20"),
            ad("vEthernet (WSL)", "Hyper-V Virtual Ethernet Adapter", "172.24.80.1"),
            ad("vEthernet (Default Switch)", "", "172.17.0.1"),
            ad("VETHERNET (Docker)", "", "10.0.75.1"),
            ad("Ethernet 3", "VirtualBox Host-Only Ethernet Adapter", "192.168.56.1"),
            ad("VMware Network Adapter VMnet8", "", "192.168.200.1"),
            ad("Ethernet 4", "Npcap Loopback Adapter", "10.9.9.9"),
            ad("Wi-Fi", "Intel(R) Wi-Fi 6 AX201", "10.0.0.7"),
        ];
        assert_eq!(websocket_urls_for(&adapters, 8765), ["ws://192.168.1.20:8765", "ws://10.0.0.7:8765"]);
    }

    #[test]
    fn real_adapter_names_are_kept() {
        for (n, d) in [("Ethernet", ""), ("Wi-Fi", "Realtek 8822CE"), ("Ethernet 2", "USB 10/100/1000 LAN")] {
            assert!(!is_virtual_adapter(n, d), "{n} / {d}");
        }
        assert!(is_virtual_adapter("x", "Hyper-V Virtual Ethernet Adapter"));
        assert!(is_virtual_adapter("vEthernet", ""));
        assert!(is_virtual_adapter("Docker NAT", ""));
    }

    #[test]
    fn interface_listing_never_contains_loopback() {
        assert!(interface_ipv4s().iter().all(|a| !a.is_loopback()));
    }
}
