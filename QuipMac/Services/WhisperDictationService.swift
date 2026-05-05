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
        let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audioArray)
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

    /// Synchronous ingest — fire-and-forget. Used when caller doesn't need
    /// to await the transcription result (normal message-loop case).
    func ingest(_ chunk: AudioChunkMessage) {
        let samples = Self.decodeInt16LE(base64: chunk.pcmBase64)
        queue.sync {
            var buf = sessions[chunk.sessionId] ?? SessionBuffer()
            buf.samples.append(contentsOf: samples)
            buf.lastTouched = Date()
            sessions[chunk.sessionId] = buf
        }
        if chunk.isFinal {
            Task { await finalize(sessionId: chunk.sessionId) }
        }
    }

    /// Test-only variant that awaits the finalize Task so assertions see
    /// the send-closure call.
    func ingestAsync(_ chunk: AudioChunkMessage) async {
        let samples = Self.decodeInt16LE(base64: chunk.pcmBase64)
        queue.sync {
            var buf = sessions[chunk.sessionId] ?? SessionBuffer()
            buf.samples.append(contentsOf: samples)
            buf.lastTouched = Date()
            sessions[chunk.sessionId] = buf
        }
        if chunk.isFinal { await finalize(sessionId: chunk.sessionId) }
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
