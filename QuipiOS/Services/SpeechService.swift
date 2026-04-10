import AVFoundation
import Observation
import Speech
import UIKit

/// On-device speech-to-text. The audio engine and recognition run on a
/// background queue to avoid Swift 6 @MainActor isolation issues.
@Observable
@MainActor
final class SpeechService {

    private(set) var isRecording = false
    private(set) var transcribedText = ""
    private(set) var isAuthorized = false
    private(set) var isSpeaking = false

    /// The window ID whose audio is currently playing — drives the TTS overlay
    private(set) var currentSpeakingWindowId: String?

    // All audio work happens through this helper on a background queue
    private let worker = AudioWorker()

    // Single-player sequential queue. Chunks from different windows are interleaved
    // but play one after another. A new sessionId for the SAME window drops that
    // window's stale queued chunks without disturbing other windows' audio.
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PlayerDelegate?
    @ObservationIgnored private var audioQueue: [(windowId: String, sessionId: String, data: Data)] = []
    @ObservationIgnored private var currentlyPlayingWindowId: String?
    /// Latest sessionId per window — used to drop stale chunks
    @ObservationIgnored private var activeSessionIds: [String: String] = [:]
    /// Background task token — keeps the app alive between TTS audio chunks
    @ObservationIgnored private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    func requestAuthorization() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .authorized {
            isAuthorized = true
            return
        }
        if speechStatus == .denied || speechStatus == .restricted {
            isAuthorized = false
            return
        }
        let callback: @Sendable (Bool) -> Void = { [weak self] authorized in
            DispatchQueue.main.async { self?.isAuthorized = authorized }
        }
        DispatchQueue.global().async {
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized else { callback(false); return }
                AVAudioApplication.requestRecordPermission { granted in
                    callback(granted)
                }
            }
        }
    }

    func startRecording() {
        guard isAuthorized, !isRecording else { return }
        isRecording = true
        transcribedText = ""

        worker.start { [weak self] text, finished in
            DispatchQueue.main.async {
                guard let self else { return }
                if let text { self.transcribedText = text }
                if finished { self.isRecording = false }
            }
        }
    }

    @discardableResult
    func stopRecording() -> String {
        guard isRecording else { return transcribedText }
        worker.stop()
        isRecording = false
        return transcribedText
    }

    /// Enqueue a WAV chunk for sequential playback. Chunks from different windows
    /// queue up and play one after another. A new sessionId for the same window drops
    /// that window's stale queued chunks (and stops playback if it's the active one).
    func enqueueAudio(_ data: Data, windowId: String, sessionId: String, isFinal: Bool) {
        guard !isRecording else { return }

        // New session for this window? Drop stale chunks for that window.
        if activeSessionIds[windowId] != sessionId {
            audioQueue.removeAll { $0.windowId == windowId }
            // If the currently playing chunk is from this window's old session, stop it
            if currentlyPlayingWindowId == windowId {
                audioPlayer?.stop()
                audioPlayer = nil
                playerDelegate = nil
            }
            activeSessionIds[windowId] = sessionId
        }

        // Final-marker messages arrive with empty audio — nothing to queue
        if !data.isEmpty {
            audioQueue.append((windowId: windowId, sessionId: sessionId, data: data))
            if audioPlayer == nil {
                playNextChunk()
            }
        }
    }

    /// Stop all audio playback and clear the queue
    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil
        audioQueue.removeAll()
        activeSessionIds.removeAll()
        currentlyPlayingWindowId = nil
        currentSpeakingWindowId = nil
        isSpeaking = false
        endBackgroundTask()
    }

    /// Stop a specific window's audio — removes its queued chunks and stops
    /// playback if that window is currently playing, then advances the queue.
    func stopSpeaking(windowId: String) {
        audioQueue.removeAll { $0.windowId == windowId }
        activeSessionIds.removeValue(forKey: windowId)
        if currentlyPlayingWindowId == windowId {
            audioPlayer?.stop()
            audioPlayer = nil
            playerDelegate = nil
            playNextChunk()
        }
    }

    private func playNextChunk() {
        guard let next = audioQueue.first else {
            audioPlayer = nil
            playerDelegate = nil
            currentlyPlayingWindowId = nil
            currentSpeakingWindowId = nil
            isSpeaking = false
            endBackgroundTask()
            return
        }
        audioQueue.removeFirst()

        // Audio session is already configured by HardwareButtonHandler (.playAndRecord).
        // Do NOT call setCategory/setActive here — it triggers phantom outputVolume KVO
        // events that the volume-button handler can't distinguish from real presses.

        do {
            let player = try AVAudioPlayer(data: next.data)
            let delegate = PlayerDelegate { [weak self] in
                DispatchQueue.main.async { self?.playNextChunk() }
            }
            self.playerDelegate = delegate
            player.delegate = delegate
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.audioPlayer = player
            currentlyPlayingWindowId = next.windowId
            currentSpeakingWindowId = next.windowId
            isSpeaking = true
            beginBackgroundTask()
        } catch {
            NSLog("[Quip] AVAudioPlayer failed: %@", error.localizedDescription)
            DispatchQueue.main.async { [weak self] in self?.playNextChunk() }
        }
    }

    /// Begin a background task so iOS keeps the app alive between TTS audio chunks.
    /// The audio background mode keeps us running while audio plays, but gaps between
    /// chunks could cause suspension — the background task bridges those gaps.
    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "QuipTTS") { [weak self] in
            // Expiration handler — OS is about to kill our time, end gracefully
            DispatchQueue.main.async { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
}

/// Delegate wrapper to detect end of audio playback
private class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}

/// Handles all audio/speech work off the main actor.
/// This is a plain class (not @MainActor) so its closures don't trigger isolation checks.
private class AudioWorker: @unchecked Sendable {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "com.quip.speech", qos: .userInteractive)

    func start(onUpdate: @escaping (String?, Bool) -> Void) {
        queue.async { [self] in
            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                onUpdate(nil, true)
                return
            }

            // Don't call setCategory here — HardwareButtonHandler owns that and
            // changing it triggers phantom volume KVO events. Just make sure the
            // session is active (cheap no-op if it already is) so the audio engine
            // can grab the mic after TTS playback releases it.
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)

            // Create recognition request
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            self.recognitionRequest = request

            // Install audio tap
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                onUpdate(nil, true)
                return
            }

            // Start recognition — accumulate text across task restarts so
            // long recordings don't lose the beginning when iOS silently
            // restarts the recognition task after ~60 seconds.
            var accumulated = ""
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let text = result?.bestTranscription.formattedString {
                    onUpdate(text, false)
                }
                let isFinal = result?.isFinal ?? false
                if isFinal, let text = result?.bestTranscription.formattedString {
                    accumulated = text
                }
                if let error = error {
                    let nsError = error as NSError
                    // Error code 1110 = "Recognition request was canceled" — iOS does
                    // this silently after ~60s of continuous on-device recognition.
                    // Restart with a fresh task and keep the accumulated text.
                    if nsError.code == 1110 || nsError.code == 216 {
                        let prefix = accumulated
                        let newRequest = SFSpeechAudioBufferRecognitionRequest()
                        newRequest.shouldReportPartialResults = true
                        newRequest.requiresOnDeviceRecognition = true
                        self.recognitionRequest = newRequest
                        // Re-install the tap to feed the new request
                        if self.audioEngine.isRunning {
                            inputNode.removeTap(onBus: 0)
                            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                                newRequest.append(buffer)
                            }
                        }
                        self.recognitionTask = recognizer.recognitionTask(with: newRequest) { result, error in
                            if let text = result?.bestTranscription.formattedString {
                                let combined = prefix.isEmpty ? text : "\(prefix) \(text)"
                                onUpdate(combined, false)
                            }
                            let isFinal = result?.isFinal ?? false
                            let hasError = error != nil
                            if hasError || isFinal {
                                onUpdate(nil, true)
                            }
                        }
                    } else {
                        onUpdate(nil, true)
                    }
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            recognitionRequest?.endAudio()
            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            // Use finish() instead of cancel() to get the final transcription
            recognitionTask?.finish()
            recognitionTask = nil
            recognitionRequest = nil
        }
    }
}
