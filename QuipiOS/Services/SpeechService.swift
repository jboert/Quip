import AVFoundation
import Observation
import Speech
import UIKit

enum DictationVocab {
    static let maxTerms = 100

    static func load(from url: URL) -> [String] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let terms = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(terms.prefix(maxTerms))
    }

    static func loadBundled() -> [String] {
        guard let url = Bundle.main.url(forResource: "dictation-vocab", withExtension: "txt") else {
            NSLog("[Quip][PTT] dictation-vocab.txt not found in bundle")
            return []
        }
        return load(from: url)
    }
}

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

    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?

    /// Fires once with the final transcribed text after the worker's trailing-flush
    /// has completed (or a safety timeout has fired). Used by QuipApp so that
    /// SendTextMessage goes out with the post-flush text, not the stale pre-flush snapshot.
    @ObservationIgnored private var pendingStopCompletion: ((String) -> Void)?

    /// Incremented on every startRecording. The worker's callback closure
    /// captures the session token at the time it was registered; any callback
    /// whose token no longer matches belongs to an obsolete session (e.g. the
    /// trailing-flush from a prior press landing after a new press started)
    /// and must not mutate transcribedText / isRecording.
    @ObservationIgnored private var activeSessionToken: UUID?

    @ObservationIgnored private var remoteSession: RemoteSpeechSession?
    @ObservationIgnored weak var webSocket: WebSocketClient?

    /// Wire up to the WebSocket client. Call once at app startup, before the
    /// first press. Enables the remote Whisper path.
    func attachWebSocket(_ client: WebSocketClient) {
        webSocket = client
        client.onTranscriptResult = { [weak self] sid, text, error in
            self?.remoteSession?.handleTranscript(sessionId: sid, text: text, error: error)
        }
    }

    /// Wire up AVAudioSession interruption handling. Call once from the app's
    /// entry point (after the onArm/onDisarm callbacks are set). Idempotent.
    func startObservingInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            switch type {
            case .began:
                self.worker.disarm()
            case .ended:
                if let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                    if options.contains(.shouldResume) { self.worker.arm() }
                }
            @unknown default: break
            }
        }
    }

    deinit {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

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

        let sessionToken = UUID()
        activeSessionToken = sessionToken

        let path: PTTPath
        if let ws = webSocket {
            path = selectPTTPath(isConnected: ws.isConnected, whisperStatus: ws.whisperStatus)
            // Pure integer logs to avoid iOS NSLog %@ redaction
            // pathRemote=1 remote, =0 local. wsReady=1 if ws.isConnected
            // whisperReady=1 if state==.ready, 0=preparing, 2=downloading, 3=failed
            let wsReady = ws.isConnected ? 1 : 0
            let whisperReady: Int = {
                switch ws.whisperStatus {
                case .ready: return 1
                case .preparing: return 0
                case .downloading: return 2
                case .failed: return 3
                }
            }()
            NSLog("[Quip][PTT] startRecording pathRemote=%d wsReady=%d whisperReady=%d",
                  path == .remote ? 1 : 0, wsReady, whisperReady)
        } else {
            path = .local
            NSLog("[Quip][PTT] startRecording pathRemote=0 wsReady=-1 whisperReady=-1")
        }

        switch path {
        case .local:
            worker.start { [weak self] text, finished in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Stale-session guard: if startRecording has been called again
                    // (new press while the prior session's trailing-flush was still
                    // in flight on the worker queue), this callback belongs to the
                    // OLD session and must not mutate state that now belongs to the
                    // new session. Fire pending completion if applicable, then bail.
                    let isCurrent = self.activeSessionToken == sessionToken
                    if finished {
                        let pending = self.pendingStopCompletion
                        self.pendingStopCompletion = nil
                        pending?(text ?? "")
                        if isCurrent { self.activeSessionToken = nil }
                    } else if isCurrent, let text {
                        self.transcribedText = text
                    }
                }
            }
        case .remote:
            guard let ws = webSocket else { isRecording = false; return }
            let sender = WhisperAudioSender(sessionId: sessionToken) { chunk in
                Task { @MainActor in ws.sendAudioChunk(chunk) }
            }
            let session = RemoteSpeechSession(sessionId: sessionToken, sender: sender)
            remoteSession = session
            worker.startForwarding { [weak session] buf in
                session?.appendBuffer(buf)
            }
        }
    }

    /// Stop recording. If `completion` is supplied, it is invoked on the main
    /// thread with the final post-flush transcription once the worker's 300ms
    /// trailing window and any end-of-utterance recognizer callback have fired
    /// (or after a 3s safety timeout). Callers that need the last-spoken word
    /// to make it into their send path MUST use the completion; the synchronous
    /// return value is the pre-flush snapshot.
    @discardableResult
    func stopRecording(completion: ((String) -> Void)? = nil) -> String {
        NSLog("[Quip][PTT] stopRecording entry isRecording=%d remoteSession=%d",
              isRecording ? 1 : 0, remoteSession != nil ? 1 : 0)
        guard isRecording else {
            completion?(transcribedText)
            return transcribedText
        }
        pendingStopCompletion = completion

        if let session = remoteSession {
            NSLog("[Quip][PTT] stopRecording taking REMOTE path")
            let sessionToken = activeSessionToken
            Task { @MainActor [weak self] in
                await session.stop { [weak self] text in
                    NSLog("[Quip][PTT] remote session.stop fired textLen=%d", text.count)
                    guard let self else {
                        NSLog("[Quip][PTT] remote completion guard FAILED selfNil")
                        return
                    }
                    guard self.activeSessionToken == sessionToken else {
                        NSLog("[Quip][PTT] remote completion guard FAILED tokenMismatch")
                        return
                    }
                    let cb = self.pendingStopCompletion
                    self.pendingStopCompletion = nil
                    self.transcribedText = text
                    self.activeSessionToken = nil
                    self.remoteSession = nil
                    NSLog("[Quip][PTT] remote firing cb pendingNotNil=%d", cb != nil ? 1 : 0)
                    cb?(text)
                }
            }
            isRecording = false
            // Ask the forwarding tap to stop, but leave the engine armed.
            worker.stopForwarding()
        } else {
            NSLog("[Quip][PTT] stopRecording taking LOCAL path")
            worker.stop()
            isRecording = false
            // Safety net: if the worker's trailing-flush never delivers a finished
            // callback (e.g. recognizer stalls, interruption arrives mid-flush),
            // fire the completion with whatever we have rather than stranding the text.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let pending = self.pendingStopCompletion else { return }
                self.pendingStopCompletion = nil
                pending(self.transcribedText)
            }
        }
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

/// Pure decision helper — tested in isolation so SpeechService doesn't need a
/// mock WebSocketClient. Returns `.remote` when the Mac Whisper path should
/// serve this press, `.local` otherwise.
enum PTTPath: Equatable { case local, remote }

func selectPTTPath(isConnected: Bool, whisperStatus: WhisperState) -> PTTPath {
    guard isConnected else { return .local }
    if case .ready = whisperStatus { return .remote }
    return .local
}

/// Detects the silent utterance-rollover SFSpeechRecognizer performs in
/// on-device mode: after a speaker pause, partial results can restart from
/// scratch without the task ever firing `isFinal`. When that happens the new
/// partial is shorter than the pre-pause high-water mark and its first token
/// no longer matches — the pattern we key off here. Captured from device log
/// 2026-04-24: `text='First sentence' → text='Second'` with `accum=''` and no
/// intervening isFinal, so the pre-pause words were dropped by `SeamStitcher`
/// on the next partial.
enum RecognizerRollover {
    /// True when `current` looks like a reset of `previous`, not a refinement.
    /// Both empty, previous empty, or current extending previous → false.
    static func detects(previous: String, current: String) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespaces)
        let curr = current.trimmingCharacters(in: .whitespaces)
        guard !prev.isEmpty, !curr.isEmpty else { return false }
        guard curr.count < prev.count else { return false }

        let prevFirst = prev.split(separator: " ").first.map(String.init) ?? ""
        let currFirst = curr.split(separator: " ").first.map(String.init) ?? ""
        guard !prevFirst.isEmpty, !currFirst.isEmpty else { return false }
        return prevFirst.lowercased() != currFirst.lowercased()
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
    private let cachedVocab: [String] = DictationVocab.loadBundled()

    // Dictation sessions naturally terminate at ~1 minute or on silence. To let
    // users talk longer, we stitch consecutive recognition tasks together and
    // preserve the transcription across the seam.
    private var accumulatedText = ""
    // Longest partial bestTranscription seen inside the CURRENT recognition
    // task. Used to detect silent utterance rollover: the on-device recognizer
    // can restart partials mid-task when the speaker pauses (no isFinal is
    // emitted), dropping everything spoken before the pause. When we see a
    // partial that's shorter than this + starts with a different first token,
    // we commit `lastPartialText` into `accumulatedText` before stitching so
    // the pre-pause words survive instead of being overwritten.
    private var lastPartialText = ""
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
            self.lastPartialText = ""
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
        if !cachedVocab.isEmpty {
            request.contextualStrings = cachedVocab
        }
        self.recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                let text = result?.bestTranscription.formattedString ?? ""
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil

                // Silent-rollover guard: SFSpeechRecognizer on-device can drop
                // prior partial content after a pause without firing isFinal,
                // restarting bestTranscription mid-task. Confirmed via captured
                // device log — "First sentence" partial was replaced by
                // "Second" on a ~3s pause while accumulatedText stayed empty.
                // If the new partial is shorter AND starts with a different
                // first token than the previous high-water mark, commit the
                // previous partial into accumulatedText so the pre-pause words
                // survive the stitch.
                if RecognizerRollover.detects(previous: self.lastPartialText, current: text) {
                    self.accumulatedText = SeamStitcher.stitch(old: self.accumulatedText,
                                                               new: self.lastPartialText)
                }
                self.lastPartialText = text

                // Present accumulated previous chunks + current partial to caller.
                let combined = SeamStitcher.stitch(old: self.accumulatedText, new: text)

                if hasError {
                    self.onUpdateCallback?(combined.isEmpty ? nil : combined, true)
                    self.isFlushing = false
                    return
                }

                self.onUpdateCallback?(combined, false)

                if isFinal {
                    // Commit this chunk and decide whether to restart.
                    self.accumulatedText = combined
                    self.lastPartialText = ""
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

    /// Remote-path variant: forward mic buffers to `onBuffer` but do not spin
    /// up a local SFSpeechRecognizer. Engine + tap stay armed.
    func startForwarding(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        queue.async { [self] in
            guard self.isArmed else { return }
            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                onBuffer(buffer)
                self.ring.append(buffer: buffer, at: Date())
            }
        }
    }

    /// Stop remote-path forwarding. Re-installs the default tap that only
    /// feeds the ring so subsequent local-path presses get pre-roll replay.
    func stopForwarding() {
        queue.async { [self] in
            guard self.isArmed else { return }
            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.recognitionRequest?.append(buffer)
                self.ring.append(buffer: buffer, at: Date())
            }
        }
    }
}
