import Foundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Abstraction so `WhisperDictationService` can be unit-tested without a
/// real WhisperKit instance.
protocol WhisperTranscriber: Sendable {
    func transcribe(audioArray: [Float]) async throws -> String
}

#if canImport(WhisperKit)
final class WhisperKitTranscriber: WhisperTranscriber, @unchecked Sendable {
    private let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
    func transcribe(audioArray: [Float]) async throws -> String {
        // Bias the decode toward Quip vocabulary at generation time. This is
        // the REMOTE PTT path's only source of biasing — the iOS corrector only
        // rewrites the final transcript after the fact, and WhisperKit (unlike
        // the local SFSpeech request) has no contextualStrings hook. Guarded by
        // the optional tokenizer (nil until the model loads): no tokenizer ⇒
        // `decodeOptions: nil` ⇒ the exact prior unbiased behavior, no regression.
        let decodeOptions: DecodingOptions?
        if let tokenizer = kit.tokenizer,
           let prompt = QuipDictationVocabulary.promptTokens(
               encode: tokenizer.encode(text:),
               specialTokenBegin: tokenizer.specialTokens.specialTokenBegin) {
            decodeOptions = DecodingOptions(promptTokens: prompt)
        } else {
            decodeOptions = nil
        }
        let results: [TranscriptionResult] = try await kit.transcribe(
            audioArray: audioArray, decodeOptions: decodeOptions)
        return results.map(\.text).joined(separator: " ")
    }
}
#endif

/// Mac-side: per-PTT-session PCM buffering + Whisper transcription. One
/// instance per running Quip process.
final class WhisperDictationService: @unchecked Sendable {

    struct SessionBuffer {
        var samples: [Float] = []
        var lastTouched: Date = Date()
    }

    private let transcriber: WhisperTranscriber
    private let send: (Any) -> Void
    private let staleWindow: TimeInterval
    private let queue = DispatchQueue(label: "com.quip.whisper.mac")
    private var sessions: [UUID: SessionBuffer] = [:]

    init(transcriber: WhisperTranscriber,
         staleWindow: TimeInterval = 30.0,
         send: @escaping (Any) -> Void) {
        self.transcriber = transcriber
        self.staleWindow = staleWindow
        self.send = send
    }

    /// Number of times a chunk was decoded while on the main thread.
    ///
    /// Same regression oracle as `TerminalStateDetector.mainThreadProcessSpawns`,
    /// for a different blocking primitive. `ingest` is reached from the MainActor
    /// message loop once per audio chunk of every PTT stream, so a base64 decode
    /// there is the highest-frequency main-thread block in the app. Incremented
    /// inside the decode itself so it cannot drift away from where the work
    /// actually runs; it must stay 0. `nonisolated(unsafe)` for the same reason
    /// the spawn counter is: only the main thread ever writes it, and an off-main
    /// decode — the correct case — leaves it alone.
    nonisolated(unsafe) private(set) static var mainThreadChunkDecodes = 0

    /// Test-only reset so each case starts from a known count.
    static func resetMainThreadChunkDecodeCount() {
        mainThreadChunkDecodes = 0
    }

    /// Fire-and-forget ingest. Used when the caller doesn't need to await the
    /// transcription result (the normal message-loop case).
    ///
    /// Nothing here runs on the caller's thread. Both halves of this used to:
    /// the base64 → `[Float]` decode, and a `queue.sync` that parked main behind
    /// whatever the whisper queue was already doing. `queue` is serial, so
    /// hopping onto it with `async` preserves the ordering callers rely on — a
    /// `hasBuffer` or `purgeStaleSessions` issued after this call still runs
    /// after this block, because both enter the same serial queue behind it.
    func ingest(_ chunk: AudioChunkMessage) {
        queue.async { [self] in
            append(chunk)
            if chunk.isFinal {
                Task { await finalize(sessionId: chunk.sessionId) }
            }
        }
    }

    /// Test-only variant that awaits the finalize Task so assertions see
    /// the send-closure call. Routes through the same off-main append as
    /// `ingest` — a `queue.sync` here would decode on the caller's thread and
    /// make the tests disagree with production about where the work happens.
    func ingestAsync(_ chunk: AudioChunkMessage) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                append(chunk)
                continuation.resume()
            }
        }
        if chunk.isFinal { await finalize(sessionId: chunk.sessionId) }
    }

    /// Decode a chunk and fold it into its session buffer.
    /// MUST be called on `queue` — it touches `sessions` unsynchronized.
    private func append(_ chunk: AudioChunkMessage) {
        let samples = Self.decodeInt16LE(base64: chunk.pcmBase64)
        var buf = sessions[chunk.sessionId] ?? SessionBuffer()
        buf.samples.append(contentsOf: samples)
        buf.lastTouched = Date()
        sessions[chunk.sessionId] = buf
    }

    func hasBuffer(for sessionId: UUID) -> Bool {
        queue.sync { sessions[sessionId] != nil }
    }

    func purgeStaleSessions() {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-staleWindow)
            sessions = sessions.filter { $0.value.lastTouched > cutoff }
        }
    }

    private func finalize(sessionId: UUID) async {
        let samples: [Float] = queue.sync {
            let s = sessions[sessionId]?.samples ?? []
            sessions.removeValue(forKey: sessionId)
            return s
        }
        do {
            let raw = try await transcriber.transcribe(audioArray: samples)
            // WhisperKit emits placeholder tokens like `[BLANK_AUDIO]`,
            // `(silence)`, `[NO_SPEECH]` for non-speech segments. They get
            // typed verbatim into the user's terminal as garbage if we
            // ship them through. Strip before sending.
            let cleaned = WhisperOutputCleaner.clean(raw)
            send(TranscriptResultMessage(sessionId: sessionId, text: cleaned, error: nil))
        } catch {
            send(TranscriptResultMessage(sessionId: sessionId, text: "",
                                         error: error.localizedDescription))
        }
    }

    private static func decodeInt16LE(base64: String) -> [Float] {
        if Thread.isMainThread { mainThreadChunkDecodes += 1 }
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return [] }
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<count {
                out[i] = Float(p[i]) / 32767.0
            }
        }
        return out
    }
}
