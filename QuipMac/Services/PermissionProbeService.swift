// PermissionProbeService.swift
// QuipMac — probe the three TCC permissions Quip needs and report status to
// connected iPhone clients. Lets the phone surface red/green dots without the
// user having to dig through System Settings to check.

import Foundation
import ApplicationServices
import CoreGraphics

/// Probes Accessibility, Automation (Apple Events) and Screen Recording.
///
/// Every probe runs **off the main thread**.
/// `AEDeterminePermissionToAutomateTarget` blocks on a dispatch semaphore
/// waiting for an Apple Events round-trip to the target app and `tccd`; when
/// either is slow the caller's thread stalls for seconds. Running that on main
/// from the 5-second permissions timer produced a 6.3-second UI freeze with
/// every sample inside `_dispatch_semaphore_wait_slow`
/// (`Quip_2026-07-30-091540.hang`).
///
/// Deliberately neither `@MainActor` nor an actor: the blocking work belongs on
/// a utility queue, and the completion is hopped back to main explicitly.
final class PermissionProbeService: @unchecked Sendable {

    /// iTerm's bundle ID — what we probe for Apple Events permission. Quip
    /// primarily drives iTerm; Terminal.app support is incidental, so we don't
    /// probe both. If a user is iTerm-less, the false-positive is preferable
    /// to a confusing red dot.
    static let iTermBundleID = "com.googlecode.iterm2"

    /// The three grant checks, injectable so tests can drive timing and
    /// outcomes without real TCC state.
    struct Probes: Sendable {
        var accessibility: @Sendable () -> Bool
        var appleEvents: @Sendable () -> Bool
        var screenRecording: @Sendable () -> Bool

        static let system = Probes(
            accessibility: { AXIsProcessTrusted() },
            appleEvents: { PermissionProbeService.systemAppleEventsProbe() },
            screenRecording: { CGPreflightScreenCaptureAccess() }
        )
    }

    private let probes: Probes
    private let queue = DispatchQueue(label: "quip.permission-probe", qos: .utility)
    private let lock = NSLock()
    private var cached: MacPermissionsMessage?
    private var inFlight = false
    private var waiters: [@MainActor (MacPermissionsMessage) -> Void] = []

    init(probes: Probes = .system) {
        self.probes = probes
    }

    /// Newest completed snapshot. Non-blocking; nil until the first refresh
    /// lands. SwiftUI view bodies read this rather than forcing a probe.
    var lastSnapshot: MacPermissionsMessage? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Run the three probes off main and deliver the result on main.
    ///
    /// Coalescing matters: the app's 5-second timer, client-auth, and wake all
    /// ask independently, and a slow Apple Events round-trip can still be
    /// outstanding when the next request arrives. Without this, those requests
    /// would pile onto the queue and each would pay the full stall.
    func refresh(completion: @escaping @MainActor (MacPermissionsMessage) -> Void) {
        lock.lock()
        waiters.append(completion)
        if inFlight {
            lock.unlock()
            return
        }
        inFlight = true
        lock.unlock()

        queue.async { [self] in
            let snapshot = MacPermissionsMessage(
                accessibility: probes.accessibility(),
                appleEvents: probes.appleEvents(),
                screenRecording: probes.screenRecording()
            )

            lock.lock()
            cached = snapshot
            inFlight = false
            let pending = waiters
            waiters.removeAll()
            lock.unlock()

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for waiter in pending { waiter(snapshot) }
                }
            }
        }
    }

    /// Returns false ONLY when the user has explicitly denied Apple Events for
    /// the target. `procNotFound` (target not running) is treated as granted —
    /// we can't tell, and the alternative is permanent red until iTerm
    /// launches. Blocking: only ever called from `queue`.
    private static func systemAppleEventsProbe() -> Bool {
        guard let bundleData = iTermBundleID.data(using: .utf8) else { return true }

        var addressDesc = AEAddressDesc()
        let createStatus: OSStatus = bundleData.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(Int(errAEWrongDataType)) }
            return OSStatus(AECreateDesc(typeApplicationBundleID, base, bundleData.count, &addressDesc))
        }
        guard createStatus == noErr else { return true }
        defer { AEDisposeDesc(&addressDesc) }

        let result = AEDeterminePermissionToAutomateTarget(
            &addressDesc,
            typeWildCard,
            typeWildCard,
            false  // askUserIfNeeded — silent probe
        )
        switch result {
        case noErr: return true
        case OSStatus(procNotFound): return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return true
        }
    }
}
