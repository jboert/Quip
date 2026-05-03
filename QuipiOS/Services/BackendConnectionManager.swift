import Foundation

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
        if let i = paired.firstIndex(where: { $0.url == url }) {
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
    func recordDeviceIdentity(_ identity: DeviceIdentityMessage) {
        guard let i = paired.firstIndex(where: { $0.id == activeBackendID }) else { return }
        let oldID = activeBackendID
        if oldID != identity.deviceID {
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
    /// auto-connect for any whose PIN is in Keychain. Run once on launch from
    /// `MainiOSView.setup()` after `loadPaired()`.
    func bootstrap() {
        for backend in paired {
            let session = BackendSession(backendID: backend.id, client: WebSocketClient())
            wire(session: session)
            sessions[backend.id] = session
            if let url = URL(string: backend.url) {
                connect(session: session, url: url)
            }
        }
        if activeBackendID.isEmpty, let first = paired.first {
            activeBackendID = first.id
        }
    }

    /// Pair a new backend — caller is responsible for prompting for a PIN and
    /// passing it in. Writes PIN to Keychain, appends to `paired`, opens a
    /// connection. The synthetic `backend.id` is rekeyed once the daemon's
    /// `device_identity` arrives (see `wire(session:)` below).
    func add(_ backend: PairedBackend, pin: String) {
        guard paired.count < Self.maxPairedBackends else { return }
        guard !paired.contains(where: { $0.id == backend.id }) else { return }

        KeychainBackendPINs.write(backendID: backend.id, pin: pin)
        paired.append(backend)
        let session = BackendSession(backendID: backend.id, client: WebSocketClient())
        wire(session: session)
        sessions[backend.id] = session
        if activeBackendID.isEmpty {
            activeBackendID = backend.id
        }
        if let url = URL(string: backend.url) {
            connect(session: session, url: url)
        }
        savePaired()
    }

    /// Hot-model switch: pure UI flip. Every paired backend already has a
    /// live `WebSocketClient` thanks to `bootstrap()` / `ensureImplicitDefault`,
    /// so swapping `activeBackendID` is what makes the new backend the one
    /// the UI displays. Returns true if the switch was issued.
    @discardableResult
    func setActive(_ id: String) -> Bool {
        guard activeBackendID != id,
              sessions[id] != nil else { return false }
        activeBackendID = id
        if let i = paired.firstIndex(where: { $0.id == id }) {
            paired[i].lastUsed = Date()
            savePaired()
        }
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
        if let existing = paired.first(where: { $0.url == url }) { return existing.id }
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
        sessions.removeValue(forKey: id)
        KeychainBackendPINs.delete(backendID: id)
        paired.removeAll { $0.id == id }
        if activeBackendID == id {
            if let next = paired.first {
                activeBackendID = next.id
                if let url = URL(string: next.url) {
                    primeActivePIN()
                    active.client.connect(to: url)
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
              let entry = paired.first(where: { $0.id == id }),
              let url = URL(string: entry.url) else { return }
        KeychainBackendPINs.write(backendID: id, pin: pin)
        session.client.disconnect()
        session.reachability = .connecting
        connect(session: session, url: url)
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
        let raw = UserDefaults.standard.data(forKey: "pairedBackendsData") ?? Data()
        if let decoded = try? JSONDecoder().decode([PairedBackend].self, from: raw), !decoded.isEmpty {
            paired = decoded
            activeBackendID = UserDefaults.standard.string(forKey: "activeBackendID") ?? decoded.first?.id ?? ""
            return
        }
        // Migrate from the legacy single-backend layout: `lastURL` holds one
        // URL string. Synthesize a single PairedBackend with a `legacy-` id;
        // the manager will rekey it once the daemon's `device_identity`
        // arrives. The PIN is NOT migrated — old code only kept it
        // session-scoped, so the user re-enters it once.
        let legacyURL = UserDefaults.standard.string(forKey: "lastURL") ?? ""
        if !legacyURL.isEmpty {
            let id = "legacy-\(UUID().uuidString)"
            paired = [PairedBackend(id: id, url: legacyURL, name: "Backend")]
            activeBackendID = id
            savePaired()
        }
    }

    private func savePaired() {
        if let data = try? JSONEncoder().encode(paired) {
            UserDefaults.standard.set(data, forKey: "pairedBackendsData")
        }
        UserDefaults.standard.set(activeBackendID, forKey: "activeBackendID")
    }

    // MARK: - Internals

    private func connect(session: BackendSession, url: URL) {
        session.reachability = .connecting
        // Pre-populate the cached PIN so the client auto-replays it on
        // `auth_required` without prompting. If Keychain is empty, the client
        // calls `onAuthRequired` below and we surface `.needsAuth` in the UI.
        if let pin = KeychainBackendPINs.read(backendID: session.backendID) {
            session.client.sendAuth(pin: pin)  // sets sessionPIN; safe pre-connect
        }
        session.client.connect(to: url)
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
    }
}
