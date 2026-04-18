// ConnectionLog.swift
// QuipMac — In-memory ring buffer of recent WebSocket connection events
// Feeds the "Diagnostics" section in Settings so the user can see who
// tried to connect, when, and whether it worked.

import Foundation
import Observation

/// One entry in the connection log.
struct ConnectionEvent: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    /// Best-effort remote address. NWConnection doesn't always give us a tidy
    /// IP — sometimes it's "hostname:port", sometimes a raw endpoint descriptor.
    /// We store whatever we can pull and let the UI render it as-is.
    let remote: String
    let detail: String?

    enum Kind: String, Sendable {
        case connected
        case disconnected
        case authSucceeded
        case authFailed
        case failed
    }
}

@MainActor
@Observable
final class ConnectionLog {
    /// Most recent events first. Capped to keep memory bounded — a phone that
    /// reconnects every few seconds because of a flaky tunnel shouldn't balloon
    /// this into MBs.
    private(set) var events: [ConnectionEvent] = []

    /// 20 is enough history to see the last handful of connect/disconnect/auth
    /// cycles without turning the settings panel into a scroll marathon.
    static let maxEvents = 20

    func record(_ kind: ConnectionEvent.Kind, remote: String, detail: String? = nil) {
        let event = ConnectionEvent(timestamp: Date(), kind: kind, remote: remote, detail: detail)
        events.insert(event, at: 0)
        if events.count > Self.maxEvents {
            events.removeLast(events.count - Self.maxEvents)
        }
    }

    func clear() {
        events.removeAll()
    }
}
