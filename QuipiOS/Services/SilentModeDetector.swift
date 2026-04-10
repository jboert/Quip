import Foundation
import AudioToolbox
import Observation

/// Detects whether the phone's ringer switch is on silent using the "duration hack":
/// play a tiny silent sound via AudioServicesPlaySystemSound and measure how long
/// the completion callback takes. When silent mode is active, the sound is suppressed
/// and the callback fires almost immediately; when off, it takes ~100ms.
///
/// iOS has no public API for the ringer switch — this is the standard workaround.
@Observable
final class SilentModeDetector: @unchecked Sendable {

    /// Current best guess at silent-mode state. Updated by `check()`.
    /// Defaults to false (not silent) so TTS audio plays until we know otherwise.
    private(set) var isSilent: Bool = false

    @ObservationIgnored private var soundID: SystemSoundID = 0
    @ObservationIgnored private var soundURL: URL?
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private var lastCheck: Date = .distantPast
    private let checkInterval: TimeInterval = 2.0
    private let silentThreshold: TimeInterval = 0.1

    init() {
        createSilentSound()
    }

    deinit {
        if soundID != 0 {
            AudioServicesDisposeSystemSoundID(soundID)
        }
        if let url = soundURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Generate a ~100ms silent WAV file in tmp and register it as a system sound.
    private func createSilentSound() {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("quip-silent-check.wav")
        soundURL = tmpURL

        // Build a minimal WAV: 8kHz 16-bit mono, 800 samples of silence (100ms)
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = 800
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataSize: UInt32 = numSamples * UInt32(blockAlign)
        let totalSize: UInt32 = 36 + dataSize

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: totalSize.littleEndian, Array.init))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))  // PCM
        wav.append(contentsOf: withUnsafeBytes(of: channels.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        wav.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        wav.append(contentsOf: "data".utf8)
        wav.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        wav.append(Data(count: Int(dataSize)))

        do {
            try wav.write(to: tmpURL)
        } catch {
            NSLog("[SilentModeDetector] Failed to write silent WAV: %@", error.localizedDescription)
            return
        }

        let status = AudioServicesCreateSystemSoundID(tmpURL as CFURL, &soundID)
        if status != 0 {
            NSLog("[SilentModeDetector] Failed to create system sound: %d", status)
        }
    }

    /// Play the silent sound and measure how long until completion.
    /// Rate-limited to avoid spamming. Updates `isSilent` asynchronously.
    func check() {
        stateLock.lock()
        guard soundID != 0 else { stateLock.unlock(); return }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= checkInterval else {
            stateLock.unlock()
            return
        }
        lastCheck = now
        let localSoundID = soundID
        let threshold = silentThreshold
        stateLock.unlock()

        let start = Date()
        AudioServicesPlaySystemSoundWithCompletion(localSoundID) { [weak self] in
            let elapsed = Date().timeIntervalSince(start)
            let silent = elapsed < threshold
            DispatchQueue.main.async { [weak self] in
                self?.isSilent = silent
            }
        }
    }
}
