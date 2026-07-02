// BonjourAdvertiser.swift
// QuipMac — Advertises the WebSocket server on the local network via Bonjour

import Foundation
import Network
import Observation

@MainActor
@Observable
final class BonjourAdvertiser {

    var isAdvertising = false

    private var netService: NetService?
    private let serviceType = "_quip._tcp."

    /// Start advertising with the given WebSocket server port
    func startAdvertising(port: Int = 8765) {
        guard !isAdvertising else { return }

        let hostName = Host.current().localizedName ?? "Mac"
        let service = NetService(
            domain: "local.",
            type: serviceType,
            name: "Quip \(hostName)",
            port: Int32(port)
        )
        // Advertise this Mac's stable device UUID in the TXT record so a phone
        // that already has a paired row for this Mac folds the discovered LAN
        // URL into that row (as a fallback) instead of spawning a SECOND
        // backend — the anti-flap contract that lets us advertise safely even
        // in Tailscale mode. Key "did" matches BackendConnectionManager's fold.
        var txt: [String: Data] = [:]
        if let idData = WebSocketServer.deviceID().data(using: .utf8) {
            txt["did"] = idData
        }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        isAdvertising = true
        print("[BonjourAdvertiser] Advertising '\(service.name)' on port \(port) (did=\(WebSocketServer.deviceID().prefix(8)))")
    }

    func stopAdvertising() {
        netService?.stop()
        netService = nil
        isAdvertising = false
        print("[BonjourAdvertiser] Stopped")
    }

    // Legacy compatibility
    func advertise(on listener: Any?) {
        startAdvertising()
    }
}
