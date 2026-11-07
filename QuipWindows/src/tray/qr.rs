//! The pairing QR (spec 6) as data: which link it carries and its module
//! matrix. Pure, so both are tested on the Mac (the matrix is decoded back
//! with a QR reader in the tests); `tray::qr_window` only paints it.
//!
//! The link is `PairingPayload::encoded_url` of the first LAN URL, else the
//! first Tailscale one (`pairing::choose_pairing_url`), with the current PIN.

use std::net::Ipv4Addr;

use qrcode::{Color, EcLevel, QrCode};

use crate::services::local_addresses::{lan_and_tailscale, websocket_urls};
use crate::services::pairing::{choose_pairing_url, PairingPayload};

/// The quiet zone a reader needs around the code, in modules.
pub const QUIET_ZONE: usize = 4;

/// A square of modules, `true` = dark.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QrMatrix {
    width: usize,
    dark: Vec<bool>,
}

impl QrMatrix {
    /// `text` at error correction M (scans from a screen at arm's length).
    pub fn encode(text: &str) -> Result<QrMatrix, String> {
        let code = QrCode::with_error_correction_level(text.as_bytes(), EcLevel::M)
            .map_err(|e| format!("cannot make the QR: {e}"))?;
        let dark = code.to_colors().into_iter().map(|c| c == Color::Dark).collect();
        Ok(QrMatrix { width: code.width(), dark })
    }

    /// Modules per side, without the quiet zone.
    pub fn width(&self) -> usize {
        self.width
    }

    /// Whether module (`x`, `y`) is dark; outside the code is light.
    pub fn is_dark(&self, x: usize, y: usize) -> bool {
        x < self.width && y < self.width && self.dark[y * self.width + x]
    }
}

/// What the QR window shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingQr {
    /// The `quip://pair?…` link the QR carries.
    pub link: String,
    /// The `ws://` URL inside it, shown as text.
    pub url: String,
    pub pin: String,
    pub matrix: QrMatrix,
}

/// The URLs the QR may carry: LAN first (RFC 1918), then Tailscale.
pub fn candidate_urls(addresses: &[Ipv4Addr], port: u16) -> (Vec<String>, Vec<String>) {
    let (lan, tailscale) = lan_and_tailscale(addresses);
    let ts = tailscale.into_iter().map(|ip| format!("ws://{ip}:{port}")).collect();
    (websocket_urls(&lan, port), ts)
}

/// The QR for this PC now. Err when it has neither a LAN nor a Tailscale
/// address (the window then says so instead of showing a code).
pub fn pairing_qr(addresses: &[Ipv4Addr], port: u16, pin: &str) -> Result<PairingQr, String> {
    let (lan, tailscale) = candidate_urls(addresses, port);
    let url = choose_pairing_url(&lan, &tailscale)
        .ok_or_else(|| "This PC has no LAN or Tailscale address, so there is nothing to pair with.".to_string())?;
    let link = PairingPayload::new(url.clone(), pin).encoded_url();
    let matrix = QrMatrix::encode(&link)?;
    Ok(PairingQr { link, url, pin: pin.to_string(), matrix })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Renders with the quiet zone at `scale` px per module and reads it
    /// back with a QR reader.
    fn read_back(m: &QrMatrix) -> String {
        let scale = 4;
        let side = (m.width() + 2 * QUIET_ZONE) * scale;
        let mut img = rqrr::PreparedImage::prepare_from_greyscale(side, side, |x, y| {
            let (mx, my) = (x / scale, y / scale);
            let dark = mx >= QUIET_ZONE && my >= QUIET_ZONE && m.is_dark(mx - QUIET_ZONE, my - QUIET_ZONE);
            if dark {
                0
            } else {
                255
            }
        });
        let grids = img.detect_grids();
        assert_eq!(grids.len(), 1, "one code in the picture");
        grids[0].decode().unwrap().1
    }

    fn ip(s: &str) -> Ipv4Addr {
        s.parse().unwrap()
    }

    #[test]
    fn the_matrix_reads_back_as_the_link() {
        let link = "quip://pair?url=d3M6Ly8xOTIuMTY4LjEuMjA6ODc2NQ&pin=12345678";
        let m = QrMatrix::encode(link).unwrap();
        assert_eq!(read_back(&m), link);
        assert!(m.width() >= 21 && (m.width() - 17).is_multiple_of(4), "a QR is 17 + 4n modules wide: {}", m.width());
        assert!(!m.is_dark(m.width(), 0), "outside the code is light");
        // Finder pattern: the top-left corner module is dark.
        assert!(m.is_dark(0, 0));
    }

    #[test]
    fn the_qr_carries_the_first_lan_url_and_the_pin() {
        let q = pairing_qr(&[ip("100.101.1.2"), ip("192.168.1.20"), ip("10.0.0.5")], 8765, "12345678").unwrap();
        assert_eq!(q.url, "ws://192.168.1.20:8765");
        assert_eq!(q.link, PairingPayload::new("ws://192.168.1.20:8765", "12345678").encoded_url());
        let back = PairingPayload::decode(&read_back(&q.matrix)).unwrap();
        assert_eq!((back.url.as_str(), back.pin.as_str()), ("ws://192.168.1.20:8765", "12345678"));
    }

    #[test]
    fn tailscale_only_when_there_is_no_lan_and_the_port_is_kept() {
        let q = pairing_qr(&[ip("8.8.8.8"), ip("100.101.1.2")], 9000, "1").unwrap();
        assert_eq!(q.url, "ws://100.101.1.2:9000");
        assert!(pairing_qr(&[ip("8.8.8.8"), ip("169.254.1.1")], 8765, "1").is_err());
        assert!(pairing_qr(&[], 8765, "1").is_err());
    }
}
