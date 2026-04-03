// BonjourBrowser.swift
// VoiceCodeiOS — No-op stub (Cloudflare tunnel handles connectivity now)

import Foundation
import Observation

@Observable
@MainActor
final class BonjourBrowser {

    private(set) var discoveredServices: [String] = []
    private(set) var isSearching = false

    func startBrowsing() {
        isSearching = true
    }

    func stopBrowsing() {
        isSearching = false
    }

    func resolve(_ result: Any) async -> URL? {
        return nil
    }
}
