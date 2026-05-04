// WebSocketClient.swift
// QuipiOS — URLSessionWebSocketTask client for Mac communication
// Connects to Mac via Cloudflare tunnel (wss://) or local (ws://)

import Foundation
import Observation
import Security
import CommonCrypto
import UIKit
import Network

// MARK: - Certificate Pinning for Cloudflare Tunnel

/// Pins Cloudflare's certificate chain for wss://*.trycloudflare.com connections.
/// Local ws:// connections bypass pinning entirely.
///
/// Pin set is loaded from a manifest at runtime so a Cloudflare CA rotation
/// doesn't require an app update — the resolution order is:
///
///   1. `~/Documents/quip-cert-pins.json` in the app's Documents container
///      (user/MDM override; lets a sysadmin patch pins without rebuilding).
///   2. `CertPins.json` in the app bundle (the canonical default; ships with
///      the app — edit `QuipiOS/Resources/CertPins.json` to update).
///   3. Hardcoded fallback baked into source so unit tests with no bundle
///      and no Documents file still pin against a known set.
///
/// Manifest shape (both override and bundled):
///   { "spkiHashes": ["base64...", "base64..."] }
///
/// To produce new SPKI hashes when Cloudflare rotates: see
/// `docs/protocol.md` → "Certificate Pinning (Cloudflare Tunnel)" for the
/// openssl recipe.
final class CloudflareCertificatePinningDelegate: NSObject, URLSessionDelegate {

    /// Manifest JSON shape. Extra fields in the file (commentary, chain
    /// notes) are ignored, so the JSON can carry inline documentation
    /// without breaking decoding.
    private struct PinManifest: Decodable {
        let spkiHashes: [String]
    }

    /// Lazily-resolved pin set. Computed (not `let`) so a user can drop a
    /// new override file at runtime and the next connection picks it up
    /// without restarting the app.
    static var pinnedSPKIHashes: Set<String> {
        if let override = loadFromDocuments(), !override.isEmpty {
            return override
        }
        if let bundled = loadFromBundle(), !bundled.isEmpty {
            return bundled
        }
        return Self.hardcodedFallback
    }

    /// Hardcoded SPKI hashes used when no manifest is loadable. Mirrors the
    /// bundled `CertPins.json` so test targets without the resource still
    /// pin to the same chain — keep the two in sync if you rotate.
    ///
    /// Current chain (as of 2026-04):
    ///   Leaf:         CN=trycloudflare.com       (issued by WE1) — NOT pinned
    ///   Intermediate: CN=WE1                     (Google Trust Services)
    ///   Root:         CN=GTS Root R4             (cross-signed by GlobalSign)
    private static let hardcodedFallback: Set<String> = [
        "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=",
    ]

    /// Override path inside the app's Documents container. iOS sandboxes mean
    /// only the user (via Files.app or sharing) or an MDM profile can drop
    /// a file here, so the trust boundary matches the existing app data.
    private static var documentsOverrideURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("quip-cert-pins.json")
    }

    private static func loadFromDocuments() -> Set<String>? {
        guard let url = documentsOverrideURL,
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PinManifest.self, from: data) else {
            return nil
        }
        NSLog("[CertPin] Using Documents override (%d pin(s))", manifest.spkiHashes.count)
        return Set(manifest.spkiHashes)
    }

    private static func loadFromBundle() -> Set<String>? {
        guard let url = Bundle.main.url(forResource: "CertPins", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PinManifest.self, from: data) else {
            return nil
        }
        return Set(manifest.spkiHashes)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Only pin for trycloudflare.com — local LAN connections use default handling
        guard host.hasSuffix("trycloudflare.com") else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the trust chain first
        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            NSLog("[CertPin] Trust evaluation failed for %@: %@", host, error?.localizedDescription ?? "unknown")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Check if any certificate in the chain matches a pinned SPKI hash
        let chainLength = SecTrustGetCertificateCount(serverTrust)
        guard let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            NSLog("[CertPin] Could not copy certificate chain for %@", host)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        for i in 0..<chainLength {
            let cert = certChain[i]
            let spkiHash = Self.sha256SPKIHash(for: cert)
            if Self.pinnedSPKIHashes.contains(spkiHash) {
                NSLog("[CertPin] Pin matched at chain position %d for %@", i, host)
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        NSLog("[CertPin] No pinned certificate matched for %@ (chain length: %d)", host, chainLength)
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    /// Compute Base64(SHA-256(SubjectPublicKeyInfo DER)) for a certificate.
    private static func sha256SPKIHash(for certificate: SecCertificate) -> String {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return "" }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return "" }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = publicKeyData.withUnsafeBytes { bytes in
            CC_SHA256(bytes.baseAddress, CC_LONG(publicKeyData.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}

@Observable
@MainActor
final class WebSocketClient {

    var isConnected = false
    var isConnecting = false
    var isAuthenticated = false
    var authError: String?
    var serverURL: URL?
    var lastError: String?

    var onLayoutUpdate: ((LayoutUpdate) -> Void)?
    var onStateChange: ((String, String) -> Void)?
    var onTerminalContent: ((String, String, String?, [String]?) -> Void)?  // (windowId, content, screenshot, urls)
    var onOutputDelta: ((String, String, String, Bool) -> Void)?  // (windowId, windowName, text, isFinal)
    // (windowId, windowName, sessionId, sequence, isFinal, wavData)
    var onTTSAudio: ((String, String, String, Int, Bool, Data) -> Void)?
    /// Mac asks the phone to switch its selected window — fired when the Mac just
    /// spawned a new window (e.g. duplicate) and wants the phone to follow along.
    var onSelectWindow: ((String) -> Void)?
    var onProjectDirectories: (([String]) -> Void)?
    /// Mac responded to a `scan_iterm_windows` request with the full list of
    /// iTerm2 windows it can see. The iOS scan sheet listens for this.
    var onITermWindowList: (([ITermWindowInfo]) -> Void)?
    var onError: ((String) -> Void)?
    var onAuthRequired: (() -> Void)?
    var onAuthResult: ((Bool, String?) -> Void)?
    /// Backend identifies itself with a stable UUID right after auth_ok.
    /// `BackendConnectionManager` uses this to key per-backend state.
    var onDeviceIdentity: ((DeviceIdentityMessage) -> Void)?
    /// Mac is sending back a preferences snapshot the phone previously
    /// uploaded — used to repopulate UserDefaults after a reinstall.
    var onPreferencesRestore: ((PreferencesSnapshot) -> Void)?
    /// Mac sent its current TCC permission status. Phone surfaces it in the
    /// settings sheet + as a badge on the main screen when anything is denied.
    var onMacPermissions: ((MacPermissionsMessage) -> Void)?
    /// Mac confirms an image upload; argument is the absolute path the Mac wrote.
    var onImageUploadAck: ((String) -> Void)?
    /// Mac rejects an image upload; argument is a human-readable reason.
    var onImageUploadError: ((String) -> Void)?
    /// Latest Whisper model lifecycle state from the Mac. Starts as .preparing
    /// until the Mac broadcasts its status. SpeechService reads this at PTT-start
    /// to decide between remote (Whisper) and local (SFSpeech) paths.
    var whisperStatus: WhisperState = .preparing
    /// Mac returned the final transcript for a session.
    var onTranscriptResult: ((UUID, String, String?) -> Void)?
    /// Mac returned a diagnostics bundle (zip of the three logs + system
    /// info). Wired by ConnectionDiagnosticsSheet to drop the zip in
    /// Documents and open a UIActivityViewController.
    var onDiagnosticsBundle: ((DiagnosticsBundleMessage) -> Void)?
    /// Mac sent the latest prompt-library catalog (wishlist §57).
    /// Phone caches into `promptLibrary` so the Prompts sheet can render
    /// without a fresh fetch.
    var onPromptLibrary: (([PromptEntry]) -> Void)?
    /// Cached catalog from the Mac — published so SwiftUI views can
    /// observe directly (avoids piping through host state).
    var promptLibrary: [PromptEntry] = []

    /// Cached PIN for the current session — used for auto-auth on reconnect
    private(set) var sessionPIN: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pinningDelegate: CloudflareCertificatePinningDelegate?
    private var intentionalDisconnect = false
    /// Full URL list for the current pairing — primary at index 0,
    /// fallbacks after. Used by the auto-fallback flow: on connect
    /// failure or auth-timeout, the client advances to the next URL
    /// in this list and re-establishes. Reset to index 0 on every
    /// fresh connect call and on NWPathMonitor path-change.
    private var connectURLs: [URL] = []
    private var currentURLIndex: Int = 0
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var foregroundProbeTask: Task<Void, Never>?

    /// Watches for OS-level network path changes (WiFi roam, VPN flap, cellular
    /// regained). When path becomes satisfied while we're disconnected,
    /// short-circuit the exponential backoff and reconnect immediately.
    private var pathMonitor: NWPathMonitor?
    /// Periodic watchdog that catches the rare case where `isConnecting` flips
    /// true but never resolves — neither becomes connected nor errors out.
    /// Force-restarts the connection after the stall threshold.
    private var stuckWatchdogTask: Task<Void, Never>?
    private var connectingStartedAt: Date?

    /// Stall threshold for the watchdog — once `isConnecting` has been true
    /// this long without progress, the watchdog rips the socket down and
    /// re-runs `establishConnection` so the user isn't stuck on "Connecting…".
    private static let stuckThresholdSec: TimeInterval = 25

    /// Diagnostic ring buffer — last 30 connection events with timestamps.
    /// Surfaced via `recentConnectionEvents` for the in-app diag panel.
    private var connectionEvents: [String] = []
    var recentConnectionEvents: [String] { connectionEvents }

    init() {
        startPathMonitor()
        startStuckWatchdog()
    }

    /// Stops the path monitor + stall watchdog. Call from `forget(_:)` so a
    /// pruned backend's client doesn't leak its background subscribers. The
    /// `[weak self]` captures inside the handlers already make stale fires
    /// harmless, but cancelling is tidier.
    func teardownDiagnostics() {
        pathMonitor?.cancel()
        pathMonitor = nil
        stuckWatchdogTask?.cancel()
        stuckWatchdogTask = nil
    }

    /// Subscribes to network path changes. When the path becomes satisfied and
    /// we're not already connected, reset the backoff and kick a connection
    /// attempt right away. Catches the "phone gave up retrying after a network
    /// blip" failure mode that leaves the UI stuck on "Connecting…".
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                if path.status == .satisfied {
                    self.logEvent("network path satisfied")
                    if !self.isConnected,
                       !self.intentionalDisconnect,
                       self.serverURL != nil {
                        self.logEvent("path-driven reconnect kick")
                        self.reconnectDelay = 1.0
                        self.reconnectTask?.cancel()
                        self.reconnectTask = nil
                        self.establishConnection()
                    }
                } else {
                    self.logEvent("network path unsatisfied (\(path.status))")
                }
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    /// Periodically checks whether we've been stalled mid-connect. If
    /// `isConnecting` has been true for more than `stuckThresholdSec` without
    /// flipping to connected (and we're not intentionally disconnected),
    /// rip the socket down and start over. Belt-and-suspenders against
    /// URLSession's occasional zombie state where the ping callback never
    /// fires and the connection-timeout task somehow never trips either.
    private func startStuckWatchdog() {
        stuckWatchdogTask?.cancel()
        stuckWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.isConnecting,
                   !self.intentionalDisconnect,
                   let started = self.connectingStartedAt,
                   Date().timeIntervalSince(started) > Self.stuckThresholdSec {
                    let secs = Int(Date().timeIntervalSince(started))
                    self.logEvent("stall watchdog tripped after \(secs)s — forcing reconnect")
                    self.lastError = "Stalled \(secs)s — resetting"
                    self.connectingStartedAt = Date()  // start clock for next attempt
                    self.handleDisconnect()
                }
            }
        }
    }

    /// Append a timestamped line to the diagnostic ring buffer (cap 30) and
    /// echo to NSLog. Cheap; called from connection lifecycle transitions so
    /// the in-app diag panel can show what actually happened without the user
    /// having to plug in a Mac and tail device logs.
    private func logEvent(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)"
        connectionEvents.append(line)
        if connectionEvents.count > 30 { connectionEvents.removeFirst(connectionEvents.count - 30) }
        NSLog("[WebSocketClient] %@", msg)
    }

    func connect(to url: URL) {
        connect(toURLs: [url])
    }

    /// Multi-URL connect with auto-fallback. Tries `urls[0]` first; if the
    /// initial WS handshake fails OR no auth_result lands within
    /// `authTimeoutSeconds`, advances to `urls[1]` and so on. Used by the
    /// LAN/Tailscale fallback flow — `BackendConnectionManager` passes the
    /// merged paired-backend URL list (LAN first, Tailscale fallback).
    /// Single-URL callers route here via `connect(to:)`.
    func connect(toURLs urls: [URL]) {
        guard let first = urls.first else { return }
        intentionalDisconnect = false
        connectURLs = urls
        currentURLIndex = 0
        hasEverConnectedOnCurrentURL = false
        serverURL = first
        reconnectDelay = 1.0
        lastError = nil
        isConnecting = true
        connectingStartedAt = Date()
        logEvent("connect(toURLs: \(urls.count) total, primary: \(first.absoluteString))")
        establishConnection()
    }

    /// Reset the URL pointer so the next reconnect starts from the
    /// primary again. Called by `BackendConnectionManager` on
    /// `NWPathMonitor` path-change — after a Wi-Fi join/leave the LAN
    /// URL may have become reachable again and we want to prefer it.
    func resetToPrimaryURL() {
        guard !connectURLs.isEmpty, currentURLIndex != 0 else { return }
        currentURLIndex = 0
        if let first = connectURLs.first { serverURL = first }
        logEvent("resetToPrimaryURL: rewound to index 0")
    }

    /// Advance to the next URL in `connectURLs`. Returns true if there
    /// was a next URL to advance to (caller should retry connect),
    /// false if we exhausted the list (caller falls back to standard
    /// reconnect-with-backoff on the current URL).
    @discardableResult
    private func advanceToNextURL() -> Bool {
        let nextIndex = currentURLIndex + 1
        guard nextIndex < connectURLs.count else { return false }
        currentURLIndex = nextIndex
        hasEverConnectedOnCurrentURL = false
        serverURL = connectURLs[nextIndex]
        logEvent("advanceToNextURL: trying [\(nextIndex)] \(connectURLs[nextIndex].absoluteString)")
        return true
    }

    func disconnect() {
        intentionalDisconnect = true
        keepaliveTask?.cancel()
        keepaliveTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        pinningDelegate = nil
        isConnected = false
        isConnecting = false
        isAuthenticated = false
        authError = nil
        sessionPIN = nil
        NSLog("[WebSocketClient] Disconnected intentionally")
    }

    /// Called when the app resigns active (user swipes away, switches apps, etc).
    /// Starts a background task so iOS gives the socket ~30s of grace before suspending
    /// network I/O — enough to cover most quick app switches without dropping the
    /// connection at all.
    func suspendForBackground() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "QuipWebSocket") { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundTask() }
        }
    }

    /// Called when the app returns to active. Ends the background task, probes the
    /// socket with a short-timeout ping, and force-reconnects (with backoff reset to 1s)
    /// if the probe doesn't come back fast. Prevents the 2–10s "stuck reconnecting"
    /// UI after a quick app switch.
    func resumeFromBackground() {
        endBackgroundTask()
        foregroundProbeTask?.cancel()

        // If we were already mid-reconnect, shortcut the exponential delay so the
        // user doesn't wait out a 2–10s sleep after foregrounding.
        if !isConnected && !intentionalDisconnect {
            reconnectDelay = 1.0
            reconnectTask?.cancel()
            reconnectTask = nil
            establishConnection()
            return
        }

        guard let task = webSocketTask else { return }

        foregroundProbeTask = Task { [weak self] in
            let pongReceived = await Self.probeSocket(task: task, timeoutNanos: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !pongReceived {
                NSLog("[WebSocketClient] Foreground probe failed — forcing reconnect")
                self.reconnectDelay = 1.0
                self.handleDisconnect()
            }
        }
    }

    /// Send a WebSocket ping and wait up to `timeoutNanos` for a response.
    /// Returns true if the pong came back in time, false otherwise.
    private nonisolated static func probeSocket(task: URLSessionWebSocketTask, timeoutNanos: UInt64) async -> Bool {
        let result = ProbeResult()
        task.sendPing { error in
            Task { await result.set(error == nil) }
        }
        try? await Task.sleep(nanoseconds: timeoutNanos)
        return await result.get() ?? false
    }

    private actor ProbeResult {
        private var value: Bool?
        func set(_ v: Bool) { if value == nil { value = v } }
        func get() -> Bool? { value }
    }

    private func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }

    func sendAuth(pin: String) {
        sessionPIN = pin
        authError = nil
        send(AuthMessage(pin: pin))
        NSLog("[WebSocketClient] Sent auth message")
    }

    func send(_ message: some Codable) {
        guard let task = webSocketTask else { return }
        do {
            let data = try JSONEncoder().encode(message)
            let string = String(data: data, encoding: .utf8) ?? ""
            task.send(.string(string)) { error in
                if let error = error {
                    NSLog("[WebSocketClient] Send error: %@", error.localizedDescription)
                }
            }
        } catch {
            NSLog("[WebSocketClient] Encode error: %@", error.localizedDescription)
        }
    }

    /// Send pre-encoded JSON. Used by services that already have a Data
    /// blob and don't need a second encode pass.
    func sendRaw(_ data: Data) {
        guard let task = webSocketTask else { return }
        let string = String(data: data, encoding: .utf8) ?? ""
        task.send(.string(string)) { error in
            if let error = error {
                NSLog("[WebSocketClient] sendRaw error: %@", error.localizedDescription)
            }
        }
    }

    /// Serialize and send an audio chunk. Safe to call from any thread;
    /// uses the same URLSessionWebSocketTask.send path as other outbound messages.
    func sendAudioChunk(_ msg: AudioChunkMessage) {
        guard let data = MessageCoder.encode(msg),
              let task = webSocketTask else { return }
        task.send(.data(data)) { err in
            if let err {
                NSLog("[WebSocketClient] audio chunk send failed: %@", err.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private func establishConnection() {
        guard let url = serverURL else { return }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        connectionTimeoutTask?.cancel()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10

        // Certificate pinning disabled by default. Pin set lives in
        // QuipiOS/Resources/CertPins.json (verify it matches Cloudflare's
        // current chain via docs/protocol.md → "Updating Pins" before
        // flipping this on). Users can additionally drop their own
        // override at ~/Documents/quip-cert-pins.json — see
        // CloudflareCertificatePinningDelegate for the resolution order.
        // To enable, replace this line with:
        //   pinningDelegate = CloudflareCertificatePinningDelegate()
        pinningDelegate = nil
        let urlSession = URLSession(configuration: config)
        session = urlSession

        let task = urlSession.webSocketTask(with: url)
        // Allow large messages for base64-encoded image uploads and TTS audio
        // payloads (URLSession default is 1 MB). See Shared/Constants.swift.
        task.maximumMessageSize = WSLimits.maxMessageBytes
        webSocketTask = task
        task.resume()

        NSLog("[WebSocketClient] Connecting to %@", url.absoluteString)

        // Connection timeout — if ping doesn't respond within 8 seconds, give up
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.isConnected && self.isConnecting {
                NSLog("[WebSocketClient] Connection timeout")
                self.lastError = "Connection timed out"
                self.handleDisconnect()
            }
        }

        // Start receive loop
        receiveNext()

        // Check connection by sending a ping
        task.sendPing { [weak self] error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.connectionTimeoutTask?.cancel()
                self.connectionTimeoutTask = nil

                if let error = error {
                    self.logEvent("initial ping failed: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                    self.handleDisconnect()
                } else {
                    self.logEvent("connected, awaiting authentication")
                    self.isConnected = true
                    self.isConnecting = false
                    self.connectingStartedAt = nil
                    self.authError = nil
                    self.lastError = nil
                    self.reconnectDelay = 1.0
                    self.hasEverConnectedOnCurrentURL = true
                    self.startKeepalive()
                    // Don't send auth eagerly — wait for the server's first
                    // auth_result message which carries the auth_required
                    // signal. On a Mac with `requireAuth=false` the server
                    // immediately replies success=true, and a stray PIN we
                    // sent here would land at handleAuthMessage where the
                    // missing pinManager.pin produces "Server PIN not
                    // configured" → flips isAuthenticated back to false →
                    // phone gets stuck in "Authenticating…". The cached
                    // sessionPIN now waits in the auth_result handler and
                    // only fires when we actually see the auth_required
                    // signal.
                }
            }
        }
    }

    private func receiveNext() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let d):
                    data = d
                @unknown default:
                    data = Data()
                }

                if !data.isEmpty {
                    DispatchQueue.main.async {
                        // Mark connected on first successful message if ping hasn't fired yet
                        if !self.isConnected {
                            self.isConnected = true
                            self.isConnecting = false
                            self.authError = nil
                            self.connectionTimeoutTask?.cancel()
                            self.connectionTimeoutTask = nil
                            self.lastError = nil
                            self.reconnectDelay = 1.0
                            // Prompt for PIN unless server already auto-authenticated us
                            // (handleMessage below will process auth_result first)
                        }
                        self.handleMessage(data)
                    }
                }

                // Continue receiving
                self.receiveNext()

            case .failure(let error):
                NSLog("[WebSocketClient] Receive error: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ data: Data) {
        let decoder = JSONDecoder()
        struct TypePeek: Codable { let type: String }
        guard let peek = try? decoder.decode(TypePeek.self, from: data) else {
            NSLog("[WebSocketClient] Could not peek type from %d bytes", data.count)
            return
        }

        switch peek.type {
        case "auth_result":
            if let msg = try? decoder.decode(AuthResultMessage.self, from: data) {
                print("[Quip] auth_result: success=\(msg.success) error=\(msg.error ?? "none") url=\(serverURL?.absoluteString ?? "?")")
                NSLog("[WebSocketClient] auth_result: success=%d error=%@", msg.success ? 1 : 0, msg.error ?? "none")
                // "auth_required" is the server's connection-ready signal —
                // server wants a PIN. Send the cached one if we have it,
                // else surface the prompt to the UI.
                if msg.error == "auth_required" {
                    if let pin = sessionPIN {
                        sendAuth(pin: pin)
                    } else {
                        onAuthRequired?()
                    }
                    return
                }
                if msg.success {
                    isAuthenticated = true
                    authError = nil
                    print("[Quip] isAuthenticated=true")
                } else {
                    isAuthenticated = false
                    authError = msg.error ?? "Invalid PIN"
                    sessionPIN = nil  // Clear bad PIN
                }
                onAuthResult?(msg.success, msg.error)
            }
        case "device_identity":
            if let msg = try? decoder.decode(DeviceIdentityMessage.self, from: data) {
                onDeviceIdentity?(msg)
            }
        case "layout_update":
            guard isAuthenticated else { return }
            do {
                let update = try decoder.decode(LayoutUpdate.self, from: data)
                NSLog("[WebSocketClient] layout_update: %d windows", update.windows.count)
                onLayoutUpdate?(update)
            } catch {
                NSLog("[WebSocketClient] decode error: %@", "\(error)")
            }
        case "state_change":
            guard isAuthenticated else { return }
            struct SC: Codable { let windowId: String; let state: String }
            if let c = try? decoder.decode(SC.self, from: data) {
                onStateChange?(c.windowId, c.state)
            }
        case "terminal_content":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(TerminalContentMessage.self, from: data) {
                onTerminalContent?(msg.windowId, msg.content, msg.screenshot, msg.urls)
            }
        case "output_delta":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(OutputDeltaMessage.self, from: data) {
                onOutputDelta?(msg.windowId, msg.windowName, msg.text, msg.isFinal)
            }
        case "tts_audio":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(TTSAudioMessage.self, from: data) {
                // Empty audioBase64 can happen on the final marker message
                let wavData = Data(base64Encoded: msg.audioBase64) ?? Data()
                onTTSAudio?(msg.windowId, msg.windowName, msg.sessionId, msg.sequence, msg.isFinal, wavData)
            }
        case "select_window":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(SelectWindowMessage.self, from: data) {
                onSelectWindow?(msg.windowId)
            }
        case "preferences_restore":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(PreferenceRestoreMessage.self, from: data) {
                onPreferencesRestore?(msg.preferences)
            }
        case "project_directories":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(ProjectDirectoriesMessage.self, from: data) {
                NSLog("[WebSocketClient] Received %d project directories", msg.directories.count)
                onProjectDirectories?(msg.directories)
            }
        case "iterm_window_list":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(ITermWindowListMessage.self, from: data) {
                NSLog("[WebSocketClient] iterm_window_list: %d windows", msg.windows.count)
                onITermWindowList?(msg.windows)
            }
        case "error":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(ErrorMessage.self, from: data) {
                onError?(msg.reason)
            }
        case "image_upload_ack":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(ImageUploadAckMessage.self, from: data) {
                onImageUploadAck?(msg.savedPath)
            }
        case "image_upload_error":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(ImageUploadErrorMessage.self, from: data) {
                onImageUploadError?(msg.reason)
            }
        case "mac_permissions":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(MacPermissionsMessage.self, from: data) {
                onMacPermissions?(msg)
            }
        case "transcript_result":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(TranscriptResultMessage.self, from: data) {
                NSLog("[Quip][PTT] transcript_result arrived textLen=%d errNil=%d",
                      msg.text.count, msg.error == nil ? 1 : 0)
                onTranscriptResult?(msg.sessionId, msg.text, msg.error)
            } else {
                NSLog("[Quip][PTT] transcript_result DECODE FAILED")
            }
        case "diagnostics_bundle":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(DiagnosticsBundleMessage.self, from: data) {
                NSLog("[WebSocketClient] diagnostics_bundle: %@ size=%d err=%@",
                      msg.filename, msg.sizeBytes, msg.errorReason ?? "none")
                onDiagnosticsBundle?(msg)
            }
        case "prompt_library":
            guard isAuthenticated else {
                print("[Quip] prompt_library RECEIVED but isAuthenticated=false — dropped")
                return
            }
            if let msg = try? decoder.decode(PromptLibraryMessage.self, from: data) {
                print("[Quip] prompt_library RECEIVED: \(msg.prompts.count) prompts")
                NSLog("[WebSocketClient] prompt_library: %d prompts", msg.prompts.count)
                promptLibrary = msg.prompts
                onPromptLibrary?(msg.prompts)
            } else {
                print("[Quip] prompt_library DECODE FAILED on \(data.count) bytes")
            }
        case "whisper_status":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(WhisperStatusMessage.self, from: data) {
                let tag: Int = {
                    switch msg.state {
                    case .preparing: return 0
                    case .ready: return 1
                    case .downloading: return 2
                    case .failed: return 3
                    }
                }()
                NSLog("[Quip][PTT] whisper_status arrived stateTag=%d (0prep 1ready 2dl 3fail)", tag)
                whisperStatus = msg.state
            } else {
                NSLog("[Quip][PTT] whisper_status DECODE FAILED")
            }
        default:
            NSLog("[WebSocketClient] Unknown message type: %@", peek.type)
        }
    }

    /// Ping the server every 10s and *await the pong* with a 3s timeout.
    /// Two consecutive missed pongs → treat the socket as dead and reconnect.
    ///
    /// The previous fire-and-forget `sendPing` only flipped to disconnected on a
    /// local send error. One-sided drops (Mac restart, NAT idle timeout, Cloudflare
    /// tunnel rotation) leave the callback hanging silently — pong never arrives,
    /// no error fires, and the UI shows "Connected" forever. Worst case to detect
    /// a real disconnect is now ~13s (10s interval + 3s pong timeout) instead of
    /// "until iOS or the OS notices TCP is dead," which can take many minutes on
    /// cellular.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            var consecutiveMisses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled, let self, let task = self.webSocketTask else { return }
                let pongReceived = await Self.probeSocket(task: task, timeoutNanos: 3_000_000_000)
                guard !Task.isCancelled else { return }
                if pongReceived {
                    consecutiveMisses = 0
                } else {
                    consecutiveMisses += 1
                    self.logEvent("keepalive pong missed (\(consecutiveMisses)/2)")
                    self.lastError = "No pong (\(consecutiveMisses)/2)"
                    if consecutiveMisses >= 2 {
                        self.logEvent("two consecutive missed pongs — forcing reconnect")
                        self.handleDisconnect()
                        return
                    }
                }
            }
        }
    }

    private func handleDisconnect() {
        guard !intentionalDisconnect else { return }
        keepaliveTask?.cancel()
        keepaliveTask = nil
        isConnected = false
        isConnecting = true
        if connectingStartedAt == nil { connectingStartedAt = Date() }
        isAuthenticated = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil

        // Don't nil the task if it's already been replaced by a new connection attempt
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        // Multi-URL fallback: if we have unused fallback URLs in the
        // current pairing's list, try the next one immediately (no
        // backoff sleep) before falling back to standard reconnect-with-
        // backoff on whatever URL we end up on. Only kick in if the
        // current URL never reached `connected` — once a URL has worked
        // we stick with it across transient failures (don't ping-pong
        // between LAN and Tailscale on every brief drop).
        if !connectURLs.isEmpty, currentURLIndex + 1 < connectURLs.count, !hasEverConnectedOnCurrentURL {
            let advanced = advanceToNextURL()
            if advanced {
                logEvent("falling back to next URL immediately")
                reconnectTask?.cancel()
                reconnectTask = Task { [weak self] in
                    guard let self, !Task.isCancelled, !self.intentionalDisconnect else { return }
                    self.establishConnection()
                }
                return
            }
        }

        logEvent("will reconnect in \(Int(reconnectDelay))s")

        let delay = reconnectDelay
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.intentionalDisconnect else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, 10.0)
            self.establishConnection()
        }
    }

    /// True once the current `serverURL` has reached the `connected` state
    /// at least once. Reset whenever `advanceToNextURL` flips the URL or
    /// `connect(toURLs:)` is called fresh. Used by `handleDisconnect` to
    /// decide whether transient drops should fail-fast over to the next
    /// URL or reconnect-with-backoff on the current one.
    private var hasEverConnectedOnCurrentURL = false
}
