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

    /// Detects whether the phone's ringer switch is on silent.
    /// When silent, TTS audio plays at volume 0 so the overlay still shows
    /// without actually making noise.
    @ObservationIgnored let silentModeDetector = SilentModeDetector()

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

    /// Arm the long-lived audio engine so it is ready before the first PTT press.
    /// Called by HardwareButtonHandler when monitoring starts.
    func arm() { worker.arm() }

    /// Disarm the audio engine when PTT monitoring stops.
    /// Called by HardwareButtonHandler when monitoring stops.
    func disarm() { worker.disarm() }

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

        // Re-check silent mode before each chunk so toggling the ringer switch
        // takes effect immediately on the next chunk.
        silentModeDetector.check()

        do {
            let player = try AVAudioPlayer(data: next.data)
            let delegate = PlayerDelegate { [weak self] in
                DispatchQueue.main.async { self?.playNextChunk() }
            }
            self.playerDelegate = delegate
            player.delegate = delegate
            // Mute audio when silent mode is on, but still "play" so the
            // overlay stays visible for the duration of the chunk.
            player.volume = silentModeDetector.isSilent ? 0.0 : 1.0
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

/// Pure policy object: decides whether a stop request should flush or be rejected as duplicate.
struct FlushPolicy {
    let trailingWindow: TimeInterval
    let finishHardCap: TimeInterval

    static let `default` = FlushPolicy(trailingWindow: 0.3, finishHardCap: 2.0)
}

/// Handles all audio/speech work off the main actor.
/// This is a plain class (not @MainActor) so its closures don't trigger isolation checks.
private class AudioWorker: @unchecked Sendable {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "com.quip.speech", qos: .userInteractive)

    // Dictation sessions naturally terminate at ~1 minute or on silence. To let
    // users talk longer, we stitch consecutive recognition tasks together and
    // preserve the transcription across the seam.
    private var accumulatedText = ""
    private var isStopping = false
    private var isFlushing = false
    private let policy: FlushPolicy = .default
    private var onUpdateCallback: ((String?, Bool) -> Void)?

    // Long-lived engine support: arm/disarm keep the engine + tap running
    // continuously while PTT is being monitored, so there is no cold-start
    // latency on each press. The ring captures the last 500ms of audio so
    // every new recognition task can replay pre-roll and avoid first-word clip.
    private let ring = AudioRingBuffer(window: 0.5)
    private var isArmed = false

    func arm() {
        queue.async { [self] in
            guard !self.isArmed else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)

            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let now = Date()
                // Always forward to the live request when one is attached.
                self.recognitionRequest?.append(buffer)
                // Always retain last 500ms for pre-roll replay.
                self.ring.append(buffer: buffer, at: now)
            }
            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
                self.isArmed = true
            } catch {
                NSLog("[Quip][PTT] arm: engine start failed: %@", error.localizedDescription)
            }
        }
    }

    func disarm() {
        queue.async { [self] in
            guard self.isArmed else { return }
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.ring.clear()
            self.isArmed = false
        }
    }

    func start(onUpdate: @escaping (String?, Bool) -> Void) {
        queue.async { [self] in
            self.accumulatedText = ""
            self.isStopping = false
            self.isFlushing = false
            self.onUpdateCallback = onUpdate

            guard let recognizer = speechRecognizer, recognizer.isAvailable else {
                onUpdate(nil, true)
                return
            }

            // Under the long-lived engine model, `arm()` has already installed the tap.
            // If somehow we weren't armed (arm failed), fall back to cold-start.
            if !self.isArmed {
                let input = self.audioEngine.inputNode
                input.removeTap(onBus: 0)
                let format = input.outputFormat(forBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.recognitionRequest?.append(buffer)
                }
                do {
                    self.audioEngine.prepare()
                    try self.audioEngine.start()
                } catch {
                    onUpdate(nil, true)
                    return
                }
            }

            self.beginRecognitionTask(recognizer: recognizer)

            // Replay pre-roll into the request we just created.
            let now = Date()
            for entry in self.ring.entries(relativeTo: now) {
                self.recognitionRequest?.append(entry.buffer)
            }
        }
    }

    private func beginRecognitionTask(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                let text = result?.bestTranscription.formattedString ?? ""
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil

                // Present accumulated previous chunks + current partial to caller.
                let combined = self.accumulatedText.isEmpty
                    ? text
                    : (text.isEmpty ? self.accumulatedText : self.accumulatedText + " " + text)

                if hasError {
                    self.onUpdateCallback?(combined.isEmpty ? nil : combined, true)
                    self.isFlushing = false
                    return
                }

                self.onUpdateCallback?(combined, false)

                if isFinal {
                    // Commit this chunk and decide whether to restart.
                    self.accumulatedText = combined
                    self.recognitionTask = nil
                    self.recognitionRequest = nil

                    if self.isStopping {
                        self.onUpdateCallback?(combined, true)
                        self.isFlushing = false
                    } else {
                        // End-of-speech hit (silence or the ~1-minute ceiling)
                        // but user is still holding PTT — spin up a new task so
                        // dictation continues without a forced cutoff.
                        self.beginRecognitionTask(recognizer: recognizer)
                    }
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard !self.isFlushing else { return }
            guard !self.isStopping || self.recognitionTask != nil else { return }
            self.isStopping = true
            self.isFlushing = true

            // End audio input — tap keeps forwarding any already-buffered samples
            // into the request until we tear it down.
            self.recognitionRequest?.endAudio()

            // 300ms later, finish the task. Under the arm/disarm model the engine
            // + tap stay running — only tear them down if we were never armed
            // (cold-start fallback path).
            self.queue.asyncAfter(deadline: .now() + self.policy.trailingWindow) { [weak self] in
                guard let self else { return }
                // Engine + tap stay running under arm/disarm model. Only tear down the
                // engine if we were never armed (cold-start fallback path).
                if !self.isArmed, self.audioEngine.isRunning {
                    self.audioEngine.stop()
                    self.audioEngine.inputNode.removeTap(onBus: 0)
                }
                self.recognitionTask?.finish()

                // Hard cap: if isFinal doesn't fire within finishHardCap, force-close.
                let taskRef = self.recognitionTask
                self.queue.asyncAfter(deadline: .now() + self.policy.finishHardCap) { [weak self] in
                    guard let self else { return }
                    if self.recognitionTask === taskRef, taskRef != nil {
                        NSLog("[Quip][PTT] flush timeout at %.1fs — cancelling task", self.policy.finishHardCap)
                        taskRef?.cancel()
                        self.recognitionTask = nil
                        self.recognitionRequest = nil
                        self.onUpdateCallback?(self.accumulatedText.isEmpty ? nil : self.accumulatedText, true)
                        self.isFlushing = false
                    }
                }
            }
        }
    }
}
