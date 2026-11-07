//! `phone.log` rows (`QuipMac/Services/PhoneLogSink.swift`): one row per phone
//! line, stamped with the host's receive time; embedded newlines flattened so a
//! line cannot forge rows; length and count capped so a phone cannot flood the
//! disk; every line through `SecretRedactor`.

pub const MAX_LINES_PER_MESSAGE: usize = 200;
pub const MAX_LINE_LENGTH: usize = 500;

pub fn format(lines: &[String], unix_seconds: f64) -> String {
    let stamp = super::clock::iso8601(unix_seconds);
    let mut out = String::new();
    for raw in lines.iter().take(MAX_LINES_PER_MESSAGE) {
        let flat = super::secret_redactor::redact(raw).replace(['\r', '\n'], " ");
        // Swift counts Characters; chars is the closest cheap stand-in.
        let capped = if flat.chars().count() > MAX_LINE_LENGTH {
            let mut s: String = flat.chars().take(MAX_LINE_LENGTH).collect();
            s.push('…');
            s
        } else {
            flat
        };
        out.push_str(&stamp);
        out.push(' ');
        out.push_str(&capped);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    //! `QuipMac/Tests/PhoneLogSinkTests.swift`.
    #![allow(non_snake_case)]
    use super::*;

    const NOW: f64 = 1_800_000_000.0;

    fn v(s: &[&str]) -> Vec<String> {
        s.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn test_eachPhoneLineBecomesOneStampedRow() {
        let out = format(&v(&["a", "b"]), NOW);
        let rows: Vec<&str> = out.split('\n').collect();
        assert_eq!(rows.len(), 3);
        assert!(rows[0].ends_with(" a"));
        assert!(rows[0].starts_with("2027-01-15T08:00:00Z"));
        assert!(rows[1].ends_with(" b"));
    }

    #[test]
    fn test_embeddedNewlinesCannotForgeRows() {
        let out = format(&v(&["one\ntwo\rthree"]), NOW);
        assert_eq!(out.matches('\n').count(), 1);
        assert!(out.contains("one two three"));
    }

    #[test]
    fn test_longLinesAndFloodsAreCapped() {
        let long = "x".repeat(MAX_LINE_LENGTH + 50);
        let row = format(&[long], NOW);
        assert!(row.chars().count() < MAX_LINE_LENGTH + 60);
        assert!(row.contains('…'));
        let exact = format(&["y".repeat(MAX_LINE_LENGTH)], NOW);
        assert!(!exact.contains('…'), "exactly at the cap is not truncated");
        let flood = vec!["y".to_string(); MAX_LINES_PER_MESSAGE + 10];
        assert_eq!(format(&flood, NOW).matches('\n').count(), MAX_LINES_PER_MESSAGE);
    }

    #[test]
    fn test_emptyMessageWritesNothing() {
        assert_eq!(format(&[], NOW), "");
    }

    #[test]
    fn secrets_are_redacted() {
        let out = format(&v(&["Bearer abcdefghijklmnopqrstuvwxyz"]), NOW);
        assert!(!out.contains("abcdefghijklmnopqrstuvwxyz"));
    }
}
