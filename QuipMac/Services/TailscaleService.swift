// TailscaleService.swift
// QuipMac — Detects the Mac's Tailscale hostname by shelling out to the
// `tailscale status --json` CLI. Exposes an observable `webSocketURL` built
// from the MagicDNS name (or the 100.x IP as a fallback) and the configured
// WebSocket port. One-shot detection — refresh() is called on app launch,
// on network-mode change, on app activation, and from a manual "Re-detect"
// button in the Connection settings tab.

import Foundation
import Observation

@MainActor
@Observable
final class TailscaleService {

    /// Detected (or overridden) hostname, e.g. "quip-mac.tail1234.ts.net" or "100.64.1.2".
    var hostname: String = ""

    /// Full WebSocket URL clients should use, e.g. "ws://quip-mac.tail1234.ts.net:8765".
    /// Empty when not available.
    var webSocketURL: String = ""

    /// True when we have a usable hostname (either auto-detected or manually overridden).
    var isAvailable: Bool = false

    /// Human-readable error message when detection fails. nil when OK.
    var lastError: String? = nil

    /// Trigger a fresh detection pass. Safe to call repeatedly.
    func refresh() {
        // Filled in by Task 3.
    }

    /// Clear all published state so the UI doesn't show a stale URL after
    /// switching away from Tailscale mode.
    func stop() {
        hostname = ""
        webSocketURL = ""
        isAvailable = false
        lastError = nil
    }
}
