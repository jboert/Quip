// BonjourBrowser.swift
// QuipiOS — Discovers Quip Mac instances on the local network via Bonjour

import Foundation
import Observation

struct DiscoveredHost: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    /// The advertising Mac's stable device UUID, read from the Bonjour TXT
    /// record ("did"). Present when the Mac runs the TXT-fold build; nil for
    /// older Macs. Lets the phone fold this LAN URL into an existing paired
    /// row instead of offering it as a brand-new backend.
    var deviceID: String?
    var wsURL: URL? {
        URL(string: "ws://\(host):\(port)")
    }
}

/// Which discovered Macs the connect bar offers (PRD 2026-10-07, US-012).
///
/// A Mac whose TXT `did` matches a paired row used to be hidden outright, on
/// the assumption that `ingestDiscoveredHost` had folded its address into
/// that row. When the row's own URLs were dead, that left nothing to tap:
/// the only one-tap option redialed the dead address. A paired Mac is now
/// listed whenever its row is not connected, so there is always a way back
/// in; a paired Mac that is connected stays hidden, since its row already
/// works. Pure / unit-testable.
enum DiscoveredHostFilter {
    static func visible(hosts: [DiscoveredHost],
                        paired: [PairedBackend],
                        connectedBackendIDs: Set<String>) -> [DiscoveredHost] {
        hosts.filter { host in
            guard let did = host.deviceID,
                  paired.contains(where: { $0.id == did }) else { return true }  // a new Mac
            return !connectedBackendIDs.contains(did)
        }
    }
}

/// The part of a Bonjour browse that `BackendConnectionManager` uses to find
/// a Mac again after all of its saved URLs stopped answering (US-012).
/// `BonjourBrowser` is the real one; tests pass a fake.
@MainActor
protocol MacRediscovering: AnyObject {
    var discoveredHosts: [DiscoveredHost] { get }
    func startBrowsing()
    func stopBrowsing()
}

@Observable
@MainActor
final class BonjourBrowser: MacRediscovering {

    private(set) var discoveredHosts: [DiscoveredHost] = []
    private(set) var isSearching = false
    /// Flips true ~4s after `startBrowsing` if discovery is still running.
    /// The Connect Bar uses `graceElapsed && discoveredHosts.isEmpty` to show
    /// a "no Macs found — Local Network access may be off" hint, without
    /// flashing it during the normal first-few-seconds-empty window. (iOS
    /// exposes no clean read of the Local Network permission, so this is a
    /// heuristic, not a hard status.)
    private(set) var graceElapsed = false

    private var delegate: BonjourDelegate?

    /// Monotonic browse-session token. Bumped on every `startBrowsing` and
    /// `stopBrowsing` so a grace-timer Task that captured an earlier value
    /// can detect it is an orphan from a prior browse session (a stop+restart
    /// within the 4s window) and decline to flip `graceElapsed` early.
    private var browseGeneration = 0

    /// Whether a grace-timer Task that captured browse-generation `captured`
    /// should still flip `graceElapsed`. Valid only when no start/stop has
    /// advanced the generation since the Task was scheduled AND a browse is
    /// still active — otherwise the Task belongs to a superseded session and
    /// must be ignored. Pure / unit-testable.
    static func graceStillValid(captured: Int, current: Int, isSearching: Bool) -> Bool {
        captured == current && isSearching
    }

    /// Two discovered rows describe the same Mac when both carry a TXT
    /// deviceID and it matches, or, when either has none (an older Mac, or
    /// the TXT record not read yet), when the Bonjour service name matches.
    /// Bonjour keeps service names unique on a link.
    static func sameService(_ a: DiscoveredHost, _ b: DiscoveredHost) -> Bool {
        if let da = a.deviceID, let db = b.deviceID { return da == db }
        return a.name == b.name
    }

    /// `hosts` with `host` folded in. A row for the same Mac at a different
    /// address is replaced, so an address resolved later takes the earlier
    /// row's place instead of sitting next to it as a second row for one Mac:
    /// the browser used to dedupe on host + port, which listed a Mac's
    /// link-local and LAN addresses as two Macs. A routable address is never
    /// replaced by a link-local one, and a repeat of the same address keeps
    /// the existing row (only learning a deviceID it lacked). Pure /
    /// unit-testable.
    static func merging(_ hosts: [DiscoveredHost], with host: DiscoveredHost) -> [DiscoveredHost] {
        var out = hosts
        guard let i = out.firstIndex(where: { sameService($0, host) }) else {
            out.append(host)
            return out
        }
        let sameAddress = out[i].host == host.host && out[i].port == host.port
        let wouldDowngrade = !BonjourAddressPicker.isLinkLocalIPv4(out[i].host)
            && BonjourAddressPicker.isLinkLocalIPv4(host.host)
        if sameAddress || wouldDowngrade {
            if out[i].deviceID == nil, let did = host.deviceID { out[i].deviceID = did }
        } else {
            out[i] = host
        }
        return out
    }

    func startBrowsing() {
        guard !isSearching else { return }
        discoveredHosts = []
        graceElapsed = false
        browseGeneration &+= 1
        let generation = browseGeneration

        let del = BonjourDelegate { [weak self] host in
            Task { @MainActor in
                guard let self else { return }
                let merged = Self.merging(self.discoveredHosts, with: host)
                if merged != self.discoveredHosts { self.discoveredHosts = merged }
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

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self,
                  Self.graceStillValid(captured: generation,
                                       current: self.browseGeneration,
                                       isSearching: self.isSearching) else { return }
            self.graceElapsed = true
        }
    }

    func stopBrowsing() {
        delegate?.stop()
        delegate = nil
        isSearching = false
        graceElapsed = false
        browseGeneration &+= 1
    }
}

// Non-isolated delegate that handles NetService callbacks. NetService delivers
// them on the run loop that started the browse and the resolve, the main one
// (`startBrowsing` is main-actor), so the held-pick bookkeeping below is only
// touched on the main thread.
private class BonjourDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private let onDiscover: (DiscoveredHost) -> Void
    private let onRemove: (String) -> Void
    private let serviceType = "_quip._tcp."

    /// How long a link-local pick waits for a routable address from a later
    /// `netServiceDidResolveAddress` before it is offered anyway. The resolve
    /// stopping releases it sooner.
    static let linkLocalHoldSeconds: TimeInterval = 1.0

    /// Link-local picks waiting out `linkLocalHoldSeconds`, by service name.
    /// `netServiceDidResolveAddress` can fire more than once per resolve as
    /// addresses arrive; the old code offered the link-local fallback at the
    /// end of the first callback, so a routable address in a later one came
    /// too late to win (US-012).
    private var heldLinkLocal: [String: (host: DiscoveredHost, release: DispatchWorkItem)] = [:]

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
        for held in heldLinkLocal.values { held.release.cancel() }
        heldLinkLocal.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[BonjourBrowser] Found: \(service.name)")
        resolvingServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        heldLinkLocal.removeValue(forKey: service.name)?.release.cancel()
        onRemove(service.name)
        resolvingServices.removeAll { $0 === service }
    }

    /// Pull the Mac's advertised deviceID out of the Bonjour TXT record.
    private func deviceID(from sender: NetService) -> String? {
        guard let txt = sender.txtRecordData() else { return nil }
        let dict = NetService.dictionary(fromTXTRecord: txt)
        guard let data = dict["did"], let id = String(data: data, encoding: .utf8), !id.isEmpty else { return nil }
        return id
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let ipv4 = BonjourAddressPicker.ipv4Strings(from: sender.addresses ?? [])
        guard let ip = BonjourAddressPicker.pick(ipv4) else {
            print("[BonjourBrowser] \(sender.name): no usable IPv4 yet (\(ipv4.count) IPv4 address(es))")
            return
        }
        let host = DiscoveredHost(name: sender.name, host: ip, port: sender.port,
                                  deviceID: deviceID(from: sender))
        guard BonjourAddressPicker.isLinkLocalIPv4(ip) else {
            // A routable address wins at once, over any link-local pick still
            // being held for this service.
            heldLinkLocal.removeValue(forKey: sender.name)?.release.cancel()
            print("[BonjourBrowser] Resolved: \(sender.name) -> \(ip):\(sender.port) did=\(host.deviceID?.prefix(8) ?? "nil")")
            onDiscover(host)
            return
        }
        // Link-local only, so far. Hold it so a routable address from a later
        // callback can win; the first hold's timer stands, a repeat callback
        // only refreshes what will be offered.
        if let held = heldLinkLocal[sender.name] {
            heldLinkLocal[sender.name] = (host, held.release)
            return
        }
        print("[BonjourBrowser] \(sender.name): only link-local \(ip) so far — holding \(Self.linkLocalHoldSeconds)s for a routable address")
        let name = sender.name
        let release = DispatchWorkItem { [weak self] in self?.releaseHeld(name) }
        heldLinkLocal[name] = (host, release)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkLocalHoldSeconds, execute: release)
    }

    /// The resolve is over (timed out, or stopped): a held link-local pick
    /// is the best this service will get, so offer it now.
    func netServiceDidStop(_ sender: NetService) {
        releaseHeld(sender.name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        print("[BonjourBrowser] Failed to resolve \(sender.name): \(errorDict)")
        releaseHeld(sender.name)
    }

    private func releaseHeld(_ name: String) {
        guard let held = heldLinkLocal.removeValue(forKey: name) else { return }
        held.release.cancel()
        print("[BonjourBrowser] Resolved (link-local fallback): \(name) -> \(held.host.host):\(held.host.port)")
        onDiscover(held.host)
    }
}
