// NetworkMode.swift
// QuipMac — Enumerates the three mutually-exclusive ways the Mac can expose
// its WebSocket server to the phone: via a Cloudflare quick tunnel, via
// Tailscale, or local-only (LAN).

import Foundation

enum NetworkMode: String, CaseIterable, Identifiable {
    case cloudflareTunnel
    case tailscale
    case localOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudflareTunnel: return "Cloudflare Tunnel"
        case .tailscale:        return "Tailscale"
        case .localOnly:        return "Local only"
        }
    }
}

/// One-time migration from the legacy `localOnlyMode` boolean to `networkMode`.
/// Idempotent — safe to call on every launch. Returns the resolved mode.
@MainActor
func migrateNetworkModeIfNeeded() -> NetworkMode {
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: "networkMode"),
       let mode = NetworkMode(rawValue: raw) {
        return mode
    }
    // First launch after the update — derive from legacy key.
    let legacyLocalOnly = defaults.bool(forKey: "localOnlyMode")
    let resolved: NetworkMode = legacyLocalOnly ? .localOnly : .cloudflareTunnel
    defaults.set(resolved.rawValue, forKey: "networkMode")
    return resolved
}
