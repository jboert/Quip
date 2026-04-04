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
    private let synthesizer = AVSpeechSynthesizer()

    /// Cached high-quality voice — picks premium/enhanced en-US voice if available
    @ObservationIgnored private var _preferredVoice: AVSpeechSynthesisVoice?
    private var preferredVoice: AVSpeechSynthesisVoice? {
        if let v = _preferredVoice { return v }
        let enUSVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en-US") || $0.language.hasPrefix("en_US")
        }
        // Prefer: premium > enhanced > default. Within each tier, prefer personality voices
        let preferredNames = ["Ava", "Samantha", "Evan", "Zoe", "Allison", "Susan", "Tom"]
        let byQuality: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]
        for quality in byQuality {
            let voicesAtQuality = enUSVoices.filter { $0.quality == quality }
            for name in preferredNames {
                if let voice = voicesAtQuality.first(where: { $0.name == name }) {
                    _preferredVoice = voice
                    return voice
                }
            }
            if let voice = voicesAtQuality.first {
                _preferredVoice = voice
                return voice
            }
        }
        let fallback = AVSpeechSynthesisVoice(language: "en-US")
        _preferredVoice = fallback
        return fallback
    }
    private let synthDelegate = SynthDelegate()

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

    /// Speak text aloud using TTS
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        // Don't interrupt recording
        guard !isRecording else { return }
        if synthesizer.delegate == nil {
            synthDelegate.onFinish = { [weak self] in
                DispatchQueue.main.async { self?.isSpeaking = false }
            }
            synthesizer.delegate = synthDelegate
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.voice = preferredVoice
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

/// Delegate helper that detects when AVSpeechSynthesizer finishes speaking.
private class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
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
