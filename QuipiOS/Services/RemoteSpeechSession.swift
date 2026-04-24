import AVFoundation
import Foundation

/// Per-press orchestrator for the Mac Whisper recognizer path. Owns one
/// `WhisperAudioSender`, tracks stop-completion + safety timeout, and routes
/// the Mac's final `TranscriptResultMessage` back to `SpeechService`.
@MainActor
final class RemoteSpeechSession {

    let sessionId: UUID
    private let sender: WhisperAudioSender
    private let safetyTimeout: TimeInterval

    private var pendingStop: ((String) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var didResolve = false

    init(sessionId: UUID, sender: WhisperAudioSender, safetyTimeout: TimeInterval = 3.0) {
        self.sessionId = sessionId
        self.sender = sender
        self.safetyTimeout = safetyTimeout
    }

    /// Forward a mic buffer to this session's sender. Caller is responsible for
    /// installing / removing the tap — `AudioWorker` already handles lifecycle.
    nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        sender.appendBuffer(buffer)
    }

    /// Finalize the recording; fire `completion` with the Mac's final transcript
    /// when it arrives, or with empty string if the safety timeout fires first.
    /// Idempotent: repeat calls re-assign the completion but only the first stop
    /// triggers teardown.
    func stop(completion: @escaping (String) -> Void) async {
        pendingStop = completion
        await sender.finish()
        startSafetyTimeout()
    }

    func handleTranscript(sessionId: UUID, text: String, error: String?) {
        guard sessionId == self.sessionId, !didResolve else { return }
        didResolve = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let out: String = (error == nil) ? text : ""
        let cb = pendingStop
        pendingStop = nil
        cb?(out)
    }

    private func startSafetyTimeout() {
        timeoutTask?.cancel()
        let t = safetyTimeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            guard let self, !self.didResolve else { return }
            self.didResolve = true
            let cb = self.pendingStop
            self.pendingStop = nil
            cb?("")
        }
    }
}
