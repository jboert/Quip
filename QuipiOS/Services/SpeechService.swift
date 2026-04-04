import AVFoundation
import Observation
import Speech

/// On-device speech-to-text. The audio engine and recognition run on a
/// background queue to avoid Swift 6 @MainActor isolation issues.
@Observable
@MainActor
final class SpeechService {

    private(set) var isRecording = false
    private(set) var transcribedText = ""
    private(set) var isAuthorized = false
    private(set) var isSpeaking = false

    // All audio work happens through this helper on a background queue
    private let worker = AudioWorker()

    // Audio playback for pre-synthesized TTS audio from the Mac (Kokoro).
    // Queues chunks by sessionId — playing one chunk triggers the next in the queue.
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var playerDelegate: PlayerDelegate?
    @ObservationIgnored private var audioQueue: [Data] = []
    @ObservationIgnored private var currentSessionId: String?

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

    /// Enqueue a WAV chunk for streaming playback. Chunks sharing the same sessionId
    /// play back-to-back. A new sessionId stops current playback and clears the queue.
    func enqueueAudio(_ data: Data, sessionId: String, isFinal: Bool) {
        guard !isRecording else { return }

        // New session? Drop everything and start fresh.
        if sessionId != currentSessionId {
            stopSpeaking()
            currentSessionId = sessionId
        }

        // Final-marker messages arrive with empty audio — just signal no more chunks coming
        if !data.isEmpty {
            audioQueue.append(data)
            if audioPlayer == nil {
                playNextChunk()
            }
        }
    }

    /// Back-compat single-shot playback (used by tap-to-silence overlay if needed)
    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerDelegate = nil
        audioQueue.removeAll()
        currentSessionId = nil
        isSpeaking = false
    }

    private func playNextChunk() {
        guard let data = audioQueue.first else {
            audioPlayer = nil
            playerDelegate = nil
            isSpeaking = false
            return
        }
        audioQueue.removeFirst()

        // Configure audio session once per play (cheap if already set)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)

        do {
            let player = try AVAudioPlayer(data: data)
            let delegate = PlayerDelegate { [weak self] in
                DispatchQueue.main.async { self?.playNextChunk() }
            }
            self.playerDelegate = delegate
            player.delegate = delegate
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.audioPlayer = player
            self.isSpeaking = true
        } catch {
            NSLog("[Quip] AVAudioPlayer failed: %@", error.localizedDescription)
            // Skip this chunk and try next
            DispatchQueue.main.async { [weak self] in self?.playNextChunk() }
        }
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

            // Do NOT reconfigure the audio session here — HardwareButtonHandler
            // already set .playAndRecord and changing the mode/options triggers
            // phantom outputVolume KVO notifications that cause a feedback loop.

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

            // Start recognition
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal ?? false
                let hasError = error != nil
                onUpdate(text, hasError || isFinal)
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
