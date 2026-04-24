import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

/// Volume up = cycle windows, Volume down = start/stop recording
@Observable
@MainActor
final class HardwareButtonHandler {

    // Suppression windows: shorter for self-triggered KVO echoes,
    // slightly longer for PTT transitions that reconfigure the audio session.
    private static let volumeRestoreSuppression: TimeInterval = 0.3
    private static let pttTransitionSuppression: TimeInterval = 0.25

    var selectedIndex = 0
    private(set) var windowCount = 0

    var onSelectionChanged: ((Int) -> Void)?
    var onPTTStart: (() -> Void)?
    var onPTTStop: (() -> Void)?
    var onArm: (() -> Void)?
    var onDisarm: (() -> Void)?

    private var volumeObservation: NSKeyValueObservation?
    private var routeChangeObserver: NSObjectProtocol?
    private(set) var isPTTActive = false
    private var suppressUntil: Date = .distantPast
    private var savedVolume: Float?

    #if DEBUG
    var _routeChangeObserverForTesting: NSObjectProtocol? { routeChangeObserver }
    #endif

    private static let stuckPressWatchdog: TimeInterval = 30.0
    private var stuckWatchdog: DispatchWorkItem?

    #if DEBUG
    var _testWatchdogOverride: TimeInterval?
    func _forceStartPTTForTesting() {
        isPTTActive = true
        onPTTStart?()
    }
    func _armStuckWatchdogForTesting() { armStuckWatchdog() }
    #endif

    /// Suppress volume KVO events for `duration` seconds. Call when audio session
    /// is about to be reconfigured (e.g. TTS playback starting) so the phantom
    /// volume changes that result don't get mistaken for button presses.
    func suppressVolumeEvents(for duration: TimeInterval) {
        let newUntil = Date().addingTimeInterval(duration)
        if newUntil > suppressUntil {
            suppressUntil = newUntil
        }
    }

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

        // Force volume to midpoint so both up and down always have room to change.
        // We restore this midpoint after every button press.
        savedVolume = 0.5
        suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
        HiddenVolumeView.setVolume(0.5)

        volumeObservation = session.observe(\.outputVolume, options: [.new, .old]) {
            [weak self] _, change in
            guard let newVol = change.newValue, let oldVol = change.oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                // Don't touch volume or interpret presses unless Quip is actually
                // foreground-active. KVO keeps firing while .inactive (app switcher,
                // Control Center, lock-screen peek) and between willResignActive
                // and didEnterBackground — hitting restoreVolume() in that window
                // fights whatever app the user is actually using (YouTube etc.).
                // We deliberately do NOT tear down the observer or audio session
                // here; that path broke PTT resume before.
                guard UIApplication.shared.applicationState == .active else { return }

                // Ignore phantom KVO events caused by audio session reconfiguration
                guard Date() >= self.suppressUntil else { return }

                let delta = newVol - oldVol
                guard abs(delta) > 0.001 else { return }

                // Restore volume to prevent audible changes
                self.restoreVolume()

                let wentDown = delta < 0

                if self.isPTTActive {
                    // ANY volume button press stops recording
                    self.isPTTActive = false
                    self.suppressUntil = Date().addingTimeInterval(Self.pttTransitionSuppression)
                    self.onPTTStop?()
                    self.cancelStuckWatchdog()
                    return
                }

                if wentDown {
                    self.isPTTActive = true
                    self.suppressUntil = Date().addingTimeInterval(Self.pttTransitionSuppression)
                    self.onPTTStart?()
                    self.armStuckWatchdog()
                } else {
                    guard self.windowCount > 0 else { return }
                    self.selectedIndex = (self.selectedIndex + 1) % self.windowCount
                    self.onSelectionChanged?(self.selectedIndex)
                }
            }
        }

        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                guard UIApplication.shared.applicationState == .active else { return }
                if self.isPTTActive {
                    self.isPTTActive = false
                    self.suppressUntil = Date().addingTimeInterval(Self.pttTransitionSuppression)
                    self.onPTTStop?()
                    self.cancelStuckWatchdog()
                }
            }
        }

        onArm?()
    }

    /// Restore volume to the level captured when monitoring started
    private func restoreVolume() {
        guard let target = savedVolume else { return }
        // Suppress the KVO event that will fire from our own volume change
        suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
        HiddenVolumeView.setVolume(target)
    }

    /// Re-activate the audio session and reset volume after returning from background.
    /// The OS deactivates the session when backgrounded, killing volume KVO.
    func resumeAfterBackground() {
        guard volumeObservation != nil else { return }
        // If a press was in flight when we backgrounded, deliver the stop now —
        // volume KVO was paused, so there was no natural release event.
        if isPTTActive {
            isPTTActive = false
            onPTTStop?()
        }
        cancelStuckWatchdog()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {}
        suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
        HiddenVolumeView.setVolume(0.5)
    }

    func stopMonitoring() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        windowCount = 0
        if isPTTActive {
            isPTTActive = false
            onPTTStop?()
        }
        suppressUntil = .distantPast
        cancelStuckWatchdog()
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        onDisarm?()
    }

    private func armStuckWatchdog() {
        cancelStuckWatchdog()
        let interval: TimeInterval = {
            #if DEBUG
            return _testWatchdogOverride ?? Self.stuckPressWatchdog
            #else
            return Self.stuckPressWatchdog
            #endif
        }()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPTTActive else { return }
            NSLog("[Quip][PTT] watchdog fired — forcing stop after %.1fs", interval)
            self.isPTTActive = false
            self.suppressUntil = Date().addingTimeInterval(Self.pttTransitionSuppression)
            self.onPTTStop?()
        }
        stuckWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func cancelStuckWatchdog() {
        stuckWatchdog?.cancel()
        stuckWatchdog = nil
    }
}

// Hidden MPVolumeView — suppresses the system volume HUD and provides volume control
struct HiddenVolumeView: UIViewRepresentable {
    static weak var shared: MPVolumeView?

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        view.alpha = 0.001
        Self.shared = view
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}

    static func setVolume(_ value: Float) {
        guard let volumeView = shared else { return }
        // Find the hidden UISlider inside MPVolumeView to programmatically set volume
        for subview in volumeView.subviews {
            if let slider = subview as? UISlider {
                slider.value = value
                slider.sendActions(for: .valueChanged)
                return
            }
        }
    }
}
