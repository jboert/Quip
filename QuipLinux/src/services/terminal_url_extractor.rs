use regex::Regex;
use std::sync::OnceLock;

/// Extract openable URLs from scraped terminal text for the iOS URL tray.
///
/// Mirrors `QuipMac/Services/TerminalURLExtractor.swift` and the iOS
/// linkifier (QuipiOS/QuipApp.swift -> `linkifiedTerminalContent`):
/// accept `http(s)://…` and `mailto:…`, including bare emails which we emit
/// with an explicit `mailto:` prefix. Reject bare-TLD false positives like
/// `README.md` or `Quip.app` — keeping the rulesets in lockstep is a contract.
///
/// Returns URLs in document order, de-duplicated by absolute string.
pub fn extract(raw: &str) -> Vec<String> {
    if raw.is_empty() {
        return Vec::new();
    }

    static URL_RE: OnceLock<Regex> = OnceLock::new();
    static EMAIL_RE: OnceLock<Regex> = OnceLock::new();

    // Explicit http(s):// — the scheme must appear literally so bare
    // github.com doesn't get promoted to a link.
    let url_re = URL_RE.get_or_init(|| {
        Regex::new(r#"https?://[^\s<>"\[\]\|\\^`{}]+"#).unwrap()
    });
    // Either explicit "mailto:foo@bar" or a bare email — both end up emitted
    // with a "mailto:" prefix to match NSDataDetector behavior on the Mac.
    let email_re = EMAIL_RE.get_or_init(|| {
        Regex::new(r#"(?:mailto:)?[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#).unwrap()
    });

    // Collect (start_offset, normalized_url) so we can sort by document order.
    let mut hits: Vec<(usize, String)> = Vec::new();

    for m in url_re.find_iter(raw) {
        // Trim trailing punctuation that almost certainly isn't part of the URL
        // (commas, periods, closing parens). NSDataDetector does this too.
        let trimmed = trim_trailing_punct(m.as_str());
        hits.push((m.start(), trimmed.to_string()));
    }

    for m in email_re.find_iter(raw) {
        let s = m.as_str();
        let normalized = if s.starts_with("mailto:") {
            s.to_string()
        } else {
            format!("mailto:{s}")
        };
        hits.push((m.start(), normalized));
    }

    hits.sort_by_key(|(start, _)| *start);

    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(hits.len());
    for (_, url) in hits {
        if seen.insert(url.clone()) {
            out.push(url);
        }
    }
    out
}

fn trim_trailing_punct(s: &str) -> &str {
    let trim_chars = [',', '.', ';', ':', '!', '?', ')', ']', '>', '"', '\''];
    let mut end = s.len();
    while end > 0 {
        let last = s[..end].chars().next_back().unwrap();
        if trim_chars.contains(&last) {
            end -= last.len_utf8();
        } else {
            break;
        }
    }
    &s[..end]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn https_url_is_extracted() {
        assert_eq!(
            extract("see https://github.com/anthropic for context"),
            vec!["https://github.com/anthropic".to_string()]
        );
    }

    #[test]
    fn http_url_is_extracted() {
        assert_eq!(
            extract("fallback http://example.com here"),
            vec!["http://example.com".to_string()]
        );
    }

    #[test]
    fn file_path_is_not_extracted() {
        assert_eq!(extract("edit Sources/Foo.swift line 42"), Vec::<String>::new());
    }

    #[test]
    fn bare_domain_is_not_extracted() {
        assert_eq!(extract("go to github.com to clone"), Vec::<String>::new());
    }

    #[test]
    fn markdown_file_is_not_extracted() {
        assert_eq!(extract("see README.md for setup"), Vec::<String>::new());
    }

    #[test]
    fn app_bundle_is_not_extracted() {
        assert_eq!(extract("rebuild Quip.app and reinstall"), Vec::<String>::new());
    }

    #[test]
    fn bare_email_is_extracted_as_mailto() {
        assert_eq!(
            extract("contact noreply@anthropic.com for support"),
            vec!["mailto:noreply@anthropic.com".to_string()]
        );
    }

    #[test]
    fn explicit_mailto_is_extracted() {
        assert_eq!(
            extract("or use mailto:hi@example.com directly"),
            vec!["mailto:hi@example.com".to_string()]
        );
    }

    #[test]
    fn multiple_urls_in_order() {
        assert_eq!(
            extract("see https://a.com then https://b.com/path?q=1"),
            vec!["https://a.com".to_string(), "https://b.com/path?q=1".to_string()]
        );
    }

    #[test]
    fn duplicates_deduped() {
        assert_eq!(
            extract("https://a.com and again https://a.com end"),
            vec!["https://a.com".to_string()]
        );
    }

    #[test]
    fn empty_string() {
        assert_eq!(extract(""), Vec::<String>::new());
    }

    #[test]
    fn no_urls() {
        assert_eq!(extract("just terminal output, nothing linkable"), Vec::<String>::new());
    }

    #[test]
    fn trailing_period_stripped() {
        assert_eq!(
            extract("done at https://a.com."),
            vec!["https://a.com".to_string()]
        );
    }
}
