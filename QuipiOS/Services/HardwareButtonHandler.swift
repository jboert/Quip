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
    // pttTransitionSuppression was 0.25s — long enough to swallow a user's
    // legitimate fast re-press to stop PTT. Dropped to 0.10s, which is still
    // longer than the phantom restore-volume KVO echo (typically <50ms after
    // setVolume) but well below the 200–300ms gap a human leaves between
    // start and stop button taps.
    private static let volumeRestoreSuppression: TimeInterval = 0.3
    private static let pttTransitionSuppression: TimeInterval = 0.10

    // iOS volume buttons step by 1/16. Stay one step away from each rail so
    // KVO can always see motion in both directions.
    private static let lowRail: Float = 0.0625
    private static let highRail: Float = 0.9375

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
        } catch {
            NSLog("[Quip][HW] Audio session setup failed: %@", error.localizedDescription)
        }

        // Preserve the user's current volume (and any audio another app like
        // YouTube is driving). Only nudge if we're parked on a rail where a
        // button press wouldn't produce a KVO delta.
        primeRailIfNeeded(session: session)

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
                guard UIApplication.shared.applicationState == .active else {
                    print("[Quip][PTT] KVO drop: app not active (state=\(UIApplication.shared.applicationState.rawValue))")
                    return
                }

                // Ignore phantom KVO events caused by audio session reconfiguration
                let now = Date()
                guard now >= self.suppressUntil else {
                    let remaining = self.suppressUntil.timeIntervalSince(now)
                    print("[Quip][PTT] KVO drop: suppressed (remaining \(String(format: "%.3f", remaining))s)")
                    return
                }

                let delta = newVol - oldVol
                guard abs(delta) > 0.001 else {
                    print("[Quip][PTT] KVO drop: delta too small (\(delta))")
                    return
                }
                print("[Quip][PTT] KVO accepted: delta=\(delta) isPTTActive=\(self.isPTTActive)")

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
            ) { [weak self] notification in
                guard let self else { return }
                guard UIApplication.shared.applicationState == .active else { return }

                // Only force-stop on actual hardware route changes (headphones
                // unplugged, BT disconnect, default device changed). The
                // notification ALSO fires on category changes — and PTT
                // start itself triggers a category-change when the speech
                // service activates the mic. The previous handler treated
                // that internal change as if AirPods had unplugged and
                // killed PTT immediately. Result: intermittent "vol-down
                // didn't trigger anything" depending on whether the route-
                // change notification beat the user's perception.
                guard let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                let isHardwareEvent: Bool
                switch reason {
                case .newDeviceAvailable, .oldDeviceUnavailable, .override, .wakeFromSleep, .noSuitableRouteForCategory:
                    isHardwareEvent = true
                case .unknown, .categoryChange, .routeConfigurationChange:
                    isHardwareEvent = false
                @unknown default:
                    isHardwareEvent = false
                }
                guard isHardwareEvent else {
                    NSLog("[Quip][PTT] route change reason=%lu (non-hardware), ignoring", reasonRaw)
                    return
                }

                NSLog("[Quip][PTT] route change reason=%lu (hardware) — force-stop", reasonRaw)
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
    /// Re-arms the KVO observer if it was torn down (which happens via
    /// `pauseMonitoring()` on the `didEnterBackground` notification).
    func resumeAfterBackground() {
        // If a press was in flight when we backgrounded, deliver the stop now —
        // volume KVO was paused, so there was no natural release event.
        if isPTTActive {
            isPTTActive = false
            onPTTStop?()
        }
        cancelStuckWatchdog()

        // If the observer is gone (background pause), re-arm using the
        // cached windowCount. Without this, PTT stayed dead from foregrounding
        // until the next Mac layout_update arrived — could be 1–15s with
        // the WS resilience layer mid-reconnect.
        if volumeObservation == nil && windowCount > 0 {
            startMonitoring(windowCount: windowCount)
            return
        }
        guard volumeObservation != nil else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            NSLog("[Quip][HW] Audio session setup failed: %@", error.localizedDescription)
        }
        primeRailIfNeeded(session: session)
    }

    /// Lighter teardown for backgrounding: kills the KVO observer (which
    /// stops firing reliably anyway when the audio session deactivates) but
    /// preserves `windowCount` so `resumeAfterBackground()` can re-arm
    /// without waiting for the next Mac `layout_update`.
    /// Use this on `didEnterBackground`; reserve full `stopMonitoring()`
    /// for terminal teardown (no-windows state, app shutting down).
    func pauseMonitoring() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        if isPTTActive {
            isPTTActive = false
            onPTTStop?()
        }
        suppressUntil = .distantPast
        cancelStuckWatchdog()
        // Deliberately keep windowCount so resumeAfterBackground can re-arm.
        // Deliberately keep routeChangeObserver — it's still useful in fg.
    }

    /// Capture the user's current output volume into `savedVolume`. Only
    /// override the system volume if it sits on a rail (≤low or ≥high) where
    /// a button press wouldn't yield a KVO delta. Otherwise leave whatever
    /// the user — or another foreground audio app — has set alone.
    private func primeRailIfNeeded(session: AVAudioSession) {
        let current = session.outputVolume
        if current <= Self.lowRail {
            savedVolume = Self.lowRail
            suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
            HiddenVolumeView.setVolume(Self.lowRail)
        } else if current >= Self.highRail {
            savedVolume = Self.highRail
            suppressUntil = Date().addingTimeInterval(Self.volumeRestoreSuppression)
            HiddenVolumeView.setVolume(Self.highRail)
        } else {
            savedVolume = current
        }
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
