//! Spec 6 on real Windows: the pairing QR window and Bonjour advertising.
//! Gated by `QUIP_WIN_UI=1` like the other Win32 tests.
#![cfg(windows)]

use std::net::Ipv4Addr;
use std::time::{Duration, Instant};

use mdns_sd::{ServiceDaemon, ServiceEvent};
use quip_windows::services::local_addresses::interface_ipv4s;
use quip_windows::services::mdns_advertiser::{Advert, MdnsAdvertiser, SERVICE_TYPE};
use quip_windows::tray::qr::pairing_qr;
use quip_windows::tray::qr_window;

fn ui_enabled() -> bool {
    if std::env::var("QUIP_WIN_UI").as_deref() == Ok("1") {
        return true;
    }
    eprintln!("skipped: set QUIP_WIN_UI=1 to run the Win32 UI tests");
    false
}

#[test]
fn the_qr_window_opens_is_reused_is_never_listed_and_closes_on_esc() {
    if !ui_enabled() {
        return;
    }
    let content = pairing_qr(&[Ipv4Addr::new(192, 168, 0, 2)], 8765, "12345678");
    assert!(content.is_ok());
    qr_window::check_open_list_close(content).unwrap();
    // Without an address the window opens with the reason instead of a code.
    qr_window::check_open_list_close(pairing_qr(&[], 8765, "12345678")).unwrap();
}

#[test]
fn the_advertiser_starts_is_seen_on_the_lan_and_stops() {
    if !ui_enabled() {
        return;
    }
    let did = format!("QUIP-TEST-{}", std::process::id());
    let Some(advert) = Advert::new("quip-ci-test", &interface_ipv4s(), 8799, &did) else {
        eprintln!("skipped: this machine has no LAN address to advertise on");
        return;
    };
    let adv = MdnsAdvertiser::start(&advert).unwrap();
    let browser = ServiceDaemon::new().unwrap();
    let events = browser.browse(SERVICE_TYPE).unwrap();
    let until = Instant::now() + Duration::from_secs(15);
    let mut seen = None;
    while Instant::now() < until {
        if let Ok(ServiceEvent::ServiceResolved(info)) = events.recv_timeout(Duration::from_millis(500)) {
            if info.get_property_val_str("did") == Some(did.as_str()) {
                seen = Some(info);
                break;
            }
        }
    }
    let info = seen.expect("our own advertisement was not resolved within 15 s");
    assert_eq!(info.get_fullname(), adv.fullname());
    assert_eq!(info.get_port(), 8799);
    let ips: Vec<Ipv4Addr> = info.get_addresses_v4().into_iter().copied().collect();
    assert!(ips.iter().all(|ip| advert.ips.contains(ip)), "only LAN addresses are announced: {}", ips.len());
    drop(adv);
    let _ = browser.shutdown();
}
