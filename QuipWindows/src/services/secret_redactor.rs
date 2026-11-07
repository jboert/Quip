//! Redaction before anything reaches a log.
//!
//! `redact` is copied from `QuipLinux/src/services/secret_redactor.rs`, whose
//! patterns are `QuipMac/Services/SecretRedactor.swift` plus the auth-envelope
//! PIN rule (Mac commit `b6a8498`). `redact_ipv4` / `redact_hostname` port
//! `QuipMac/Services/LogRedactor.swift` (spec 10.3 maps this module to
//! `LogRedactorTests`).

use regex::Regex;
use std::sync::LazyLock;

struct RedactPattern {
    regex: Regex,
    replacement: &'static str,
}

static PATTERNS: LazyLock<Vec<RedactPattern>> = LazyLock::new(|| {
    let defs: Vec<(&str, &str)> = vec![
        // OpenAI API keys (sk-...)
        (r"sk-[A-Za-z0-9_\-]{20,}", "[REDACTED]"),
        // GitHub personal access tokens
        (r"ghp_[A-Za-z0-9]{36,}", "[REDACTED]"),
        // GitHub OAuth tokens
        (r"gho_[A-Za-z0-9]{36,}", "[REDACTED]"),
        // GitHub app tokens
        (r"ghs_[A-Za-z0-9]{36,}", "[REDACTED]"),
        // GitHub refresh tokens
        (r"ghr_[A-Za-z0-9]{36,}", "[REDACTED]"),
        // AWS access key IDs
        (r"AKIA[A-Z0-9]{16}", "[REDACTED]"),
        // AWS secret keys (after common env var patterns)
        (r"(?i)(aws[_\-]?secret[_\-]?access[_\-]?key\s*[=:]\s*)[A-Za-z0-9/+=]{30,}", "${1}[REDACTED]"),
        (r"(?i)(aws[_\-]?access[_\-]?key[_\-]?id\s*[=:]\s*)[A-Za-z0-9]{16,}", "${1}[REDACTED]"),
        // Bearer tokens
        (r"(?i)(Bearer\s+)[A-Za-z0-9._\-+/=]{20,}", "${1}[REDACTED]"),
        // Generic token: / token= patterns
        (r"(?i)(token\s*[=:]\s*)[A-Za-z0-9._\-+/=]{20,}", "${1}[REDACTED]"),
        // PIN inside an auth WebSocket envelope (Mac commit b6a8498).
        (r#""pin"\s*:\s*"[^"]*""#, r#""pin":"[REDACTED]""#),
    ];
    defs.into_iter()
        .filter_map(|(pattern, replacement)| Regex::new(pattern).ok().map(|regex| RedactPattern { regex, replacement }))
        .collect()
});

/// Redact common secret patterns, replacing them with `[REDACTED]`.
pub fn redact(text: &str) -> String {
    let mut result = text.to_string();
    for p in PATTERNS.iter() {
        result = p.regex.replace_all(&result, p.replacement).into_owned();
    }
    result
}

static IPV4: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b").ok());

/// `LogRedactor.redactIPv4`: mask the last two octets of every IPv4, skipping
/// matches with an octet over 255 (version strings).
pub fn redact_ipv4(text: &str) -> String {
    let Some(re) = IPV4.as_ref() else { return text.to_string() };
    re.replace_all(text, |c: &regex::Captures<'_>| {
        let oct = |i: usize| c.get(i).map(|m| m.as_str()).unwrap_or("");
        let valid = (1..=4).all(|i| oct(i).parse::<u32>().map(|n| n <= 255).unwrap_or(false));
        if valid {
            format!("{}.{}.x.x", oct(1), oct(2))
        } else {
            c.get(0).map(|m| m.as_str().to_string()).unwrap_or_default()
        }
    })
    .into_owned()
}

/// `LogRedactor.redactHostname`: case-insensitive literal replace with
/// `<host>`; a no-op for names shorter than 3 characters.
pub fn redact_hostname(text: &str, hostname: &str) -> String {
    if hostname.chars().count() < 3 {
        return text.to_string();
    }
    match Regex::new(&format!("(?i){}", regex::escape(hostname))) {
        Ok(re) => re.replace_all(text, "<host>").into_owned(),
        Err(_) => text.to_string(),
    }
}

/// `LogRedactor.redactAll`.
pub fn redact_all(text: &str, hostname: &str) -> String {
    redact_hostname(&redact_ipv4(text), hostname)
}

#[cfg(test)]
mod tests {
    //! The QuipLinux cases, then `QuipMac/Tests/LogRedactorTests.swift`.
    #![allow(non_snake_case)]
    use super::*;

    #[test]
    fn redacts_auth_pin_in_websocket_envelope() {
        let red = redact(r#"{"type":"auth","pin":"123456"}"#);
        assert!(!red.contains("123456"), "PIN leaked: {red}");
        assert!(red.contains("[REDACTED]"));
    }

    #[test]
    fn redacts_auth_pin_with_spaces() {
        assert!(!redact(r#"{"pin" : "abcdef"}"#).contains("abcdef"));
    }

    #[test]
    fn passes_through_non_secret_text() {
        let s = "no secrets here, just terminal output";
        assert_eq!(redact(s), s);
    }

    #[test]
    fn redacts_bearer_token() {
        let red = redact("authorization: Bearer abcdefghijklmnopqrstuvwxyz");
        assert!(red.contains("[REDACTED]"));
        assert!(!red.contains("abcdefghijklmnopqrstuvwxyz"));
    }

    #[test]
    fn redacts_each_key_family() {
        for s in [
            "sk-abcdefghijklmnopqrstuvwx",
            &format!("ghp_{}", "a".repeat(36)),
            &format!("gho_{}", "a".repeat(36)),
            &format!("ghs_{}", "a".repeat(36)),
            &format!("ghr_{}", "a".repeat(36)),
            "AKIAABCDEFGHIJKLMNOP",
        ] {
            assert_eq!(redact(s), "[REDACTED]", "{s}");
        }
        assert_eq!(redact(&format!("AWS_SECRET_ACCESS_KEY={}", "a".repeat(30))), "AWS_SECRET_ACCESS_KEY=[REDACTED]");
        assert_eq!(redact("aws_access_key_id: ABCDEFGHIJKLMNOP"), "aws_access_key_id: [REDACTED]");
        assert_eq!(redact(&format!("token={}", "z".repeat(20))), "token=[REDACTED]");
    }

    #[test]
    fn short_lookalikes_are_left_alone() {
        assert_eq!(redact("sk-short"), "sk-short");
        assert_eq!(redact("token=abc"), "token=abc");
    }

    #[test]
    fn test_redactIPv4_lanAddress_masksLastTwoOctets() {
        assert_eq!(
            redact_ipv4("Connection state: failed for 192.168.1.134:52001"),
            "Connection state: failed for 192.168.x.x:52001"
        );
    }

    #[test]
    fn test_redactIPv4_tailscaleCgnat_masksLastTwoOctets() {
        assert_eq!(redact_ipv4("peer endpoint 100.101.102.105 reachable"), "peer endpoint 100.101.x.x reachable");
    }

    #[test]
    fn test_redactIPv4_publicAddress_masksLastTwoOctets() {
        assert_eq!(redact_ipv4("outbound 8.8.8.8 ttl 64"), "outbound 8.8.x.x ttl 64");
    }

    #[test]
    fn test_redactIPv4_multipleIpsInOneLine_allMasked() {
        assert_eq!(redact_ipv4("10.0.0.5 -> 192.168.1.1 via 100.64.0.1"), "10.0.x.x -> 192.168.x.x via 100.64.x.x");
    }

    #[test]
    fn test_redactIPv4_invalidOctet_leftAlone() {
        assert_eq!(redact_ipv4("version 1.2.999.4"), "version 1.2.999.4");
    }

    #[test]
    fn test_redactIPv4_noIpv4_unchanged() {
        let s = "[2026-05-05T19:06:47Z] Connection ready (pending auth)";
        assert_eq!(redact_ipv4(s), s);
    }

    #[test]
    fn test_redactIPv4_idempotent() {
        let once = redact_ipv4("from 10.0.0.5");
        assert_eq!(redact_ipv4(&once), once);
    }

    #[test]
    fn test_redactHostname_replacesCaseInsensitive() {
        assert_eq!(
            redact_hostname("Host: test-mbp generated this report on Test-MBP", "test-mbp"),
            "Host: <host> generated this report on <host>"
        );
    }

    #[test]
    fn test_redactHostname_emptyOrShort_noOp() {
        let s = "abcde fghij";
        assert_eq!(redact_hostname(s, ""), s);
        assert_eq!(redact_hostname(s, "ab"), s);
    }

    #[test]
    fn test_redactHostname_noMatch_unchanged() {
        let s = "no host name here";
        assert_eq!(redact_hostname(s, "missing-host"), s);
    }

    #[test]
    fn redact_hostname_treats_the_name_literally() {
        assert_eq!(redact_hostname("a.b.c axbxc", "a.b.c"), "<host> axbxc");
    }

    #[test]
    fn test_redactAll_runsBothPasses() {
        assert_eq!(
            redact_all("test-mbp connected from 192.168.1.134", "test-mbp"),
            "<host> connected from 192.168.x.x"
        );
    }
}
