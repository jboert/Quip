// WatchSyncService.swift
// QuipiOS — pushes per-window Claude state to the paired Apple Watch over
// WCSession. The Watch app receives this in WatchSync (QuipWatchApp.swift)
// and renders a glance + haptics on attention transitions.
//
// Protocol: a single key `windows` in the WCSession dictionary, carrying
// a JSON-encoded `[WatchWindowState]` array. Wire format kept self-contained
// here so the watch target doesn't need to import the full Shared
// MessageProtocol module — that would drag in every iOS-only dependency
// the protocol file touches.

import Foundation
import WatchConnectivity
import OSLog
import Observation

/// Wire shape — must match the Watch-side `WatchWindowState` declared in
/// `QuipiOS/QuipWatch/QuipWatchApp.swift`. Keeping the struct duplicated
/// (rather than shared via the Shared/ module) avoids dragging UIKit
/// imports into the watch target.
struct WatchWindowSyncEntry: Codable {
    let id: String
    let name: String
    let state: String
    let claudeMode: String?
}

enum WatchNotificationReadiness: Equatable {
    case unsupported
    case noPairedWatch
    case companionNotInstalled
    case ready(reachable: Bool)

    var title: String {
        switch self {
        case .unsupported: return "Apple Watch unavailable"
        case .noPairedWatch: return "No paired Apple Watch"
        case .companionNotInstalled: return "Install Quip on Apple Watch"
        case .ready(let reachable): return reachable ? "Apple Watch connected" : "Apple Watch paired"
        }
    }

    var detail: String {
        switch self {
        case .unsupported: return "This iPhone does not support Watch connectivity."
        case .noPairedWatch: return "Pair an Apple Watch to receive mirrored alerts and live Quip status."
        case .companionNotInstalled: return "Install the Quip companion from the Watch app for live status and haptics."
        case .ready(let reachable):
            return reachable
                ? "Mirrored alerts, inline actions, and live status are available."
                : "Alerts can mirror; live status updates when the Watch reconnects."
        }
    }
}

@MainActor
@Observable
final class WatchSyncService: NSObject, WCSessionDelegate {

    private static let logger = Logger(subsystem: "com.quip.ios", category: "WatchSyncService")

    /// Last payload pushed — used to dedupe so we don't fire transferUserInfo
    /// for every layout poll when nothing actually changed.
    private var lastPayload: Data?
    private(set) var readiness: WatchNotificationReadiness = .unsupported

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshReadiness()
    }

    func refreshReadiness() {
        guard WCSession.isSupported() else {
            readiness = .unsupported
            return
        }
        let session = WCSession.default
        if !session.isPaired {
            readiness = .noPairedWatch
        } else if !session.isWatchAppInstalled {
            readiness = .companionNotInstalled
        } else {
            readiness = .ready(reachable: session.isReachable)
        }
    }

    /// Push the current window list to the watch. Called from the host on
    /// every layout_update or state_change. Throttled by content-equality
    /// against the last successful payload.
    func push(windows: [WatchWindowSyncEntry]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        refreshReadiness()
        guard session.activationState == .activated else { return }
        guard session.isPaired, session.isWatchAppInstalled else { return }

        let data: Data
        do {
            data = try JSONEncoder().encode(windows)
        } catch {
            Self.logger.error("WatchSync encode failed: \(error.localizedDescription, privacy: .public) — \(windows.count) windows dropped")
            return
        }
        if data == lastPayload { return }
        lastPayload = data

        // Prefer the live channel when reachable (instant); fall back to
        // background-delivered transferUserInfo so the Watch still gets the
        // payload after the next wake. updateApplicationContext also
        // overwrites previous in-flight updates rather than queuing,
        // which is exactly what we want for state.
        let payload: [String: Any] = ["windows": data]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { sendErr in
                // Fall through to context update on send failure so the Watch
                // still has the latest snapshot once it wakes.
                Self.logger.warning("WatchSync sendMessage failed (\(sendErr.localizedDescription, privacy: .public)); falling back to applicationContext")
                do {
                    try WCSession.default.updateApplicationContext(payload)
                } catch {
                    Self.logger.error("WatchSync applicationContext fallback also failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            do {
                try session.updateApplicationContext(payload)
            } catch {
                Self.logger.error("WatchSync applicationContext failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.refreshReadiness() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshReadiness() }
    }

    // The iPhone-side delegate must implement these no-ops (or real handlers)
    // even when the watch app does the talking, otherwise WCSession asserts
    // on iOS at activation time.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so a new watch can pair without app relaunch.
        WCSession.default.activate()
        Task { @MainActor in self.refreshReadiness() }
    }
}
