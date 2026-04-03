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

    // All audio work happens through this helper on a background queue
    private let worker = AudioWorker()

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

            // Configure audio session
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                onUpdate(nil, true)
                return
            }

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
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil

            // Restore audio session to playback so volume button KVO keeps working
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try? session.setActive(true)
        }
    }
}
