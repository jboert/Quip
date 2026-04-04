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
        service.publish()
        netService = service
        isAdvertising = true
        print("[BonjourAdvertiser] Advertising '\(service.name)' on port \(port)")
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
