import Foundation
import Network

/// Owns one `WebSocketClient` per paired backend and the per-backend state
/// slice (`BackendSession`). All paired backends stay live (Hot model) so a
/// switch is just a `setActive(_:)` pointer flip — no I/O, sub-frame.
///
/// Persistence: paired backends live in `@AppStorage("pairedBackendsData")` as
/// JSON; PINs live in Keychain (`KeychainBackendPINs`); the active selection
/// lives in `@AppStorage("activeBackendID")`.
@MainActor
@Observable
final class BackendConnectionManager {
    /// Hard cap on the number of paired backends. 4 keeps total keepalive
    /// pings under ~25/min and avoids unbounded socket fan-out.
    static let maxPairedBackends = 4

    private(set) var sessions: [String: BackendSession] = [:]
    var paired: [PairedBackend] = []
    var activeBackendID: String = ""

    /// Convenience: the currently-active session. Falls back to a sentinel
    /// "empty" session before the first pairing so callers can treat it
    /// uniformly.
    var active: BackendSession {
        if let s = sessions[activeBackendID] { return s }
        if let any = sessions.values.first { return any }
        return placeholder
    }

    private let placeholder: BackendSession

    /// Watches OS-level network path transitions (Wi-Fi join/leave, cellular,
    /// VPN flap). On every path change we tell every live client to rewind
    /// its URL pointer to the primary so the next reconnect prefers the LAN
    /// URL again — when you walk back into the house, the client switches
    /// off Tailscale and back to Bonjour LAN automatically. The change
    /// itself doesn't force a reconnect — `WebSocketClient`'s existing
    /// path-change handling does that on its own.
    private var pathMonitor: NWPathMonitor?

    /// Hooks the host (`QuipApp`) sets so that side-effecty things which the
    /// manager itself shouldn't know about — Live Activity, push registration,
    /// pref sync, error toast routing — can react to events from any session,
    /// but only when that session is the active one. The manager passes the
    /// session pointer so the host can compare against `activeBackendID`.
    var onLayoutUpdate: ((BackendSession, LayoutUpdate) -> Void)?
    var onStateChange: ((BackendSession, String, String) -> Void)?
    var onTerminalContent: ((BackendSession, String, String, String?, [String]?) -> Void)?
    var onOutputDelta: ((BackendSession, String, String, String, Bool) -> Void)?
    var onTTSAudio: ((BackendSession, String, String, String, Int, Bool, Data) -> Void)?
    var onSelectWindow: ((BackendSession, String) -> Void)?
    var onProjectDirectories: ((BackendSession, [String]) -> Void)?
    var onITermWindowList: ((BackendSession, [ITermWindowInfo]) -> Void)?
    var onError: ((BackendSession, String) -> Void)?
    var onAuthRequired: ((BackendSession) -> Void)?
    var onAuthResult: ((BackendSession, Bool, String?) -> Void)?
    var onPreferencesRestore: ((BackendSession, PreferencesSnapshot) -> Void)?
    var onMacPermissions: ((BackendSession, MacPermissionsMessage) -> Void)?
    var onImageUploadAck: ((BackendSession, String) -> Void)?
    var onImageUploadError: ((BackendSession, String) -> Void)?
    var onTranscriptResult: ((BackendSession, UUID, String, String?) -> Void)?

    init() {
        // Sentinel session so `active` is never nil before pairing.
        self.placeholder = BackendSession(backendID: "", client: WebSocketClient())
    }

    // MARK: - Single-backend integration helpers
    //
    // The legacy code flow uses one `WebSocketClient` set up in `QuipApp.setup()`
    // (the manager's placeholder). These helpers let that flow persist its PIN
    // to Keychain and react to `device_identity` without forcing the host code
    // through the full multi-backend Hot wiring path. They're a stepping
    // stone — once the picker UI lands, `add(_:pin:)` and `wire(session:)`
    // become the only entry points and these helpers go away.

    /// Upsert a paired entry for this URL and make it active. Called from
    /// every `client.connect(url)` site so the paired list always reflects
    /// what the user has actually connected to. Also ensures a wired
    /// `BackendSession` exists for the entry (Hot model: every paired backend
    /// has a live client). Synthetic `legacy-` ids get rekeyed to the
    /// daemon's real UUID when `device_identity` arrives. Cap-aware: drops
    /// the LRU non-pinned entry to make room.
    func ensureImplicitDefault(url: String) {
        // URL-based dedupe: any existing row whose primary OR fallback
        // URL matches → reuse that row, no new entry. Prevents the
        // "two Backend rows pointing at the same Mac" duplicate seen
        // when the same URL came in via both QR pairing + Bonjour
        // discovery, or via legacy single-URL connect after a
        // multi-URL row already existed.
        if let i = paired.firstIndex(where: { $0.urlsInOrder.contains(url) }) {
            paired[i].lastUsed = Date()
            activeBackendID = paired[i].id
            ensureSession(for: paired[i].id)
            savePaired()
            return
        }
        if paired.count >= Self.maxPairedBackends {
            if let drop = paired.enumerated()
                .filter({ !$0.element.pinned })
                .min(by: { $0.element.lastUsed < $1.element.lastUsed }) {
                let removedID = paired[drop.offset].id
                KeychainBackendPINs.delete(backendID: removedID)
                sessions[removedID]?.client.disconnect()
                sessions.removeValue(forKey: removedID)
                paired.remove(at: drop.offset)
            }
        }
        let id = "legacy-\(UUID().uuidString)"
        paired.append(PairedBackend(id: id, url: url, name: "Backend"))
        activeBackendID = id
        ensureSession(for: id)
        savePaired()
    }

    /// Lazily create + wire a session for a paired entry. No-op if already
    /// present. Doesn't connect — the caller does that (typical pattern: this
    /// is called from `ensureImplicitDefault`, then host code calls
    /// `manager.active.client.connect(url)`).
    private func ensureSession(for id: String) {
        guard sessions[id] == nil else { return }
        let session = BackendSession(backendID: id, client: WebSocketClient())
        wire(session: session)
        sessions[id] = session
    }

    /// Persist a PIN under the active backend's id. Called from the host's
    /// `onAuthResult` success branch.
    func persistPINForActive(_ pin: String) {
        guard !activeBackendID.isEmpty else { return }
        KeychainBackendPINs.write(backendID: activeBackendID, pin: pin)
    }

    /// Pre-populate the active client's `sessionPIN` from Keychain so the
    /// connect-time auto-replay at `WebSocketClient.swift:428` skips the PIN
    /// entry sheet. Safe to call anytime.
    func primeActivePIN() {
        guard !activeBackendID.isEmpty,
              let pin = KeychainBackendPINs.read(backendID: activeBackendID) else { return }
        active.client.sendAuth(pin: pin)  // sets sessionPIN; pre-connect send is no-op.
    }

    /// Rekey the active paired entry to the daemon's real UUID + capture
    /// kind/displayName. Called from the host's `onDeviceIdentity` callback.
    ///
    /// If the rekey lands on a UUID that already exists (user paired the
    /// same Mac via a second URL — Tailscale after Bonjour, etc), merge
    /// the freshly-paired entry's URL into the existing entry's URL list
    /// and drop the duplicate row + duplicate session. Same-Mac dedupe so
    /// the user sees one logical entry with auto-fallback between paths.
    func recordDeviceIdentity(_ identity: DeviceIdentityMessage) {
        guard let i = paired.firstIndex(where: { $0.id == activeBackendID }) else { return }
        let oldID = activeBackendID
        if oldID != identity.deviceID {
            // Existing row for the real UUID? Merge instead of rekey.
            if let existingIdx = paired.firstIndex(where: { $0.id == identity.deviceID }), existingIdx != i {
                // Move freshly-paired row's URL into the existing row's
                // URL list (deduped + re-sorted by network priority).
                var allURLs = paired[existingIdx].urlsInOrder
                for u in paired[i].urlsInOrder where !allURLs.contains(u) {
                    allURLs.append(u)
                }
                allURLs.sort(by: { Self.urlPriority($0) < Self.urlPriority($1) })
                paired[existingIdx].url = allURLs.first ?? paired[existingIdx].url
                paired[existingIdx].fallbackURLs = Array(allURLs.dropFirst())
                paired[existingIdx].lastUsed = Date()
                paired[existingIdx].enabled = paired[existingIdx].enabled || paired[i].enabled
                // Drop the freshly-paired row + its session.
                paired.remove(at: paired.firstIndex(where: { $0.id == oldID })!)
                sessions[oldID]?.client.disconnect()
                sessions.removeValue(forKey: oldID)
                KeychainBackendPINs.delete(backendID: oldID)
                activeBackendID = identity.deviceID
                // Reconnect the surviving session with the merged URL
                // list so it picks up the freshly-paired URL as a
                // fallback option.
                if let session = sessions[identity.deviceID] {
                    session.client.disconnect()
                    primePINIfPresent(session: session)
                    let mergedURLs = urlList(for: paired[paired.firstIndex(where: { $0.id == identity.deviceID })!])
                    connect(session: session, urls: mergedURLs)
                }
                savePaired()
                return
            }
            KeychainBackendPINs.rekey(from: oldID, to: identity.deviceID)
            paired[i].id = identity.deviceID
            activeBackendID = identity.deviceID
        }
        if paired[i].name.isEmpty || paired[i].name == "Backend" {
            paired[i].name = identity.displayName
        }
        paired[i].kind = BackendKind(rawValue: identity.deviceKind) ?? .unknown
        paired[i].lastSeenLayoutMonitorName = identity.displayName
        savePaired()
    }

    // MARK: - Lifecycle

    /// Read persisted paired backends, spawn one client per entry, kick off
    /// auto-connect for entries the user has marked `enabled`. Run once on
    /// launch from `MainiOSView.setup()` after `loadPaired()`.
    ///
    /// Each enabled session gets its cached Keychain PIN seeded BEFORE
    /// the connect call so the connect-time auto-replay at
    /// `WebSocketClient.swift:546` can fire — without this prime, the
    /// client hits the socket without a `sessionPIN`, falls into the
    /// `onAuthRequired` branch, and (because the manager only forwards
    /// auth-required for the active backend) the user is left staring
    /// at "Authenticating…" with no actual PIN entry field.
    func bootstrap() {
        for backend in paired {
            let session = BackendSession(backendID: backend.id, client: WebSocketClient())
            wire(session: session)
            sessions[backend.id] = session
            if backend.enabled {
                let urls = urlList(for: backend)
                if !urls.isEmpty {
                    primePINIfPresent(session: session)
                    connect(session: session, urls: urls)
                }
            }
        }
        if activeBackendID.isEmpty, let first = paired.first {
            activeBackendID = first.id
        }
        startPathMonitor()
    }

    /// Watches OS network path transitions and rewinds every live client's
    /// URL pointer to its primary on each change. Idempotent — a no-op on
    /// repeat calls. Cancelling is implicit at deinit (the monitor's queue
    /// is held by the strong reference).
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.quip.BackendConnectionManager.path")
        monitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                for s in self.sessions.values {
                    s.client.resetToPrimaryURL()
                }
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Toggle whether a paired backend keeps a live connection. Called from
    /// the picker sheet's per-row power button. Disabling drops the socket
    /// but keeps the entry in `paired` so the user can re-enable later
    /// without re-pairing. Enabling spins up a fresh connection.
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let i = paired.firstIndex(where: { $0.id == id }) else { return }
        guard paired[i].enabled != enabled else { return }
        paired[i].enabled = enabled
        savePaired()

        guard let session = sessions[id] else { return }
        if enabled {
            let urls = urlList(for: paired[i])
            if !urls.isEmpty {
                primePINIfPresent(session: session)
                connect(session: session, urls: urls)
            }
        } else {
            session.client.disconnect()
            session.reachability = .unreachable
        }
    }

    /// Pre-load the cached PIN for a session so the client can auto-replay it
    /// once the socket is up. Same idea as `primeActivePIN` but scoped to a
    /// specific session — used when (re)enabling a non-active backend.
    private func primePINIfPresent(session: BackendSession) {
        guard let pin = KeychainBackendPINs.read(backendID: session.backendID) else { return }
        session.client.sendAuth(pin: pin)
    }

    /// Append `url` as a new fallback on an existing paired row at
    /// `rowIndex`, persist `pin` to Keychain, refresh lastUsed, and
    /// force-reconnect the row's session with the merged URL list.
    /// Used when a re-pair attempt or pairing-add lands on a Mac UUID
    /// that's already known.
    private func mergeNewURLInto(rowIndex i: Int, backendID: String, url: String, pin: String) {
        KeychainBackendPINs.write(backendID: backendID, pin: pin)
        var allURLs = paired[i].urlsInOrder
        if !allURLs.contains(url) { allURLs.append(url) }
        allURLs.sort(by: { Self.urlPriority($0) < Self.urlPriority($1) })
        paired[i].url = allURLs.first ?? paired[i].url
        paired[i].fallbackURLs = Array(allURLs.dropFirst())
        paired[i].lastUsed = Date()
        paired[i].enabled = true
        savePaired()
        if let session = sessions[backendID] {
            session.client.disconnect()
            primePINIfPresent(session: session)
            connect(session: session, urls: urlList(for: paired[i]))
        }
    }

    /// Pair a new backend — caller is responsible for prompting for a PIN and
    /// passing it in. Writes PIN to Keychain, appends to `paired`, opens a
    /// connection. The synthetic `backend.id` is rekeyed once the daemon's
    /// `device_identity` arrives (see `wire(session:)` below).
    ///
    /// Already-known id (user paired the same Mac via a different network
    /// path — Bonjour LAN earlier, Tailscale now): append the new URL as a
    /// fallback on the existing entry instead of duplicating the row. Same
    /// Mac, two paths to it, one logical entry — `WebSocketClient.connect`
    /// walks the URL list with auto-fallback.
    func add(_ backend: PairedBackend, pin: String) {
        // Same-id collision: merge fallback URL into existing row.
        if let i = paired.firstIndex(where: { $0.id == backend.id }) {
            mergeNewURLInto(rowIndex: i, backendID: backend.id, url: backend.url, pin: pin)
            return
        }
        // URL-overlap collision: caller fed a URL that already exists in
        // ANOTHER row's primary or fallback list. Same Mac, different id
        // (legacy synthetic vs real UUID, or pre-rekey state). Merge into
        // that other row instead of creating a duplicate. The other row's
        // PIN stays in Keychain under its id; we just refresh lastUsed
        // and reconnect.
        if let i = paired.firstIndex(where: { $0.urlsInOrder.contains(backend.url) }) {
            paired[i].lastUsed = Date()
            paired[i].enabled = true
            activeBackendID = paired[i].id
            savePaired()
            if let session = sessions[paired[i].id] {
                session.client.disconnect()
                primePINIfPresent(session: session)
                connect(session: session, urls: urlList(for: paired[i]))
            }
            return
        }

        guard paired.count < Self.maxPairedBackends else { return }

        KeychainBackendPINs.write(backendID: backend.id, pin: pin)
        paired.append(backend)
        let session = BackendSession(backendID: backend.id, client: WebSocketClient())
        wire(session: session)
        sessions[backend.id] = session
        if activeBackendID.isEmpty {
            activeBackendID = backend.id
        }
        let urls = urlList(for: backend)
        if !urls.isEmpty {
            connect(session: session, urls: urls)
        }
        savePaired()
    }

    /// Forget a backend — disconnect, drop session and Keychain PIN, remove
    /// from `paired`. If we just removed the active backend, fall back to the
    /// first remaining one.
    func remove(_ id: String) {
        sessions[id]?.client.disconnect()
        sessions.removeValue(forKey: id)
        KeychainBackendPINs.delete(backendID: id)
        paired.removeAll { $0.id == id }
        if activeBackendID == id {
            activeBackendID = paired.first?.id ?? ""
        }
        savePaired()
    }

    /// Hot-model switch: pure UI flip when the target is enabled (the live
    /// client is already up). If the target is disabled, also enable it and
    /// kick off a fresh connection — picking a backend from the switcher
    /// implies "I want to use this one now." Returns true if the switch was
    /// issued.
    @discardableResult
    func setActive(_ id: String) -> Bool {
        guard activeBackendID != id,
              sessions[id] != nil,
              let i = paired.firstIndex(where: { $0.id == id }) else { return false }
        if !paired[i].enabled {
            setEnabled(id, true)
        }
        activeBackendID = id
        paired[i].lastUsed = Date()
        savePaired()
        return true
    }

    /// Cycle by `direction` (+1 forward, -1 backward) through the paired list.
    /// Driven by the horizontal swipe on `RemoteLayoutView`.
    @discardableResult
    func cycleActive(direction: Int) -> Bool {
        guard paired.count > 1,
              let i = paired.firstIndex(where: { $0.id == activeBackendID }) else { return false }
        let next = (i + direction + paired.count) % paired.count
        return setActive(paired[next].id)
    }

    /// Append a new paired backend. The synthetic id will be rekeyed to the
    /// daemon's real UUID once `device_identity` arrives. Doesn't connect —
    /// caller flips to it via `setActive(_:)` to start the cold connect.
    @discardableResult
    func addPaired(url: String, name: String = "Backend") -> String? {
        guard paired.count < Self.maxPairedBackends else { return nil }
        // Dedupe across the FULL urlsInOrder (primary + fallbacks), not just
        // primary. The prior check matched only `$0.url == url` and missed
        // the case where the same URL was stored as a fallback on an
        // existing row — producing a duplicate "Backend" entry pointing at
        // the same Mac (visible in QR-pair after a Bonjour-discovery row
        // already had the same URL as a fallback).
        if let existing = paired.first(where: { $0.urlsInOrder.contains(url) }) {
            return existing.id
        }
        let id = "legacy-\(UUID().uuidString)"
        paired.append(PairedBackend(id: id, url: url, name: name))
        savePaired()
        return id
    }

    /// Drop a paired entry + its Keychain PIN + its live `WebSocketClient`.
    /// If we just removed the active backend, fall back to whichever paired
    /// entry's left. Disconnecting the session is what stops the inactive
    /// ghost backend from spinning a reconnect loop forever — the user
    /// "forgot" it but the client kept dialing the dead URL.
    func forget(_ id: String) {
        sessions[id]?.client.disconnect()
        sessions[id]?.client.teardownDiagnostics()
        sessions.removeValue(forKey: id)
        KeychainBackendPINs.delete(backendID: id)
        paired.removeAll { $0.id == id }
        if activeBackendID == id {
            if let next = paired.first {
                activeBackendID = next.id
                let urls = urlList(for: next)
                if !urls.isEmpty {
                    primeActivePIN()
                    active.client.connect(toURLs: urls)
                }
            } else {
                activeBackendID = ""
            }
        }
        savePaired()
    }

    /// User re-entered a PIN after a previous auth failure. Persist the new
    /// PIN and force a reconnect.
    func reauth(_ id: String, pin: String) {
        guard let session = sessions[id],
              let entry = paired.first(where: { $0.id == id }) else { return }
        let urls = urlList(for: entry)
        guard !urls.isEmpty else { return }
        KeychainBackendPINs.write(backendID: id, pin: pin)
        session.client.disconnect()
        session.reachability = .connecting
        connect(session: session, urls: urls)
    }

    /// Backgrounding/foregrounding — pass through to every live client so all
    /// sessions stay sync'd with foreground state.
    func suspendAll() {
        for s in sessions.values { s.client.suspendForBackground() }
    }
    func resumeAll() {
        for s in sessions.values { s.client.resumeFromBackground() }
    }

    // MARK: - Persistence

    func loadPaired() {
        let defaults = UserDefaults.standard
        let raw = defaults.data(forKey: "pairedBackendsData") ?? Data()
        if let decoded = try? JSONDecoder().decode([PairedBackend].self, from: raw), !decoded.isEmpty {
            paired = decoded
            activeBackendID = defaults.string(forKey: "activeBackendID") ?? decoded.first?.id ?? ""
            // First-launch migration: before this build all paired backends
            // auto-connected, which produced multiple parallel sockets to the
            // same Mac (e.g. one Bonjour entry + one Tailscale entry both
            // resolving via Tailscale). Drop everyone except the active to
            // disabled exactly once; the user re-enables the ones they want.
            if !defaults.bool(forKey: "pairedEnabledMigrationV1Done") {
                let activeID = activeBackendID
                for i in paired.indices {
                    paired[i].enabled = (paired[i].id == activeID)
                }
                defaults.set(true, forKey: "pairedEnabledMigrationV1Done")
                savePaired()
            }
            // Multi-URL migration: same-id rows (one Mac paired over both
            // Bonjour LAN and Tailscale) get merged into a single entry
            // whose `url` is the LAN URL (preferred when reachable) and
            // whose `fallbackURLs` are the rest. WebSocketClient.connect
            // walks `urlsInOrder` and advances on TCP-fail / auth-timeout,
            // so the user sees one logical Mac and the right path is
            // chosen automatically.
            // V1 only deduped by id; V2 also collapses entries that share
            // any URL but have different ids (e.g. one row still carrying
            // a `legacy-` synthetic id from before device_identity rekey).
            // Force-run for any device that completed V1 since the
            // overlap case wasn't caught by the earlier pass.
            if !defaults.bool(forKey: "pairedMultiURLMigrationV2Done") {
                paired = Self.mergeSameIDRows(paired)
                defaults.set(true, forKey: "pairedMultiURLMigrationV2Done")
                savePaired()
            }
            // Always run merge on load. mergeSameIDRows is idempotent on
            // already-deduped data (cheap O(n²) over typically 1-3 rows),
            // so re-running every launch costs nothing and prevents the
            // "two identical Backend rows" bug from sticking around once
            // it's somehow snuck through addPaired / ensureImplicitDefault.
            // The V2 one-shot above stays for the migration log line; this
            // unconditional pass is the actual safety net.
            let beforeCount = paired.count
            paired = Self.mergeSameIDRows(paired)
            if paired.count != beforeCount {
                NSLog("[Quip][Backends] Deduped on load: %d → %d rows", beforeCount, paired.count)
                if !paired.contains(where: { $0.id == activeBackendID }) {
                    activeBackendID = paired.first?.id ?? ""
                }
                savePaired()
            }
            return
        }
        // Migrate from the legacy single-backend layout: `lastURL` holds one
        // URL string. Synthesize a single PairedBackend with a `legacy-` id;
        // the manager will rekey it once the daemon's `device_identity`
        // arrives. The PIN is NOT migrated — old code only kept it
        // session-scoped, so the user re-enters it once.
        let legacyURL = defaults.string(forKey: "lastURL") ?? ""
        if !legacyURL.isEmpty {
            let id = "legacy-\(UUID().uuidString)"
            paired = [PairedBackend(id: id, url: legacyURL, name: "Backend")]
            activeBackendID = id
            defaults.set(true, forKey: "pairedEnabledMigrationV1Done")
            savePaired()
        }
    }

    private func savePaired() {
        if let data = try? JSONEncoder().encode(paired) {
            UserDefaults.standard.set(data, forKey: "pairedBackendsData")
        }
        UserDefaults.standard.set(activeBackendID, forKey: "activeBackendID")
    }

    /// Collapse multiple rows that share an `id` OR overlap on any URL
    /// into one row whose `url` is the LAN-preferring primary and whose
    /// `fallbackURLs` carry the rest.
    ///
    /// Two-pass dedupe:
    /// 1. Group by `id`. Same Mac UUID, different paths → merge.
    /// 2. Walk groups; any group sharing a URL with an earlier kept group
    ///    folds into that earlier one (covers the case where one entry
    ///    was rekeyed to the real Mac UUID and the other still has its
    ///    `legacy-` synthetic id, so id-grouping alone misses them).
    ///
    /// URL ordering: Bonjour `.local` first, then RFC1918 LAN
    /// (192.168.*, 10.*, 172.16-31.*), then Tailscale CGNAT (100.64-127.*),
    /// then anything else (Cloudflare tunnel, MagicDNS, etc). `enabled` is
    /// the OR of all merged rows. `lastUsed` becomes the most recent. Other
    /// fields take the first row's values.
    ///
    /// Pure helper — exposed at file scope for unit testing.
    static func mergeSameIDRows(_ entries: [PairedBackend]) -> [PairedBackend] {
        // Pass 1 — collapse same-id rows.
        var byID: [String: [PairedBackend]] = [:]
        var order: [String] = []
        for e in entries {
            if byID[e.id] == nil { order.append(e.id) }
            byID[e.id, default: []].append(e)
        }
        let firstPass: [PairedBackend] = order.map { id -> PairedBackend in
            let group = byID[id] ?? []
            return group.count == 1 ? group[0] : Self.mergeRows(group)
        }

        // Pass 2 — fold any later row whose URL set overlaps an earlier
        // row's URL set. Different ids but same Mac (one synthetic
        // legacy id, one real UUID after device_identity rekey).
        var kept: [PairedBackend] = []
        for row in firstPass {
            let rowURLs = Set(row.urlsInOrder)
            if let i = kept.firstIndex(where: { !Set($0.urlsInOrder).isDisjoint(with: rowURLs) }) {
                kept[i] = Self.mergeRows([kept[i], row])
            } else {
                kept.append(row)
            }
        }
        return kept
    }

    /// Merge a non-empty group of `PairedBackend` rows into a single row.
    /// Caller guarantees the group represents the same Mac (either same
    /// id OR overlapping URL set). First row's metadata wins for
    /// non-mergeable fields (name, kind, pinned).
    private static func mergeRows(_ group: [PairedBackend]) -> PairedBackend {
        var seen = Set<String>()
        var allURLs: [String] = []
        for row in group {
            for url in row.urlsInOrder where !seen.contains(url) {
                seen.insert(url)
                allURLs.append(url)
            }
        }
        allURLs.sort(by: { Self.urlPriority($0) < Self.urlPriority($1) })
        var merged = group[0]
        merged.url = allURLs.first ?? merged.url
        merged.fallbackURLs = Array(allURLs.dropFirst())
        merged.enabled = group.contains(where: { $0.enabled })
        merged.lastUsed = group.map(\.lastUsed).max() ?? merged.lastUsed
        return merged
    }

    /// Lower number = preferred for connect (tried first). Bonjour `.local`
    /// is fastest when reachable, then RFC1918 LAN, then Tailscale CGNAT,
    /// then everything else. Conservative parse — anything that doesn't
    /// look like a URL falls into the last bucket.
    static func urlPriority(_ urlString: String) -> Int {
        guard let url = URL(string: urlString), let host = url.host else { return 99 }
        let h = host.lowercased()
        if h.hasSuffix(".local") { return 0 }
        // RFC1918 LAN ranges
        if h.hasPrefix("192.168.") { return 1 }
        if h.hasPrefix("10.") { return 1 }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return 1
            }
        }
        // Tailscale CGNAT (100.64.0.0/10)
        if h.hasPrefix("100.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (64...127).contains(second) {
                return 2
            }
        }
        // Tailscale MagicDNS suffix
        if h.hasSuffix(".ts.net") { return 2 }
        return 3
    }

    // MARK: - Internals

    private func connect(session: BackendSession, url: URL) {
        connect(session: session, urls: [url])
    }

    /// Multi-URL connect path used by the LAN/Tailscale fallback flow.
    /// Pre-seeds the cached PIN once (Keychain key is per-backendID, so
    /// it's the same PIN regardless of which URL ends up authenticating)
    /// and hands the full URL list to `WebSocketClient.connect(toURLs:)`,
    /// which advances on TCP-fail / auth-timeout.
    private func connect(session: BackendSession, urls: [URL]) {
        guard !urls.isEmpty else { return }
        session.reachability = .connecting
        if let pin = KeychainBackendPINs.read(backendID: session.backendID) {
            session.client.sendAuth(pin: pin)  // sets sessionPIN; safe pre-connect
        }
        session.client.connect(toURLs: urls)
    }

    /// Build the `urlsInOrder` list for a paired backend, dropping any
    /// entries that don't parse as URLs. Used by every connect callsite.
    private func urlList(for backend: PairedBackend) -> [URL] {
        backend.urlsInOrder.compactMap { URL(string: $0) }
    }

    /// Wire every client callback to fan out: (1) update the session's slice,
    /// (2) call the host hook so global side-effects fire only for the active
    /// session. The closures capture `weak session` so a removed backend
    /// doesn't leak its session via callbacks the client still holds.
    private func wire(session: BackendSession) {
        let c = session.client

        c.onLayoutUpdate = { [weak self, weak session] update in
            guard let self, let session else { return }
            session.windows = update.windows
            session.monitorName = update.monitor
            if let a = update.screenAspect, a > 0 { session.screenAspect = a }
            if session.reachability != .connected { session.reachability = .connected }
            if let i = self.paired.firstIndex(where: { $0.id == session.backendID }) {
                self.paired[i].lastSeenLayoutMonitorName = update.monitor
                self.savePaired()
            }
            self.onLayoutUpdate?(session, update)
        }

        c.onStateChange = { [weak self, weak session] windowId, newState in
            guard let self, let session else { return }
            if let i = session.windows.firstIndex(where: { $0.id == windowId }) {
                let w = session.windows[i]
                session.windows[i] = WindowState(
                    id: w.id, name: w.name, app: w.app, folder: w.folder, enabled: w.enabled,
                    frame: w.frame, state: newState, color: w.color,
                    isThinking: w.isThinking, claudeMode: w.claudeMode
                )
            }
            self.onStateChange?(session, windowId, newState)
        }

        c.onTerminalContent = { [weak self, weak session] windowId, content, screenshot, urls in
            guard let self, let session else { return }
            session.terminalContentWindowId = windowId
            session.terminalContentText = content
            if let screenshot, !screenshot.isEmpty {
                session.terminalContentScreenshot = screenshot
            }
            if let urls, !urls.isEmpty {
                session.terminalContentURLs = urls
            }
            self.onTerminalContent?(session, windowId, content, screenshot, urls)
        }

        c.onOutputDelta = { [weak self, weak session] windowId, windowName, text, isFinal in
            guard let self, let session else { return }
            session.ttsOverlayTexts[windowId] = text
            self.onOutputDelta?(session, windowId, windowName, text, isFinal)
        }

        c.onTTSAudio = { [weak self, weak session] windowId, windowName, sessionId, sequence, isFinal, wavData in
            guard let self, let session else { return }
            self.onTTSAudio?(session, windowId, windowName, sessionId, sequence, isFinal, wavData)
        }

        c.onSelectWindow = { [weak self, weak session] windowId in
            guard let self, let session else { return }
            if session.windows.contains(where: { $0.id == windowId }) {
                session.selectedWindowId = windowId
            }
            self.onSelectWindow?(session, windowId)
        }

        c.onProjectDirectories = { [weak self, weak session] dirs in
            guard let self, let session else { return }
            session.projectDirectories = dirs
            self.onProjectDirectories?(session, dirs)
        }

        c.onITermWindowList = { [weak self, weak session] infos in
            guard let self, let session else { return }
            session.iTermScanResults = infos
            self.onITermWindowList?(session, infos)
        }

        c.onMacPermissions = { [weak self, weak session] snapshot in
            guard let self, let session else { return }
            session.macPermissions = snapshot
            self.onMacPermissions?(session, snapshot)
        }

        c.onError = { [weak self, weak session] reason in
            guard let self, let session else { return }
            self.onError?(session, reason)
        }

        c.onAuthRequired = { [weak self, weak session] in
            guard let self, let session else { return }
            // If we have a PIN in Keychain, send it now without prompting.
            // `sendAuth` sets `sessionPIN` (which is private(set)) and sends.
            if let pin = KeychainBackendPINs.read(backendID: session.backendID) {
                session.client.sendAuth(pin: pin)
                return
            }
            session.reachability = .needsAuth
            self.onAuthRequired?(session)
        }

        c.onAuthResult = { [weak self, weak session] success, error in
            guard let self, let session else { return }
            if success {
                session.reachability = .connected
            } else {
                session.reachability = .needsAuth
                // Stale PIN — drop it from Keychain; user will be prompted on
                // tap in the picker.
                KeychainBackendPINs.delete(backendID: session.backendID)
            }
            self.onAuthResult?(session, success, error)
        }

        c.onDeviceIdentity = { [weak self, weak session] identity in
            guard let self, let session else { return }
            // Rekey the synthetic legacy id to the daemon's real UUID.
            let oldID = session.backendID
            if oldID == identity.deviceID { return }
            KeychainBackendPINs.rekey(from: oldID, to: identity.deviceID)
            self.sessions.removeValue(forKey: oldID)
            // BackendSession.backendID is `let`; rebuild the session under the
            // real id. The client and accumulated state are reused.
            let rebuilt = BackendSession(backendID: identity.deviceID, client: session.client)
            rebuilt.windows = session.windows
            rebuilt.selectedWindowId = session.selectedWindowId
            rebuilt.monitorName = session.monitorName
            rebuilt.screenAspect = session.screenAspect
            rebuilt.terminalContentText = session.terminalContentText
            rebuilt.terminalContentScreenshot = session.terminalContentScreenshot
            rebuilt.terminalContentURLs = session.terminalContentURLs
            rebuilt.terminalContentWindowId = session.terminalContentWindowId
            rebuilt.projectDirectories = session.projectDirectories
            rebuilt.iTermScanResults = session.iTermScanResults
            rebuilt.macPermissions = session.macPermissions
            rebuilt.ttsOverlayTexts = session.ttsOverlayTexts
            rebuilt.reachability = session.reachability
            self.wire(session: rebuilt)
            self.sessions[identity.deviceID] = rebuilt
            if let i = self.paired.firstIndex(where: { $0.id == oldID }) {
                self.paired[i].id = identity.deviceID
                self.paired[i].name = self.paired[i].name.isEmpty ? identity.displayName : self.paired[i].name
                self.paired[i].kind = BackendKind(rawValue: identity.deviceKind) ?? .unknown
                self.savePaired()
            }
            if self.activeBackendID == oldID {
                self.activeBackendID = identity.deviceID
            }
        }

        c.onPreferencesRestore = { [weak self, weak session] snap in
            guard let self, let session else { return }
            self.onPreferencesRestore?(session, snap)
        }

        c.onTranscriptResult = { [weak self, weak session] sid, text, error in
            guard let self, let session else { return }
            self.onTranscriptResult?(session, sid, text, error)
        }

        // image_upload_ack and image_upload_error were dropped from the
        // wire() bridge during the multi-backend hot-model rework — the
        // WebSocketClient receives them and fires its own callbacks, but
        // nothing forwards to the manager-level closures the host
        // (QuipApp.swift:945) actually subscribed to. Result: every photo
        // upload looked stuck on iOS even though the Mac wrote the file
        // and typed the path successfully — the 10s watchdog would fire
        // with "no response (last stage: sent, awaiting ack)".
        c.onImageUploadAck = { [weak self, weak session] savedPath in
            guard let self, let session else { return }
            self.onImageUploadAck?(session, savedPath)
        }
        c.onImageUploadError = { [weak self, weak session] reason in
            guard let self, let session else { return }
            self.onImageUploadError?(session, reason)
        }
    }
}
