// WebSocketClient.swift
// QuipiOS — URLSessionWebSocketTask client for Mac communication
// Connects to Mac via Cloudflare tunnel (wss://) or local (ws://)

import Foundation
import Observation
import Security
import CommonCrypto

// MARK: - Certificate Pinning for Cloudflare Tunnel

/// Pins Cloudflare's certificate chain for wss://*.trycloudflare.com connections.
/// Local ws:// connections bypass pinning entirely.
///
/// To update pins when Cloudflare rotates certificates:
///   openssl s_client -connect trycloudflare.com:443 -showcerts < /dev/null 2>/dev/null \
///     | openssl x509 -noout -pubkey | openssl pkey -pubin -outform DER \
///     | openssl dgst -sha256 -binary | base64
/// Run for each certificate in the chain and update the hashes below.
final class CloudflareCertificatePinningDelegate: NSObject, URLSessionDelegate {

    /// Base64-encoded SHA-256 hashes of Subject Public Key Info (SPKI) for
    /// certificates in the trycloudflare.com chain.
    /// Pinning intermediate + root CAs (not the leaf, which rotates frequently).
    ///
    /// Current chain (as of 2026-04):
    ///   Leaf:         CN=trycloudflare.com       (issued by WE1) — NOT pinned
    ///   Intermediate: CN=WE1                     (Google Trust Services)
    ///   Root:         CN=GTS Root R4             (cross-signed by GlobalSign)
    static let pinnedSPKIHashes: Set<String> = [
        // Google Trust Services WE1 (intermediate)
        "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=",
        // GTS Root R4
        "mEflZT5enoR1FuXLgYYGqnVEoZvmf9c2bVBpiOjYQ0c=",
    ]

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
    var onTerminalContent: ((String, String, String?) -> Void)?  // (windowId, content, screenshot)
    var onOutputDelta: ((String, String, String, Bool) -> Void)?  // (windowId, windowName, text, isFinal)
    // (windowId, windowName, sessionId, sequence, isFinal, wavData)
    var onTTSAudio: ((String, String, String, Int, Bool, Data) -> Void)?
    var onAuthRequired: (() -> Void)?
    var onAuthResult: ((Bool, String?) -> Void)?

    /// Cached PIN for the current session — used for auto-auth on reconnect
    private(set) var sessionPIN: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pinningDelegate: CloudflareCertificatePinningDelegate?
    private var intentionalDisconnect = false
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?

    func connect(to url: URL) {
        intentionalDisconnect = false
        serverURL = url
        reconnectDelay = 1.0
        lastError = nil
        isConnecting = true
        establishConnection()
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

    // MARK: - Private

    private func establishConnection() {
        guard let url = serverURL else { return }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        connectionTimeoutTask?.cancel()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10

        // Certificate pinning disabled — the hardcoded SPKI hashes need
        // to be verified against Cloudflare's current cert chain before enabling
        pinningDelegate = nil
        let urlSession = URLSession(configuration: config)
        session = urlSession

        let task = urlSession.webSocketTask(with: url)
        // Allow up to 16MB messages for base64-encoded TTS audio payloads (default is 1MB)
        task.maximumMessageSize = 16 * 1024 * 1024
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
                    NSLog("[WebSocketClient] Ping failed: %@", error.localizedDescription)
                    self.lastError = error.localizedDescription
                    self.handleDisconnect()
                } else {
                    NSLog("[WebSocketClient] Connected, awaiting authentication")
                    self.isConnected = true
                    self.isConnecting = false
                    self.authError = nil
                    self.lastError = nil
                    self.reconnectDelay = 1.0
                    self.startKeepalive()
                    // Auto-send cached PIN on reconnect, or prompt for PIN
                    // (skip if server already auto-authenticated us)
                    if !self.isAuthenticated {
                        if let pin = self.sessionPIN {
                            self.sendAuth(pin: pin)
                        } else {
                            self.onAuthRequired?()
                        }
                    }
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
                NSLog("[WebSocketClient] auth_result: success=%d error=%@", msg.success ? 1 : 0, msg.error ?? "none")
                // "auth_required" is the server's connection-ready signal, not a real error
                if msg.error == "auth_required" {
                    return
                }
                if msg.success {
                    isAuthenticated = true
                    authError = nil
                } else {
                    isAuthenticated = false
                    authError = msg.error ?? "Invalid PIN"
                    sessionPIN = nil  // Clear bad PIN
                }
                onAuthResult?(msg.success, msg.error)
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
                onTerminalContent?(msg.windowId, msg.content, msg.screenshot)
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
        default:
            NSLog("[WebSocketClient] Unknown message type: %@", peek.type)
        }
    }

    /// Ping the server every 30 seconds. If a ping fails, tear down and reconnect.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, let task = self.webSocketTask else { return }
                task.sendPing { error in
                    DispatchQueue.main.async {
                        if let error {
                            NSLog("[WebSocketClient] Keepalive ping failed: %@", error.localizedDescription)
                            self.handleDisconnect()
                        }
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
        isAuthenticated = false
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil

        // Don't nil the task if it's already been replaced by a new connection attempt
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil

        NSLog("[WebSocketClient] Will reconnect in %.0f seconds", reconnectDelay)

        let delay = reconnectDelay
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.intentionalDisconnect else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, 10.0)
            self.establishConnection()
        }
    }
}
