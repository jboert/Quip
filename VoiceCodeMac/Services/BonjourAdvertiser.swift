// BonjourAdvertiser.swift
// VoiceCodeMac — No-op stub (Cloudflare tunnel handles connectivity now)

import Foundation
import Observation

@MainActor
@Observable
final class BonjourAdvertiser {

    var isAdvertising = false

    func advertise(on listener: Any?) {
        isAdvertising = true
    }

    func startAdvertising() {
        isAdvertising = true
    }

    func stopAdvertising() {
        isAdvertising = false
    }
}
