import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

/// Volume up = cycle windows, Volume down = start/stop recording
@Observable
@MainActor
final class HardwareButtonHandler {

    var selectedIndex = 0
    private(set) var windowCount = 0

    var onSelectionChanged: ((Int) -> Void)?
    var onPTTStart: (() -> Void)?
    var onPTTStop: (() -> Void)?

    private var volumeObservation: NSKeyValueObservation?
    private(set) var isPTTActive = false
    private var suppressUntil: Date = .distantPast

    func startMonitoring(windowCount: Int) {
        guard windowCount > 0 else { return }
        self.windowCount = windowCount
        self.selectedIndex = min(selectedIndex, max(0, windowCount - 1))

        guard volumeObservation == nil else { return }

        // Use .playAndRecord so volume KVO keeps working even while the mic is active.
        // The speech service no longer switches categories — it stays on .playAndRecord.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {}

        volumeObservation = session.observe(\.outputVolume, options: [.new, .old]) {
            [weak self] _, change in
            guard let newVol = change.newValue, let oldVol = change.oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Ignore phantom KVO events caused by audio session reconfiguration
                guard Date() >= self.suppressUntil else { return }

                let delta = newVol - oldVol
                guard abs(delta) > 0.001 else { return }

                let wentDown = delta < 0

                if self.isPTTActive {
                    // ANY volume button press stops recording
                    self.isPTTActive = false
                    self.suppressUntil = Date().addingTimeInterval(0.5)
                    self.onPTTStop?()
                    return
                }

                if wentDown {
                    self.isPTTActive = true
                    self.suppressUntil = Date().addingTimeInterval(0.5)
                    self.onPTTStart?()
                } else {
                    guard self.windowCount > 0 else { return }
                    self.selectedIndex = (self.selectedIndex + 1) % self.windowCount
                    self.onSelectionChanged?(self.selectedIndex)
                }
            }
        }
    }

    func stopMonitoring() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        windowCount = 0
    }
}

// Hidden MPVolumeView — suppresses the system volume HUD
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.001
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
