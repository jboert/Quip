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
    // Counts how many KVO events to skip (audio session switches cause 1-2 spurious events)
    private var skipCount = 0

    func startMonitoring(windowCount: Int) {
        guard windowCount > 0 else { return }
        self.windowCount = windowCount
        self.selectedIndex = min(selectedIndex, max(0, windowCount - 1))

        guard volumeObservation == nil else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
        } catch {}

        volumeObservation = session.observe(\.outputVolume, options: [.new, .old]) {
            [weak self] _, change in
            guard let newVol = change.newValue, let oldVol = change.oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                let delta = newVol - oldVol
                guard abs(delta) > 0.001 else { return }

                // Skip spurious KVO events from audio session category changes
                if self.skipCount > 0 {
                    self.skipCount -= 1
                    return
                }

                let wentDown = delta < 0

                if self.isPTTActive {
                    // ANY volume button press stops recording
                    self.isPTTActive = false
                    // Skip next 2 KVO events (audio session switching back to playback)
                    self.skipCount = 2
                    self.onPTTStop?()
                    return
                }

                if wentDown {
                    self.isPTTActive = true
                    // Skip next 2 KVO events (audio session switching to record)
                    self.skipCount = 2
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
