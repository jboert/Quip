import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

/// Volume up = cycle windows, Volume down = toggle recording
/// Uses a "last known volume" approach instead of resetting to neutral.
@Observable
@MainActor
final class HardwareButtonHandler {

    var selectedIndex = 0
    private(set) var windowCount = 0

    var onSelectionChanged: ((Int) -> Void)?
    var onPTTStart: (() -> Void)?
    var onPTTStop: (() -> Void)?

    private var volumeObservation: NSKeyValueObservation?
    private var isPTTActive = false
    private var lastKnownVolume: Float = -1
    private var ignoreUntil: Date = .distantPast

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

        lastKnownVolume = session.outputVolume

        volumeObservation = session.observe(\.outputVolume, options: [.new]) {
            [weak self] session, change in
            guard let newVol = change.newValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Ignore KVO events from our own reset
                if Date() < self.ignoreUntil {
                    self.lastKnownVolume = newVol
                    return
                }

                guard self.lastKnownVolume >= 0 else {
                    self.lastKnownVolume = newVol
                    return
                }

                let delta = newVol - self.lastKnownVolume
                self.lastKnownVolume = newVol
                guard abs(delta) > 0.001 else { return }

                let wentUp = delta > 0

                if self.isPTTActive {
                    self.isPTTActive = false
                    self.onPTTStop?()
                    self.resetToMiddle()
                    return
                }

                if wentUp {
                    guard self.windowCount > 0 else { return }
                    self.selectedIndex = (self.selectedIndex + 1) % self.windowCount
                    self.onSelectionChanged?(self.selectedIndex)
                } else {
                    self.isPTTActive = true
                    self.onPTTStart?()
                }

                self.resetToMiddle()
            }
        }
    }

    func stopMonitoring() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        windowCount = 0
    }

    private func resetToMiddle() {
        // Ignore KVO for the next 0.4s to avoid reacting to our own reset
        ignoreUntil = Date().addingTimeInterval(0.4)
        lastKnownVolume = 0.5

        // Reset system volume to 0.5 via the hidden MPVolumeView slider
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NotificationCenter.default.post(
                name: Self.resetVolumeNotification,
                object: nil,
                userInfo: ["volume": Float(0.5)]
            )
        }
    }

    static let resetVolumeNotification = Notification.Name("HardwareButtonHandler.resetVolume")
}

// Hidden MPVolumeView — keeps volume HUD from appearing
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.001
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
