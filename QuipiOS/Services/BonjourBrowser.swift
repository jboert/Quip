// BonjourBrowser.swift
// QuipiOS — Discovers Quip Mac instances on the local network via Bonjour

import Foundation
import Observation

struct DiscoveredHost: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    var wsURL: URL? {
        URL(string: "ws://\(host):\(port)")
    }
}

@Observable
@MainActor
final class BonjourBrowser {

    private(set) var discoveredHosts: [DiscoveredHost] = []
    private(set) var isSearching = false

    private var delegate: BonjourDelegate?

    func startBrowsing() {
        guard !isSearching else { return }
        discoveredHosts = []

        let del = BonjourDelegate { [weak self] host in
            Task { @MainActor in
                guard let self else { return }
                if !self.discoveredHosts.contains(where: { $0.host == host.host && $0.port == host.port }) {
                    self.discoveredHosts.append(host)
                }
            }
        } onRemove: { [weak self] name in
            Task { @MainActor in
                self?.discoveredHosts.removeAll { $0.name == name }
            }
        }

        del.start()
        delegate = del
        isSearching = true
        print("[BonjourBrowser] Searching...")
    }

    func stopBrowsing() {
        delegate?.stop()
        delegate = nil
        isSearching = false
    }
}

// Non-isolated delegate that handles NetService callbacks
private class BonjourDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private let onDiscover: (DiscoveredHost) -> Void
    private let onRemove: (String) -> Void
    private let serviceType = "_quip._tcp."

    init(onDiscover: @escaping (DiscoveredHost) -> Void, onRemove: @escaping (String) -> Void) {
        self.onDiscover = onDiscover
        self.onRemove = onRemove
        super.init()
    }

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolvingServices.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[BonjourBrowser] Found: \(service.name)")
        resolvingServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        onRemove(service.name)
        resolvingServices.removeAll { $0 === service }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }
        let port = sender.port

        for data in addresses {
            var addr = sockaddr()
            (data as NSData).getBytes(&addr, length: MemoryLayout<sockaddr>.size)

            if addr.sa_family == UInt8(AF_INET) {
                var addr4 = sockaddr_in()
                (data as NSData).getBytes(&addr4, length: MemoryLayout<sockaddr_in>.size)
                let ip = String(cString: inet_ntoa(addr4.sin_addr))
                // Skip loopback addresses — connecting to 127.x.x.x from the phone
                // would hit the phone's own loopback, not the Mac
                if ip.hasPrefix("127.") {
                    print("[BonjourBrowser] Skipping loopback address: \(ip)")
                    continue
                }
                print("[BonjourBrowser] Resolved: \(sender.name) -> \(ip):\(port)")
                onDiscover(DiscoveredHost(name: sender.name, host: ip, port: port))
                return
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[BonjourBrowser] Failed to resolve \(sender.name): \(errorDict)")
    }
}
