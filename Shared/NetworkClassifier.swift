import Foundation

/// Single source of truth for RFC1918 private-LAN IPv4 classification, shared by
/// BOTH peers so the Mac's advertise gate and the phone's URL bucketing can never
/// drift and silently hide the "Use Local Network" tile:
///
/// - QuipMac `WebSocketServer.isPrivateIPv4` — decides which interface addresses
///   get advertised to the phone as `DeviceIdentityMessage.localURLs`.
/// - QuipiOS `BackendConnectionManager.urlPriority` / `isLANURL` — decides which
///   URLs count as "local network" (priority 1) for the LAN switch + tile.
///
/// Compiled into the QuipMac and QuipiOS app targets (both source `../Shared`).
/// Pure value logic, no state — safe to call from any isolation domain.
enum NetworkClassifier {

    /// True for an RFC1918 private-LAN IPv4 literal: `10/8`, `172.16–31/12`,
    /// `192.168/16`. Requires exactly four decimal octets, each in `0...255`.
    ///
    /// Deliberately EXCLUDES loopback (`127/8`), link-local (`169.254/16`),
    /// Tailscale CGNAT (`100.64–127/10`), and every public address — none of
    /// those are ever advertised or treated as "local network". Tailscale is
    /// reached on its own path; the phone must never see a TS address as LAN.
    ///
    /// Strict parse: anything that isn't four in-range octets (a `.local` host,
    /// a MagicDNS name, a malformed literal) returns `false`.
    static func isRFC1918IPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        return false
    }
}
