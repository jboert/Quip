import Foundation

/// Which resolved address a Bonjour row should dial (PRD 2026-10-07, US-012).
///
/// A Mac advertises one service on every interface, so a resolve can return
/// a routable LAN address, a link-local one (169.254/16, self-assigned on a
/// USB/Thunderbolt bridge or a Wi-Fi interface still waiting for DHCP), and
/// loopback. A link-local address vanishes with the interface that carried
/// it: the 2026-10-07 QA pass paired on one and lost the Mac six minutes
/// later. So loopback is never offered and link-local is the last resort.
/// Pure value logic, unit-tested in `BonjourAddressPickerTests`.
enum BonjourAddressPicker {

    /// The address to offer from one resolve's IPv4 literals, in the order
    /// the resolver returned them: the first that is neither loopback nor
    /// link-local, else the first link-local, else nil.
    static func pick(_ ipv4: [String]) -> String? {
        let usable = ipv4.filter { !isLoopbackIPv4($0) }
        return usable.first(where: { !isLinkLocalIPv4($0) }) ?? usable.first
    }

    /// True for an IPv4 link-local literal (`169.254/16`). Same strict parse
    /// as `NetworkClassifier.isRFC1918IPv4`: exactly four decimal octets in
    /// `0...255`, so a host name or a malformed literal is never link-local.
    static func isLinkLocalIPv4(_ ip: String) -> Bool {
        guard let octets = octets(ip) else { return false }
        return octets[0] == 169 && octets[1] == 254
    }

    /// True for an IPv4 loopback literal (`127/8`).
    static func isLoopbackIPv4(_ ip: String) -> Bool {
        guard let octets = octets(ip) else { return false }
        return octets[0] == 127
    }

    /// The IPv4 addresses in `NetService.addresses` (`sockaddr` blobs), as
    /// dotted-quad strings in their original order. IPv6 and malformed
    /// entries are skipped.
    static func ipv4Strings(from addresses: [Data]) -> [String] {
        addresses.compactMap { data -> String? in
            guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            return data.withUnsafeBytes { raw -> String? in
                let addr = raw.loadUnaligned(as: sockaddr_in.self)
                guard addr.sin_family == sa_family_t(AF_INET) else { return nil }
                var sin = addr.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
        }
    }

    private static func octets(_ ip: String) -> [Int]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { $0 }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return values
    }
}
