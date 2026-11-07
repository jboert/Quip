//! Pairing link (`Shared/PairingPayload.swift`):
//! `quip://pair?url=<base64, padding stripped>&pin=<pin>`.
//!
//! The spec (6) says "base64url"; `PairingPayload` uses STANDARD base64
//! (`base64EncodedString()`) with `=` stripped, and the phone decodes with
//! `Data(base64Encoded:)`, which rejects `-` and `_`. Swift wins: standard
//! alphabet. `+` and `/` are legal in a URL query, so nothing is
//! percent-encoded for the alphabet; other bytes are, as `URLComponents` would.

use base64::alphabet;
use base64::engine::general_purpose::{GeneralPurpose, GeneralPurposeConfig, STANDARD};
use base64::engine::DecodePaddingMode;
use base64::Engine;

/// `Data(base64Encoded:)`: standard alphabet, whitespace rejected, but
/// non-canonical trailing bits accepted (`Yh` decodes as `Yg`;
/// `vectors/pairing.json`). The default engine rejects those.
const FOUNDATION_DECODE: GeneralPurpose = GeneralPurpose::new(
    &alphabet::STANDARD,
    GeneralPurposeConfig::new()
        .with_decode_allow_trailing_bits(true)
        .with_decode_padding_mode(DecodePaddingMode::RequireCanonical),
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingPayload {
    pub url: String,
    pub pin: String,
}

/// RFC 3986 query characters `URLComponents` leaves alone, minus `&`, `=`,
/// `+` and `#` so a value cannot split the query.
fn encode_query_value(v: &str) -> String {
    let mut out = String::new();
    for b in v.bytes() {
        let keep = b.is_ascii_alphanumeric() || b"-._~!$'()*,;:@/?".contains(&b);
        if keep {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn decode_query_value(v: &str) -> Option<String> {
    let bytes = v.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = v.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

impl PairingPayload {
    pub fn new(url: impl Into<String>, pin: impl Into<String>) -> Self {
        Self { url: url.into(), pin: pin.into() }
    }

    /// `encodedURL()`.
    pub fn encoded_url(&self) -> String {
        // The standard alphabet is [A-Za-z0-9+/]: all legal in a query, and
        // Swift's URLQueryItem leaves `+` alone (the phone does not read it as
        // a space), so the value goes in as-is.
        let b64 = STANDARD.encode(self.url.as_bytes()).replace('=', "");
        format!("quip://pair?url={}&pin={}", b64, encode_query_value(&self.pin))
    }

    /// `decode(_:)`: nil for anything that is not a `quip://pair` link with
    /// both fields and decodable base64.
    pub fn decode(raw: &str) -> Option<PairingPayload> {
        let rest = raw.strip_prefix("quip://pair")?;
        let query = rest.strip_prefix('?')?;
        let mut url_b64 = None;
        let mut pin = None;
        for item in query.split('&') {
            let (k, v) = item.split_once('=').unwrap_or((item, ""));
            match k {
                "url" if url_b64.is_none() => url_b64 = Some(decode_query_value(v)?),
                "pin" if pin.is_none() => pin = Some(decode_query_value(v)?),
                _ => {}
            }
        }
        let (url_b64, pin) = (url_b64?, pin?);
        if pin.is_empty() {
            return None;
        }
        // Re-pad to a multiple of 4. Foundation also accepts a value that
        // already carries its padding (`vectors/pairing.json`, "percent-encoded
        // base64 is decoded first": `d3M6Ly9h==`), so padding is stripped first.
        let bare = url_b64.trim_end_matches('=');
        let pad = (4 - bare.len() % 4) % 4;
        let padded = format!("{bare}{}", "=".repeat(pad));
        let data = FOUNDATION_DECODE.decode(padded).ok()?;
        let url = String::from_utf8(data).ok()?;
        Some(PairingPayload { url, pin })
    }
}

/// The URL the QR carries (spec 6): the first LAN URL, else the first
/// Tailscale one.
pub fn choose_pairing_url(lan: &[String], tailscale: &[String]) -> Option<String> {
    lan.first().or_else(|| tailscale.first()).cloned()
}

#[cfg(test)]
mod tests {
    //! `Shared/Tests/PairingPayloadTests.swift`.
    #![allow(non_snake_case)]
    use super::*;

    fn b64(s: &str) -> String {
        STANDARD.encode(s).replace('=', "")
    }

    #[test]
    fn testRoundTripPreservesURLAndPIN() {
        let o = PairingPayload::new("wss://abc-def.trycloudflare.com/ws", "482913");
        assert_eq!(PairingPayload::decode(&o.encoded_url()), Some(o));
    }

    #[test]
    fn testRoundTripPlainLANURL() {
        let o = PairingPayload::new("ws://192.168.1.42:8765", "000000");
        assert_eq!(PairingPayload::decode(&o.encoded_url()), Some(o));
    }

    #[test]
    fn testEncodedURLHasQuipPairShapeAndStrippedPadding() {
        let e = PairingPayload::new("wss://example.ts.net/ws", "123456").encoded_url();
        assert!(e.starts_with("quip://pair?url="));
        let url_value = e.split("url=").nth(1).unwrap().split('&').next().unwrap();
        assert!(!url_value.contains('='));
    }

    #[test]
    fn fake_mac_readme_link_matches() {
        // tools/fake-mac/README.md: `d3M6Ly8xMjcuMC4wLjE6ODc5OQ` is ws://127.0.0.1:8799.
        assert_eq!(
            PairingPayload::new("ws://127.0.0.1:8799", "11112222").encoded_url(),
            "quip://pair?url=d3M6Ly8xMjcuMC4wLjE6ODc5OQ&pin=11112222"
        );
    }

    #[test]
    fn standard_alphabet_not_url_safe() {
        // ">>>?" encodes to "Pj4+Pw" in standard base64 ("Pj4-Pw" in url-safe).
        let e = PairingPayload::new(">>>?", "1").encoded_url();
        assert!(e.contains("url=Pj4+Pw&"), "{e}");
        assert_eq!(PairingPayload::decode(&e).unwrap().url, ">>>?");
    }

    #[test]
    fn testHandCraftedUnpaddedBase64DecodesWithRepadding() {
        let url = "wss://host.local:8765/ws";
        let raw = format!("quip://pair?url={}&pin=778899", b64(url));
        let d = PairingPayload::decode(&raw).unwrap();
        assert_eq!(d.url, url);
        assert_eq!(d.pin, "778899");
    }

    #[test]
    fn testWrongSchemeReturnsNil() {
        assert_eq!(PairingPayload::decode(&format!("https://pair?url={}&pin=123456", b64("wss://x/ws"))), None);
    }

    #[test]
    fn testWrongHostReturnsNil() {
        assert_eq!(PairingPayload::decode(&format!("quip://window?url={}&pin=123456", b64("wss://x/ws"))), None);
    }

    #[test]
    fn testMissingURLReturnsNil() {
        assert_eq!(PairingPayload::decode("quip://pair?pin=123456"), None);
    }

    #[test]
    fn testMissingPINReturnsNil() {
        assert_eq!(PairingPayload::decode(&format!("quip://pair?url={}", b64("wss://x/ws"))), None);
    }

    #[test]
    fn testEmptyPINReturnsNil() {
        assert_eq!(PairingPayload::decode(&format!("quip://pair?url={}&pin=", b64("wss://x/ws"))), None);
    }

    #[test]
    fn testNonBase64URLReturnsNil() {
        assert_eq!(PairingPayload::decode("quip://pair?url=!!!!&pin=123456"), None);
    }

    #[test]
    fn testPlainWSURLDecodesToNil() {
        assert_eq!(PairingPayload::decode("ws://192.168.1.42:8765"), None);
    }

    #[test]
    fn testPlainWSSURLDecodesToNil() {
        assert_eq!(PairingPayload::decode("wss://abc.trycloudflare.com/ws"), None);
    }

    #[test]
    fn testGarbageStringDecodesToNil() {
        assert_eq!(PairingPayload::decode("not a url at all"), None);
    }

    #[test]
    fn pairing_url_prefers_lan() {
        let lan = vec!["ws://192.168.1.20:8765".to_string()];
        let ts = vec!["ws://pc.tail.ts.net:8765".to_string()];
        assert_eq!(choose_pairing_url(&lan, &ts), Some(lan[0].clone()));
        assert_eq!(choose_pairing_url(&[], &ts), Some(ts[0].clone()));
        assert_eq!(choose_pairing_url(&[], &[]), None);
    }

    #[test]
    fn percent_decoding_and_first_item_wins() {
        let raw = format!("quip://pair?pin=1%322&url={}&pin=9&url={}", b64("ws://a"), b64("ws://b"));
        assert_eq!(PairingPayload::decode(&raw), Some(PairingPayload::new("ws://a", "122")));
        assert_eq!(PairingPayload::decode(&format!("quip://pair?url={}&pin=%4", b64("ws://a"))), None);
    }

    #[test]
    fn repadding_for_each_length() {
        for url in ["ws://a", "ws://ab", "ws://abc"] {
            let raw = format!("quip://pair?url={}&pin=1", b64(url));
            assert_eq!(PairingPayload::decode(&raw).map(|p| p.url), Some(url.to_string()), "{url}");
        }
    }

    #[test]
    fn non_canonical_trailing_bits_are_accepted_like_foundation() {
        assert_eq!(
            PairingPayload::decode("quip://pair?url=d3M6Ly9hYh&pin=1").map(|p| p.url).as_deref(),
            Some("ws://ab")
        );
        assert_eq!(PairingPayload::decode("quip://pair?url=d3M6Ly9h%20&pin=1"), None, "whitespace rejected");
    }
}
