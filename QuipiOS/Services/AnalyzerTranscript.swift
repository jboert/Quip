import Foundation

/// The running text of one SpeechAnalyzer session. Finalized results are
/// permanent and accumulate; the volatile result is the analyzer's current
/// guess for audio not yet finalized, and each new one replaces the last.
/// Unlike SFSpeech partials, nothing finalized is ever dropped on a pause.
struct AnalyzerTranscript {
    private var finalized: [String] = []
    private var volatile = ""

    mutating func apply(_ text: String, isFinal: Bool) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !piece.isEmpty { finalized.append(piece) }
            volatile = ""
        } else if !piece.isEmpty {
            volatile = piece
        }
    }

    var display: String {
        (finalized + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ")
    }
}

/// Whether the on-device SpeechTranscriber model can run right now.
enum AnalyzerReadiness: Equatable {
    case ready
    /// Locale is supported but the model asset is not installed yet.
    case needsDownload
    case unsupported
}

enum SpeechEngine: Equatable { case analyzer, legacy }

/// Picks the local-path recognizer for one PTT press. Anything short of a
/// ready analyzer uses the legacy recognizer, so a press is never silent.
enum SpeechEnginePolicy {
    static func choose(osSupportsAnalyzer: Bool, readiness: AnalyzerReadiness,
                       legacyForced: Bool) -> SpeechEngine {
        guard osSupportsAnalyzer, !legacyForced, readiness == .ready else { return .legacy }
        return .analyzer
    }
}
