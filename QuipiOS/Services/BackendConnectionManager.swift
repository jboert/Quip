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

    /// Phase 3: latency probe + auto-swap orchestration for the ACTIVE
    /// session only. Inactive sessions don't need probes — no traffic
    /// flows through them, so a swap on an inactive session would be
    /// invisible until the user flipped to it. Cost cap: one probe loop
    /// at any time across all paired backends.
    private var probeService: LatencyProbeService?
    /// Timestamp of the most recent successful URL hot-swap. Stamped into
    /// `URLSwapPolicy.decide` for hysteresis. Cleared when the active
    /// backend changes (the new backend's swap history is its own).
    private var lastSwapAt: Date?
    /// Polling task for swap evaluations. Distinct from probe cadence
    /// (probes gather data; this evaluates whether to act on the data).
    private var swapEvaluatorTask: Task<Void, Never>?
    /// UserDefaults-backed toggle. Read at task start so a user flip
    /// takes effect on the next eval tick. Defaults OFF until the
    /// first hardware-verified release; opt-in keeps the rollout safe.
    static let autoSwapDefaultsKey = "latencyAutoSwapEnabled"

    /// Hooks the host (`QuipApp`) sets so that side-effecty things which the
    /// manager itself shouldn't know about — Live Activity, push registration,
    /// pref sync, error toast routing — can react to events from any session,
    /// but only when that session is the active one. The manager passes the
    /// session pointer so the host can compare against `activeBackendID`.
    var onLayoutUpdate: ((BackendSession, LayoutUpdate) -> Void)?
    /// swrm story moved into `in_progress` ("Started"). Host shows a card/toast
    /// for the active session. (US-004.)
    var onSwrmStoryStarted: ((BackendSession, SwrmStoryStartedMessage) -> Void)?
    var onStateChange: ((BackendSession, String, String) -> Void)?
    var onTerminalContent: ((BackendSession, String, String, String?, [String]?, Bool) -> Void)?
    var onOutputDelta: ((BackendSession, String, String, String, Bool) -> Void)?
    var onTTSAudio: ((BackendSession, String, String, String, Int, Bool, Data) -> Void)?
    var onSelectWindow: ((BackendSession, String) -> Void)?
    /// Mac broadcasts its current frontmost ManagedWindow.id (or nil if
    /// untracked). Host uses it for the "follow Mac frontmost" feature.
    /// (wishlist §B16.)
    var onFrontmostChanged: ((BackendSession, String?) -> Void)?
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
    /// Fired when the Mac drops a QA pair for a backend (window closed,
    /// off-screen >5s, or post-reconnect ID mismatch). Hosts use this to
    /// surface a toast and ensure the layout view falls back to the grid.
    /// Called after the pair is cleared. `lostPair` is the pair that was active
    /// before clearing — useful for purging per-windowId content maps.
    var onQAPairLost: ((BackendSession, QAPair?, String, String) -> Void)?

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
                // Tailscale-first, consistent with every other merge path
                // (mergeNewURLInto / mergeRows / mergedURLOrder).
                allURLs = Self.mergedURLOrder(allURLs)
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
            // Guard against two paired rows sharing an id (a rekey/merge
            // race): overwriting sessions[id] would orphan a still-wired,
            // still-live client and produce the dual-socket flap. Keep the
            // first; mergeSameIDRows should have collapsed these already.
            if sessions[backend.id] != nil { continue }
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
        // Phase 3: bring up the latency probe + swap evaluator targeting
        // whichever backend is active. Both stay live across foreground/
        // background; tasks are cheap and self-throttling.
        rebindProbeService()
        startSwapEvaluator()
    }

    // MARK: - Phase 3: latency probe + URL hot-swap orchestration

    /// Spin up (or replace) the probe service against the active session.
    /// Called from `bootstrap`, `setActive`, and after `add`/`forget` so the
    /// probe always targets whoever is current. No-op when no session is
    /// active or the active session lacks alt URLs to probe.
    private func rebindProbeService() {
        probeService?.stop()
        probeService = nil
        guard !activeBackendID.isEmpty,
              let session = sessions[activeBackendID] else { return }
        let activeID = activeBackendID
        let service = LatencyProbeService(
            client: session.client,
            urlsProvider: { [weak self] in
                guard let self,
                      let entry = self.paired.first(where: { $0.id == activeID }) else { return [] }
                return entry.urlsInOrder.compactMap { URL(string: $0) }
            },
            currentURLProvider: { [weak session] in
                session?.client.serverURL
            }
        )
        service.start()
        probeService = service
    }

    /// Periodic evaluator. Runs every 30s; reads the toggle, calls
    /// URLSwapPolicy.decide, and orchestrates a hot-swap if the policy
    /// returns a non-nil URL. Disabled-by-default until hardware-verified
    /// (toggle in Settings → Diagnostics → Latency).
    private func startSwapEvaluator() {
        swapEvaluatorTask?.cancel()
        swapEvaluatorTask = Task { [weak self] in
            // Initial 10s grace so a freshly-bootstrapped manager has a
            // chance to gather samples before the first eval. Otherwise
            // the policy returns nil every 30s for the first few minutes
            // and we waste log lines.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            while !Task.isCancelled {
                await self?.evaluateSwap()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    /// One eval pass. Returns the URL we swapped to (if any) for testability.
    @discardableResult
    func evaluateSwap() async -> URL? {
        guard UserDefaults.standard.bool(forKey: Self.autoSwapDefaultsKey) else { return nil }
        guard !activeBackendID.isEmpty,
              let session = sessions[activeBackendID],
              let entry = paired.first(where: { $0.id == activeBackendID }),
              let currentURL = session.client.serverURL else { return nil }
        let candidates = entry.urlsInOrder.compactMap { URL(string: $0) }
        guard candidates.count > 1 else { return nil }
        let samples = session.client.latencySamples
        guard let target = URLSwapPolicy.decide(
            currentURL: currentURL,
            candidates: candidates,
            samples: samples,
            lastSwapAt: lastSwapAt
        ) else { return nil }
        await performHotSwap(session: session, entry: entry, target: target)
        return target
    }

    /// The single reorder-and-reconnect dance shared by `performHotSwap` (the
    /// automatic latency swap) and `switchToLANPath` (the manual "Use Local
    /// Network" tap), defined once so the two reconnect paths cannot drift.
    /// Moves `preferred` to index 0 of the session's in-memory URL list — the
    /// reorder is tactical and deliberately NOT persisted (`savePaired()` is
    /// not called; relaunch restores the saved Tailscale-first order) — then
    /// disconnects, marks the reachability `.connecting`, re-primes the
    /// Keychain PIN, and reconnects onto the reordered list. `lastSwapAt` is
    /// stamped so the auto-evaluator won't immediately fight a just-completed
    /// swap.
    private func reconnect(
        session: BackendSession,
        entry: PairedBackend,
        preferring preferred: URL
    ) {
        var reordered = entry.urlsInOrder.compactMap { URL(string: $0) }
        reordered.removeAll { $0 == preferred }
        reordered.insert(preferred, at: 0)
        session.client.disconnect()
        session.reachability = .connecting
        primePINIfPresent(session: session)
        session.client.connect(toURLs: reordered)
        lastSwapAt = Date()
    }

    /// Orchestrate the automatic latency-driven swap. Reorders `urlsInOrder`
    /// in-memory only — we don't `savePaired()` because the user's preference
    /// order should be preserved across launches; swaps are tactical, not
    /// structural. Delegates the reorder/disconnect/reconnect to `reconnect`.
    private func performHotSwap(
        session: BackendSession,
        entry: PairedBackend,
        target: URL
    ) async {
        let fromHost = session.client.serverURL?.host ?? "?"
        let toHost = target.host ?? "?"
        NSLog("[Quip][LATENCY] hot-swap: from=%@ to=%@ reason=avg-30%%-faster",
              fromHost, toHost)
        reconnect(session: session, entry: entry, preferring: target)
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
        // Use the shared Tailscale-first ordering so the re-pair path agrees
        // with load/dedup (mergeSameIDRows/mergeRows). Previously this sorted
        // purely by urlPriority (LAN-first), so re-pairing a known Mac flipped
        // the primary vs a restart — silent URL-order churn. Safe to prefer
        // Tailscale now that a stalled TS primary auto-fails-over to LAN
        // (see WebSocketClient.startAuthTimeout).
        allURLs = Self.mergedURLOrder(allURLs)
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
        // Phase 3: re-bind the probe service to the new active session.
        // Old probe service stops; fresh one starts targeting the new
        // backend's URL list. Swap history resets — the new backend's
        // hysteresis is its own.
        rebindProbeService()
        lastSwapAt = nil
        return true
    }

    /// Cycle by `direction` (+1 forward, -1 backward) through the paired list.
    /// Driven by the horizontal swipe on the main layout surface.
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
        // Empty is the fresh-install path. A non-empty blob that won't decode
        // means every paired Mac silently disappears and the user is dumped
        // back on the pairing screen with no explanation — log it loudly.
        var decodedOrNil: [PairedBackend]?
        if !raw.isEmpty {
            do {
                decodedOrNil = try JSONDecoder().decode([PairedBackend].self, from: raw)
            } catch {
                print("[Quip][Connections] loadPaired FAILED bytes=\(raw.count) err=\(error) — ALL paired Macs lost, falling back to unpaired")
            }
        }
        if let decoded = decodedOrNil, !decoded.isEmpty {
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
            // V3 one-shot: fold PRE-EXISTING duplicate rows the id/URL passes
            // above can't catch — different ids, disjoint URL sets, same Mac (a
            // LAN row + a Tailscale row whose second path never authed, so its
            // id never rekeyed). Matches on the Mac's monitor display name with
            // a strict both-non-nil-and-equal guard, so two differently-named
            // Macs never merge. One-shot so a false positive can't recur.
            if !defaults.bool(forKey: "pairedDupMonitorMigrationV3Done") {
                let beforeMon = paired.count
                paired = Self.consolidateByMonitorName(paired)
                defaults.set(true, forKey: "pairedDupMonitorMigrationV3Done")
                if paired.count != beforeMon {
                    NSLog("[Quip][Backends] Monitor-name dedup: %d → %d rows", beforeMon, paired.count)
                    if !paired.contains(where: { $0.id == activeBackendID }) {
                        activeBackendID = paired.first?.id ?? ""
                    }
                    savePaired()
                }
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
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(paired), forKey: "pairedBackendsData")
        } catch {
            print("[Quip][Connections] savePaired FAILED count=\(paired.count) err=\(error) — pairing NOT persisted, will be gone on next launch")
        }
        UserDefaults.standard.set(activeBackendID, forKey: "activeBackendID")
    }

    /// Merge a restored backup (from the Mac's prefs mirror) into live state.
    /// Loads are overwrite-only, so we UNION the restored rows into `paired`
    /// via the same dedup used at launch — keeping any currently-live session
    /// authoritative (a restored row that turns out to be a same-Mac duplicate
    /// collapses through `mergeSameIDRows`, and the same-device-gated reap on
    /// the next `device_identity` finishes the job). Then spawn sessions for
    /// newly-restored `enabled` rows without disturbing existing ones. Called
    /// from `PreferencesSyncService.onRestorePaired` after a reinstall.
    func mergeRestoredBackends(_ json: String, activeID: String?) {
        guard let data = json.data(using: .utf8) else {
            print("[Quip][Connections] mergeRestoredBackends FAILED: payload is not valid UTF-8 — pairings NOT restored from Mac")
            return
        }
        let restored: [PairedBackend]
        do {
            restored = try JSONDecoder().decode([PairedBackend].self, from: data)
        } catch {
            print("[Quip][Connections] mergeRestoredBackends FAILED bytes=\(data.count) err=\(error) — pairings NOT restored from Mac")
            return
        }
        // Empty is legitimate: the Mac simply has no backup for this device.
        guard !restored.isEmpty else { return }
        let before = paired
        paired = Self.mergeSameIDRows(paired + restored)
        // Nothing genuinely new after dedup → don't churn sessions/persistence.
        if paired == before { return }
        savePaired()
        // Spawn sessions for any newly-present rows. The `sessions[id] != nil`
        // guard leaves live connections untouched (same guard as bootstrap()).
        for backend in paired where sessions[backend.id] == nil {
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
        // Re-select the backed-up active backend only if nothing is active yet
        // (never steal focus from a connection the user is already using).
        if activeBackendID.isEmpty {
            if let activeID, paired.contains(where: { $0.id == activeID }) {
                activeBackendID = activeID
            } else if let first = paired.first {
                activeBackendID = first.id
            }
            savePaired()
        }
        rebindProbeService()
    }

    /// Compute a paired row's URL list after learning a Bonjour-discovered LAN
    /// URL for that same Mac: union + Tailscale-first order. Returns nil when
    /// the URL adds nothing (already present, or order unchanged). Pure —
    /// exposed at file scope for unit testing.
    static func foldDiscoveredURL(into existing: [String], url: String) -> [String]? {
        guard !existing.contains(url) else { return nil }
        let merged = mergedURLOrder(existing + [url])
        return merged == existing ? nil : merged
    }

    /// Bonjour discovered a Mac advertising `deviceID` at `url`. If we already
    /// have a paired row for that deviceID, fold the LAN URL into it (as a
    /// fallback) and return true so the caller HIDES it from the "new host"
    /// list — the anti-flap contract: a known Mac augments its existing row and
    /// never spawns a second backend. Unknown or nil deviceID returns false so
    /// the caller can still offer it as a brand-new pairing.
    @discardableResult
    func ingestDiscoveredHost(deviceID: String?, url: String) -> Bool {
        guard let deviceID, let i = paired.firstIndex(where: { $0.id == deviceID }) else { return false }
        if let refreshed = Self.foldDiscoveredURL(into: paired[i].urlsInOrder, url: url) {
            paired[i].url = refreshed.first ?? paired[i].url
            paired[i].fallbackURLs = Array(refreshed.dropFirst())
            savePaired()
        }
        return true
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

    /// One-shot dedup for PRE-EXISTING duplicates that `mergeSameIDRows` cannot
    /// fold — rows with DIFFERENT ids AND disjoint URL sets that are actually
    /// the same Mac (a LAN row + a Tailscale row whose second path never
    /// completed auth, so its synthetic `legacy-` id was never rekeyed). The
    /// only persisted same-Mac signal left is the Mac's monitor display name.
    /// Folds ONLY when both rows have a non-nil, non-empty, EQUAL
    /// `lastSeenLayoutMonitorName` and different ids — nil is not evidence of
    /// sameness, so a never-connected row is never merged. The real-UUID row
    /// (non-`legacy-` id) is kept as the survivor. Run once (migration-gated)
    /// so a false positive on two same-named Macs can't recur every launch.
    static func consolidateByMonitorName(_ entries: [PairedBackend]) -> [PairedBackend] {
        var kept: [PairedBackend] = []
        for row in entries {
            guard let name = row.lastSeenLayoutMonitorName, !name.isEmpty,
                  let i = kept.firstIndex(where: {
                      $0.lastSeenLayoutMonitorName == name && $0.id != row.id
                  }) else {
                kept.append(row)
                continue
            }
            // Keep the real-UUID row as survivor (mergeRows takes group[0]'s id).
            let pair = row.id.hasPrefix("legacy-") ? [kept[i], row] : [row, kept[i]]
            kept[i] = Self.mergeRows(pair)
        }
        return kept
    }

    /// Merge a non-empty group of `PairedBackend` rows into a single row.
    /// Caller guarantees the group represents the same Mac (either same
    /// id OR overlapping URL set). First row's metadata wins for
    /// non-mergeable fields (name, kind, pinned).
    /// Order merged URLs Tailscale-FIRST, then by `urlPriority`. A Tailscale
    /// peer (100.64/10 or *.ts.net, i.e. `urlPriority == 2`) is reachable on
    /// any network, so for a phone that roams off home Wi-Fi it's the stable
    /// primary — it avoids the reconnect churn of a LAN-only primary that
    /// dies every time you leave the LAN. LAN/Bonjour stay as faster
    /// fallbacks for when you're home. (User preference; single-path
    /// backends are unaffected since there's nothing to reorder.)
    static func mergedURLOrder(_ urls: [String]) -> [String] {
        urls.sorted { a, b in
            let ta = urlPriority(a) == 2, tb = urlPriority(b) == 2
            if ta != tb { return ta }                  // Tailscale first
            let pa = urlPriority(a), pb = urlPriority(b)
            if pa != pb { return pa < pb }             // else existing priority
            return a < b                               // deterministic tiebreaker for equal-priority URLs
        }
    }

    private static func mergeRows(_ group: [PairedBackend]) -> PairedBackend {
        var seen = Set<String>()
        var allURLs: [String] = []
        for row in group {
            for url in row.urlsInOrder where !seen.contains(url) {
                seen.insert(url)
                allURLs.append(url)
            }
        }
        allURLs = Self.mergedURLOrder(allURLs)
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
        // RFC1918 LAN ranges — delegate to the shared NetworkClassifier so the
        // phone's LAN bucket and the Mac's isPrivateIPv4 advertise gate stay in
        // lockstep (single source of truth). `url.host` strips the port, so `h`
        // is a bare IP literal for LAN URLs.
        if NetworkClassifier.isRFC1918IPv4(h) { return 1 }
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

    // MARK: - Local-network switch (§ "Use Local Network")

    /// True when `url` is a local-network endpoint — Bonjour `.local`
    /// (priority 0) or an RFC1918 LAN IP (priority 1). Tailscale and tunnels
    /// are not LAN. Drives the picker's "Use Local Network" affordance.
    static func isLANURL(_ url: URL) -> Bool {
        urlPriority(url.absoluteString) <= 1
    }

    /// Human label for the transport a URL rides on. Shown next to the
    /// switch control so the user can see which path they're currently on.
    static func pathLabel(for url: URL?) -> String {
        guard let url else { return "—" }
        switch urlPriority(url.absoluteString) {
        case 0, 1: return "Local network"
        case 2:    return "Tailscale"
        default:   return "Remote"
        }
    }

    /// Pure refresh of the LAN-class URLs in an existing `urlsInOrder` list
    /// against the Mac's freshly-advertised `localURLs`. The Mac's DHCP LAN IP
    /// can change between connects, so `localURLs` is treated as *current
    /// truth*: stale LAN-class entries (`urlPriority <= 1`) are DROPPED and
    /// replaced with the advertised set — never accumulated. Non-LAN transports
    /// (Tailscale, tunnels) are left untouched, and the result is re-sorted
    /// Tailscale-first so the live primary isn't disturbed. Empty `localURLs`
    /// (older Mac that doesn't advertise) is a no-op — we never strip the only
    /// known LAN path on the strength of silence. Pure / unit-testable.
    static func urlsByRefreshingLocal(_ existing: [String], _ localURLs: [String]) -> [String] {
        guard !localURLs.isEmpty else { return existing }   // silence ≠ "drop LAN"
        // Keep every URL that isn't a raw private-IP LAN URL (urlPriority 1) and
        // replace those with the advertised set. The Bonjour `.local` fallback
        // (urlPriority 0) is DHCP-stable — it re-resolves after the Mac's LAN IP
        // changes — so it is PRESERVED across a raw-IP refresh, never dropped.
        var all = existing.filter { u in
            guard let url = URL(string: u) else { return true }
            return urlPriority(url.absoluteString) != 1
        }
        for u in localURLs where !all.contains(u) { all.append(u) }
        let refreshed = mergedURLOrder(all)
        return refreshed == existing ? existing : refreshed
    }

    /// Merge LAN URLs from a peer's `device_identity` into the paired row at
    /// `backendID`. Updates the persisted URL list only — does not touch the
    /// live socket (fallback URLs are consumed on the next reconnect, and the
    /// manual `switchToLANPath` triggers that explicitly). No-op when there's
    /// nothing new to add.
    private func ingestLocalURLs(_ localURLs: [String], into backendID: String) {
        guard !localURLs.isEmpty,
              let i = paired.firstIndex(where: { $0.id == backendID }) else { return }
        let merged = Self.urlsByRefreshingLocal(paired[i].urlsInOrder, localURLs)
        guard merged != paired[i].urlsInOrder else { return }
        paired[i].url = merged.first ?? paired[i].url
        paired[i].fallbackURLs = Array(merged.dropFirst())
        savePaired()
    }

    /// Force a backend's live connection onto its local-network URL. Mirrors
    /// `performHotSwap`: reorder the LAN URL to index 0 in-memory (so a
    /// `resetToPrimaryURL` on a Wi-Fi path change keeps LAN rather than
    /// reverting to the Tailscale primary), then reconnect. The reorder is
    /// not persisted — relaunch returns to the saved Tailscale-first order, so
    /// the switch is tactical, matching the hot-swap contract. No-op when the
    /// session is already on its LAN URL or has no LAN URL to switch to.
    /// The LAN URL to switch a live connection onto, preferring a concrete
    /// reachable RFC1918 IP (urlPriority 1) over a Bonjour `.local` host
    /// (urlPriority 0). A flaky or permission-off mDNS resolver can leave
    /// `.local` unresolvable, so an explicit "Use Local Network" tap must not
    /// dead-end on it while a raw IP is available; `.local` is the last LAN
    /// resort, used only when no concrete IP is known. Pure / unit-testable.
    static func preferredLANURL(from urls: [URL]) -> URL? {
        urls.first(where: { urlPriority($0.absoluteString) == 1 })
            ?? urls.first(where: { urlPriority($0.absoluteString) == 0 })
    }

    func switchToLANPath(_ id: String) {
        guard let i = paired.firstIndex(where: { $0.id == id }),
              let session = sessions[id] else { return }
        let urls = paired[i].urlsInOrder.compactMap { URL(string: $0) }
        guard let lan = Self.preferredLANURL(from: urls) else { return }
        if session.client.serverURL == lan { return }   // already on LAN
        NSLog("[Quip][LAN] manual switch: backend=%@ to=%@", id, lan.host ?? "?")
        // `reconnect` stamps `lastSwapAt` — suppresses the auto-evaluator from
        // fighting the manual choice — using the same dance as the hot-swap.
        reconnect(session: session, entry: paired[i], preferring: lan)
    }

    /// Pure same-Mac duplicate collapse. Given all `rows`, a `canonicalID`
    /// (the row whose live session just identified — the post-rekey REAL
    /// device UUID), and `knownURLs` (the Mac's advertised `localURLs`), fold
    /// every OTHER row that is PROVABLY the same Mac into the canonical row and
    /// report the reaped ids. This breaks the dual-path flap deadlock: the
    /// surviving session collapses its disjoint-URL duplicate (LAN vs
    /// Tailscale) using the identity it already has, instead of waiting for
    /// the duplicate's socket to identify — which the Mac's same-deviceID
    /// dedup keeps killing first.
    ///
    /// SAFETY GATE (US-001): URL-string overlap alone is NOT evidence of
    /// sameness — two DIFFERENT Macs can advertise the same private-LAN IP
    /// literal (192.168.x.y), and folding on that reaps a *different* Mac's
    /// live row and deletes its Keychain PIN. A candidate is folded ONLY when
    /// it (a) overlaps the canonical's URL set AND (b) carries POSITIVE
    /// same-Mac evidence: the SAME real device UUID (`row.id == canonicalID`)
    /// OR the SAME non-empty monitor/display name. A nil/empty monitor name is
    /// not evidence, so an unidentified row is never merged into a stranger.
    /// Pure / value-in-value-out for unit testing.
    static func reapDuplicates(
        rows: [PairedBackend],
        canonicalID: String,
        knownURLs: [String]
    ) -> (rows: [PairedBackend], reaped: [String]) {
        guard let ci = rows.firstIndex(where: { $0.id == canonicalID }) else { return (rows, []) }
        let canonical = rows[ci]
        let known = Set(knownURLs).union(canonical.urlsInOrder)
        // Canonical Mac's monitor/display name, iff non-empty (nil = no evidence).
        let canonicalMonitor: String? = {
            guard let m = canonical.lastSeenLayoutMonitorName, !m.isEmpty else { return nil }
            return m
        }()
        var reaped: [String] = []
        var canonicalURLs = canonical.urlsInOrder
        // State-preserving fold (US-002): mirror the mergeRows/mergeSameIDRows
        // contract — enabled is a logical OR across the folded group, lastUsed
        // is the max — so consolidation never silently disables a backend or
        // loses its recency. Seed from the canonical, then fold each duplicate.
        var foldedEnabled = canonical.enabled
        var foldedLastUsed = canonical.lastUsed
        for (idx, row) in rows.enumerated() where idx != ci {
            // URL overlap identifies a *candidate* only — not proof of sameness.
            guard !Set(row.urlsInOrder).isDisjoint(with: known) else { continue }
            // Require POSITIVE same-Mac evidence before folding: exact device
            // UUID, or an equal non-empty monitor name.
            let sameDevice = (row.id == canonicalID)
            let sameMonitor: Bool
            if let cm = canonicalMonitor,
               let rm = row.lastSeenLayoutMonitorName, !rm.isEmpty {
                sameMonitor = (rm == cm)
            } else {
                sameMonitor = false
            }
            guard sameDevice || sameMonitor else { continue }
            reaped.append(row.id)
            foldedEnabled = foldedEnabled || row.enabled
            foldedLastUsed = max(foldedLastUsed, row.lastUsed)
            for u in row.urlsInOrder where !canonicalURLs.contains(u) { canonicalURLs.append(u) }
        }
        guard !reaped.isEmpty else { return (rows, []) }
        canonicalURLs = mergedURLOrder(canonicalURLs)
        var out: [PairedBackend] = []
        for (idx, r) in rows.enumerated() {
            if idx == ci {
                var row = r
                row.url = canonicalURLs.first ?? row.url
                row.fallbackURLs = Array(canonicalURLs.dropFirst())
                row.enabled = foldedEnabled
                row.lastUsed = foldedLastUsed
                out.append(row)
            } else if !reaped.contains(r.id) {
                out.append(r)
            }
        }
        return (out, reaped)
    }

    /// Apply `reapDuplicates` for a backend whose session just received a
    /// `device_identity`: fold same-Mac duplicate rows into `canonicalID` and
    /// tear down their now-orphaned sessions + Keychain PINs. No-op when there
    /// are no duplicates. Ends the LAN↔Tailscale dual-socket flap.
    private func reapDuplicateSameMac(canonicalID: String, knownLocalURLs: [String]) {
        let (newRows, reaped) = Self.reapDuplicates(
            rows: paired, canonicalID: canonicalID, knownURLs: knownLocalURLs)
        guard !reaped.isEmpty else { return }
        paired = newRows
        for id in reaped {
            sessions[id]?.client.disconnect()
            sessions.removeValue(forKey: id)
            KeychainBackendPINs.delete(backendID: id)
            if activeBackendID == id { activeBackendID = canonicalID }
        }
        NSLog("[Quip][LAN] reaped %d duplicate same-Mac row(s) into %@", reaped.count, canonicalID)
        savePaired()
    }

    /// The LAN URL the active/given backend could switch to, or nil when none
    /// is known. Used by the picker to decide whether to show the switch tile.
    func lanURL(for id: String) -> URL? {
        guard let backend = paired.first(where: { $0.id == id }) else { return nil }
        return backend.urlsInOrder.compactMap { URL(string: $0) }.first(where: { Self.isLANURL($0) })
    }

    /// True when the given backend's live socket is currently on a LAN URL —
    /// in which case the "Use Local Network" tile is hidden (already there).
    func isOnLANPath(_ id: String) -> Bool {
        guard let url = sessions[id]?.client.serverURL else { return false }
        return Self.isLANURL(url)
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
            let wasConnected = session.reachability == .connected
            if !wasConnected { session.reachability = .connected }
            // §J — stamp the paired-backend's lastConnectedAt on the
            // first layout_update of a connection (i.e. the moment the
            // session newly enters .connected). Throttled to once per
            // connection cycle so the picker sees stable timestamps and
            // we don't write UserDefaults every layout tick.
            if !wasConnected, let i = self.paired.firstIndex(where: { $0.id == session.backendID }) {
                self.paired[i].lastConnectedAt = Date()
                self.savePaired()
            }
            if let i = self.paired.firstIndex(where: { $0.id == session.backendID }) {
                // Diff guard — only persist when the monitor name actually
                // changed. Without this every layout_update (multiple per
                // second during normal use) writes UserDefaults, which
                // triggers `PreferencesSyncService`'s didChange observer,
                // schedules a 0.5s-debounced snapshot upload, and feeds the
                // Mac a 1369-byte preferences_snapshot frame at 1-3s
                // cadence forever. Trigger source for the kokoro.log
                // "preferences_snapshot" storm (~300:1 vs audio_chunk).
                if self.paired[i].lastSeenLayoutMonitorName != update.monitor {
                    self.paired[i].lastSeenLayoutMonitorName = update.monitor
                    self.savePaired()
                }
            }
            self.onLayoutUpdate?(session, update)
        }

        c.onSwrmStoryStarted = { [weak self, weak session] msg in
            guard let self, let session else { return }
            self.onSwrmStoryStarted?(session, msg)
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

        c.onTerminalContent = { [weak self, weak session] windowId, content, screenshot, urls, hasAutosuggest in
            guard let self, let session else { return }
            session.terminalContentWindowId = windowId
            session.terminalContentText = content
            if let screenshot, !screenshot.isEmpty {
                session.terminalContentScreenshot = screenshot
            }
            if let urls {
                session.terminalContentURLs = urls
            }
            self.onTerminalContent?(session, windowId, content, screenshot, urls, hasAutosuggest)
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

        c.onFrontmostChanged = { [weak self, weak session] windowId in
            guard let self, let session else { return }
            self.onFrontmostChanged?(session, windowId)
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
                // Re-announce our currently-selected window so the Mac's
                // `clientSelectedWindowId` lines up with what the phone is
                // actually showing. After a Mac restart (or any phone
                // reconnect post-NAT-idle drop) the Mac side resets to
                // nil; without this re-send, every state-change push
                // skipped via `selection_mismatch` until the user
                // manually tapped a different window. push.log shows it
                // as a long stream of `clientSelectedWindowId=nil,
                // selection_mismatch` entries.
                if let wid = session.selectedWindowId,
                   session.windows.contains(where: { $0.id == wid }) {
                    session.client.send(SelectWindowMessage(windowId: wid))
                }
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

            // Learn the Mac's LAN URL(s) from its identity so a "Use Local
            // Network" switch is possible even when this phone only ever
            // paired over Tailscale. Done BEFORE the rekey/merge branches so
            // the new fallback URLs ride along when the row is rekeyed or
            // folded into an existing same-Mac row. Keyed on the session's
            // current id (synthetic pre-rekey, real post-rekey) — whichever
            // row this path owns right now.
            if let localURLs = identity.localURLs, !localURLs.isEmpty {
                self.ingestLocalURLs(localURLs, into: session.backendID)
            }

            // Break the dual-path flap: fold any stuck same-Mac duplicate row
            // (a LAN-only duplicate racing the Tailscale primary, whose socket
            // the Mac's same-deviceID dedup keeps resetting before it can
            // identify) into the canonical row. The reap is invoked below,
            // keyed on the Mac's REAL device UUID (`identity.deviceID`), ONLY
            // from the branches AFTER rekey/merge — never on the pre-rekey
            // synthetic `session.backendID`, which folded the WRONG direction
            // and tore down the live authenticated row, deleting its PIN.
            // reapDuplicates also requires positive same-Mac evidence, so two
            // different Macs sharing a LAN IP literal are never collapsed.
            // See project_dual_path_reap_deadlock.

            // Replay persisted QA pair on every identity ack — covers
            // reconnects (the closure also fires on the equal-IDs path
            // below). Mac validates the pair; if either id is stale it
            // responds qa_pair_lost and the bridge clears local state.
            if let pair = session.qaPair {
                c.setQAPair(targetId: pair.targetId, terminalId: pair.terminalId)
            }

            // Rekey the synthetic legacy id to the daemon's real UUID.
            let oldID = session.backendID
            if oldID == identity.deviceID {
                // Defensive dedup: if another live session already owns this
                // deviceID, THIS closure's session is a duplicate path to the
                // same Mac (a bootstrap orphan, or a route that authenticated
                // after this id was already rekeyed). Two live clients to one
                // Mac are the dual-socket "flap" — tear this duplicate down so
                // a single connection survives. The canonical session in
                // `sessions` keeps its connection, PIN, and paired row.
                if let canonical = self.sessions[oldID], canonical !== session {
                    c.disconnect()
                }
                // Steady-state reconnect on the already-real-UUID canonical:
                // fold any duplicate whose own socket never got to identify.
                self.reapDuplicateSameMac(canonicalID: identity.deviceID,
                                          knownLocalURLs: identity.localURLs ?? [])
                return
            }

            // Same-Mac consolidation. If another backend row already holds
            // this deviceID, THIS session is a second path to the same Mac
            // (e.g. Tailscale arriving after LAN). Merge this path's URL into
            // the existing backend and tear THIS duplicate down — never
            // overwrite the existing session, which orphaned a still-live
            // client and produced the dual-socket "flap". The keeper holds
            // its live connection; the merged (Tailscale-first) URL list is
            // used on its next reconnect.
            if let keepIdx = self.paired.firstIndex(where: { $0.id == identity.deviceID }),
               let dupIdx = self.paired.firstIndex(where: { $0.id == oldID }) {
                var allURLs = self.paired[keepIdx].urlsInOrder
                for u in self.paired[dupIdx].urlsInOrder where !allURLs.contains(u) { allURLs.append(u) }
                allURLs = Self.mergedURLOrder(allURLs)
                self.paired[keepIdx].enabled = self.paired[keepIdx].enabled || self.paired[dupIdx].enabled
                self.paired[keepIdx].url = allURLs.first ?? self.paired[keepIdx].url
                self.paired[keepIdx].fallbackURLs = Array(allURLs.dropFirst())
                self.paired[keepIdx].lastUsed = Date()
                self.paired.remove(at: dupIdx)
                c.disconnect()
                self.sessions.removeValue(forKey: oldID)
                KeychainBackendPINs.delete(backendID: oldID)
                if self.activeBackendID == oldID { self.activeBackendID = identity.deviceID }
                self.savePaired()
                // The keeper (id == deviceID) is now canonical — fold any other
                // stuck same-Mac rows into it.
                self.reapDuplicateSameMac(canonicalID: identity.deviceID,
                                          knownLocalURLs: identity.localURLs ?? [])
                return
            }

            // Rekey: rename this session's row from the synthetic legacy id
            // to the daemon's real UUID (first/only path to this Mac).
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
            rebuilt.updateQAPair(session.qaPair)
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
            // This session just became the real-UUID canonical — fold any
            // stuck same-Mac duplicate rows into it.
            self.reapDuplicateSameMac(canonicalID: identity.deviceID,
                                      knownLocalURLs: identity.localURLs ?? [])
        }

        c.onPreferencesRestore = { [weak self, weak session] snap in
            guard let self, let session else { return }
            self.onPreferencesRestore?(session, snap)
        }

        c.onQAPairLost = { [weak self, weak session] missingId, reason in
            guard let self, let session else { return }
            // Capture pair IDs before clearing so the host can purge content maps.
            let lostPair = session.qaPair
            // Drop pair locally + notify host so the toast can fire.
            session.updateQAPair(nil)
            self.onQAPairLost?(session, lostPair, missingId, reason)
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
