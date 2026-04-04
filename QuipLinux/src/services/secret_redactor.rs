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
    ];

    defs.into_iter()
        .filter_map(|(pattern, replacement)| {
            Regex::new(pattern).ok().map(|regex| RedactPattern { regex, replacement })
        })
        .collect()
});

/// Redact common secret patterns from text, replacing them with [REDACTED].
pub fn redact(text: &str) -> String {
    let mut result = text.to_string();
    for p in PATTERNS.iter() {
        result = p.regex.replace_all(&result, p.replacement).into_owned();
    }
    result
}
