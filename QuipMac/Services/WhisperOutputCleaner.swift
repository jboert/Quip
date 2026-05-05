import Foundation

/// Strips WhisperKit's bracketed / parenthesized non-speech annotations
/// (`[BLANK_AUDIO]`, `(silence)`, `[NO_SPEECH]`, `[MUSIC]`, …) from a raw
/// transcript before it leaves the Mac. These tokens are an artifact of
/// the Whisper decoder, not user speech — typing them into the user's
/// terminal looks like garbage prompts.
///
/// Conservative on purpose: only strips a closed list of known Whisper
/// tokens, never freeform user text. Case-insensitive. Tolerates
/// whitespace, underscores, and hyphens between the words.
enum WhisperOutputCleaner {

    /// Whisper non-speech token patterns. Each is wrapped in either
    /// brackets or parentheses by the decoder; we accept both forms.
    /// Add new patterns here as new tokens are discovered in the wild —
    /// don't loosen the regex into a catch-all (it will eat real user
    /// text spoken in parentheses).
    private static let tokens = [
        "BLANK_AUDIO", "BLANK AUDIO",
        "NO_SPEECH", "NO SPEECH",
        "SILENCE",
        "MUSIC",
        "INAUDIBLE",
        "APPLAUSE",
        "LAUGHTER",
        "CROSSTALK",
        "BACKGROUND_NOISE", "BACKGROUND NOISE",
        "FOREIGN_LANGUAGE", "FOREIGN LANGUAGE",
        "INDISTINCT",
    ]

    /// Pre-compiled per-token regex options. `[regex, caseInsensitive]`.
    private static let regexOptions: NSRegularExpression.Options = [.caseInsensitive]

    static func clean(_ raw: String) -> String {
        var s = raw
        for token in tokens {
            // Allow underscore OR space OR hyphen between words inside
            // the token (whisper sometimes emits `[NO-SPEECH]` etc.).
            let lenient = token.replacingOccurrences(of: "_", with: "[ _-]?")
                                .replacingOccurrences(of: " ", with: "[ _-]?")
            // Bracketed form: `[TOKEN]` with optional internal whitespace.
            let bracketed = #"\[\s*"# + lenient + #"\s*\]"#
            // Parenthesized form: `(token)` with optional internal whitespace.
            let parenthesized = #"\(\s*"# + lenient + #"\s*\)"#
            s = s.replacingOccurrences(of: bracketed, with: "",
                                       options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: parenthesized, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        // Collapse any whitespace gaps left by removed tokens, then trim.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
