import Foundation

/// Corrects high-confidence mishearings of Quip / dev vocabulary in a FINAL
/// dictation transcript.
///
/// The remote Whisper path has no `contextualStrings` biasing (that lives only
/// on the local SFSpeech `SFSpeechAudioBufferRecognitionRequest`), so terms the
/// on-device recognizer would get right come back mangled when connected. This
/// value type closes that gap on BOTH paths by remapping a *curated* set of
/// unambiguous mishearings to their canonical spelling.
///
/// Design constraints (US-005):
/// - Matching is **case-insensitive** and **whole-word / whole-phrase only**
///   (regex `\b` boundaries) so a substring inside a larger word is never
///   rewritten (e.g. "xcoder" stays "xcoder").
/// - Only the matched span is replaced, so all surrounding text — including the
///   leading/trailing whitespace the send pipeline relies on — is preserved.
/// - **Conservative**: every entry is unambiguous in a Quip/dev context. We
///   never remap a token that is a normal English word on its own. The single
///   "real word" remap, `monotype -> monospace`, is the user's own documented
///   dictation artifact, not generic prose.
/// - Applied to the FINAL transcript only (never partials) at the convergence
///   point in `SpeechService.stopRecording` — for both the local and the
///   separate remote (`session.stop`) exit.
struct TranscriptCorrector {

    /// Shared instance built from the curated default rule set.
    static let shared = TranscriptCorrector()

    /// A single mishearing rule: a compiled case-insensitive pattern and the
    /// canonical replacement it maps to.
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let rules: [Rule]

    /// Curated mishearing-pattern -> canonical-term map. Order matters: a longer
    /// phrase MUST precede any shorter rule it contains, so the specific form
    /// wins (e.g. "x code gen" -> "Xcodegen" before "x code" -> "Xcode").
    ///
    /// Patterns are the *inner* body only; `init` wraps each in `\b…\b`, so
    /// keep them boundary-free here. `\s+` matches the spoken word gap; `\s*`
    /// also accepts the run-together single-token form the recognizer sometimes
    /// emits.
    static let defaultPatternMap: [(pattern: String, replacement: String)] = [
        (#"x\s*code\s*gen"#, "Xcodegen"),   // before "x code" / "xcode"
        (#"tail\s+scale"#,   "Tailscale"),
        (#"mono\s*type"#,    "monospace"),  // "mono type" / "monotype" (documented artifact)
        (#"web\s*socket"#,   "WebSocket"),  // "web socket" / "websocket"
        (#"co[-\s]+dex"#,    "Codex"),      // "co-dex" / "co dex"
        (#"codex"#,          "Codex"),      // capitalization-only: "codex" is a real word, but in
                                            // Quip dictation it is always the CLI (audit.log 2026-07-10)
        (#"x\s*code"#,       "Xcode"),      // "x code" / "xcode"
        (#"fin+\s+tech"#,    "Fintech"),    // "fin tech" / "finn tech" (two-token spoken form only)
        (#"whisperers"#,     "Whisper"),    // plural mishearing of "Whisper" (documented artifact)
    ]

    init(patternMap: [(pattern: String, replacement: String)] = TranscriptCorrector.defaultPatternMap) {
        rules = patternMap.compactMap { entry in
            // Whole-word / whole-phrase: anchor each pattern with word boundaries.
            guard let regex = try? NSRegularExpression(
                pattern: #"\b(?:"# + entry.pattern + #")\b"#,
                options: [.caseInsensitive]
            ) else {
                assertionFailure("TranscriptCorrector: bad pattern \(entry.pattern)")
                return nil
            }
            return Rule(regex: regex, replacement: entry.replacement)
        }
    }

    /// Apply every rule in order to `text`, returning the corrected string.
    /// Non-matching input (ordinary prose, empty, whitespace-only) is returned
    /// byte-for-byte unchanged.
    func correct(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            // Literal replacement template ($ and \ in canonical terms would be
            // template metacharacters — escape so they're treated literally).
            let template = NSRegularExpression.escapedTemplate(for: rule.replacement)
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }
}
