import Foundation

/// Redacts common secret patterns from terminal output before transmission.
enum SecretRedactor {
    private static let patterns: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            // OpenAI API keys (sk-...)
            (#"sk-[A-Za-z0-9_-]{20,}"#, "[REDACTED]"),
            // GitHub personal access tokens
            (#"ghp_[A-Za-z0-9]{36,}"#, "[REDACTED]"),
            // GitHub OAuth tokens
            (#"gho_[A-Za-z0-9]{36,}"#, "[REDACTED]"),
            // GitHub app tokens
            (#"ghs_[A-Za-z0-9]{36,}"#, "[REDACTED]"),
            // GitHub refresh tokens
            (#"ghr_[A-Za-z0-9]{36,}"#, "[REDACTED]"),
            // AWS access key IDs
            (#"AKIA[A-Z0-9]{16}"#, "[REDACTED]"),
            // AWS secret keys (after common env var patterns)
            (#"(?i)(aws[_-]?secret[_-]?access[_-]?key\s*[=:]\s*)[A-Za-z0-9/+=]{30,}"#, "$1[REDACTED]"),
            (#"(?i)(aws[_-]?access[_-]?key[_-]?id\s*[=:]\s*)[A-Za-z0-9]{16,}"#, "$1[REDACTED]"),
            // Bearer tokens
            (#"(?i)(Bearer\s+)[A-Za-z0-9._\-+/=]{20,}"#, "$1[REDACTED]"),
            // Generic token: / token= patterns
            (#"(?i)(token\s*[=:]\s*)[A-Za-z0-9._\-+/=]{20,}"#, "$1[REDACTED]"),
        ]
        return defs.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    static func redact(_ text: String) -> String {
        var result = text
        for (regex, replacement) in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
