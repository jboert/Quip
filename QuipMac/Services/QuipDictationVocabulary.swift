import Foundation

/// Mac-side Quip dictation vocabulary used to bias the WhisperKit decode toward
/// domain terms at GENERATION time (the remote PTT path). The iOS corrector only
/// rewrites the final transcript after the fact; seeding the decoder with a
/// conditioning prompt lets these spellings win ties before they ever mangle.
///
/// Source of truth mirror: `QuipiOS/Resources/dictation-vocab.txt`. Kept as a
/// small hardcoded list (v1) so the Mac has no bundle-resource dependency — when
/// you grow the iOS file, mirror the dev/Quip terms here too.
///
/// Foundation-only by design (no `import WhisperKit`): the token builder is a
/// pure function injected with the tokenizer's `encode`, so it unit-tests via a
/// standalone `swift` run without a loaded model.
enum QuipDictationVocabulary {

    /// Canonical spellings worth biasing the decoder toward. Mirrors the iOS
    /// contextualStrings vocabulary (dictation-vocab.txt).
    static let terms: [String] = [
        "SwiftUI", "Xcode", "WebSocket", "Claude", "Quip", "monospace",
        "iOS", "macOS", "TestFlight", "GitHub", "WKWebView", "UIKit",
        "SFSpeechRecognizer", "AVFoundation", "Whisper", "Bonjour",
        "Tailscale", "QRCode", "PTT", "Bluetooth", "Codex", "Grok",
        "Cursor", "Kokoro", "Simulator", "keystroke", "Xcodegen",
        "entitlements", "APNs", "keychain", "devicectl",
    ]

    /// The conditioning prompt fed to WhisperKit. A comma-joined vocabulary list
    /// reads to the decoder as prior context (the Whisper `initial_prompt`
    /// convention), nudging it toward these terms.
    static var promptText: String {
        terms.joined(separator: ", ")
    }

    /// Build `DecodingOptions.promptTokens` from the vocabulary, mirroring the
    /// WhisperKit CLI recipe: prepend a leading space, encode, then drop any
    /// special tokens (>= `specialTokenBegin`) that would corrupt the prefill.
    ///
    /// Pure + dependency-injected (`encode`) so it is testable without a model.
    /// Returns `nil` when the encode yields nothing usable, so a degraded
    /// tokenizer falls back to the unbiased decode (no crash, no regression).
    static func promptTokens(
        encode: (String) -> [Int],
        specialTokenBegin: Int
    ) -> [Int]? {
        let text = " " + promptText.trimmingCharacters(in: .whitespaces)
        let tokens = encode(text).filter { $0 < specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }
}
