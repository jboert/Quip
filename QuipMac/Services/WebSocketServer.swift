// WebSocketServer.swift
// QuipMac — NWListener-based WebSocket server
// Listens on localhost:8765 for iPhone connections via Cloudflare tunnel

import Foundation
import Network
import Observation

@MainActor
@Observable
final class WebSocketServer {

    var isRunning: Bool = false
    var connectedClientCount: Int = 0
    /// Number of currently-authenticated direct WebSocket clients. Diagnostic.
    var authenticatedClientCount: Int { clients.filter(\.isAuthenticated).count }
    var onMessageReceived: ((Data) -> Void)?
    var onClientAuthenticated: (() -> Void)?
    var pinManager: PINManager?
    /// Diagnostics log — optional so nothing breaks if the app hasn't wired
    /// it in yet. The server feeds events (connect/disconnect/auth), the
    /// Settings panel reads them.
    var connectionLog: ConnectionLog?
    /// Read from the network queue during connection handshake, so it can't live
    /// on the MainActor. It's a plain Bool — atomic reads/writes are fine.
    @ObservationIgnored
    nonisolated(unsafe) var requireAuth: Bool = true

    private var listener: NWListener?
    private var clients: [ClientConnection] = []
    private let networkQueue = DispatchQueue(label: "quip.websocket", qos: .userInitiated)
    /// Retry interval when the listener can't bind (e.g. port 8765 squatted by
    /// another process). Without this the server would give up silently and the
    /// phone would talk to whatever is on 8765 and report "bad response from server".
    nonisolated private static let bindRetryInterval: TimeInterval = 5
    private var bindRetryWorkItem: DispatchWorkItem?

    /// Tracks a WebSocket connection, its authentication state, and rate limiting.
    private struct ClientConnection {
        let connection: NWConnection
        var isAuthenticated: Bool = false
        var messageCount: Int = 0
        var windowStart: Date = Date()
        /// Bytes currently in flight (queued for send, completion not yet fired).
        /// When this exceeds `maxPendingBytes`, we stop queueing broadcasts to this
        /// client so a dead/slow socket can't balloon the NWConnection send buffer
        /// into GB-scale memory while TCP keepalive waits to reap it.
        var pendingBytes: Int = 0

        static let maxMessagesPerSecond = 10
        /// Drop broadcasts once a single client has this much buffered. Chosen to
        /// be a couple of TTS audio chunks (~500KB each) worth — enough headroom
        /// for normal bursty traffic, small enough to bound the leak if a phone
        /// silently goes dark.
        static let maxPendingBytes = 2_000_000

        /// Returns true if the message should be allowed, false if rate-limited.
        mutating func allowMessage() -> Bool {
            let now = Date()
            if now.timeIntervalSince(windowStart) >= 1.0 {
                // New window
                windowStart = now
                messageCount = 1
                return true
            }
            messageCount += 1
            return messageCount <= Self.maxMessagesPerSecond
        }
    }

    func start() {
        guard !isRunning else { return }

        // Bind a single IPv4-wildcard listener. The previous default
        // `NWListener(using: parameters, on: 8765)` silently bound `::.8765`
        // with `IPV6_V6ONLY` semantics — it accepted the loopback path
        // (`[::1]` from the Cloudflare tunnel proxy) but rejected every IPv4
        // connection, including the Tailscale `100.x` MagicDNS path. Loopback
        // kept working and masked the bug for months.
        //
        // Binding `0.0.0.0` (IPv4 wildcard) covers loopback v4 (Cloudflare
        // tunnel resolves `localhost` to `127.0.0.1`), LAN v4, and Tailscale
        // CGNAT v4 — every path Quip currently uses. A dual-stack v6 socket
        // with `IPV6_V6ONLY=0` would also work in theory, but Network.framework
        // sets the v6-only flag on its listeners and exposes no knob to clear
        // it; running parallel v4 + v6 listeners hits `EADDRINUSE` because the
        // v4 wildcard collides with the (effectively dual-stack) v6 wildcard.
        // If Tailscale-over-IPv6 ever matters, we'll need a raw socket bind.
        do {
            listener = try makeListener()
        } catch {
            print("[WebSocketServer] Failed to create listener: \(error) — retrying in \(Self.bindRetryInterval)s")
            connectionLog?.record(
                .failed,
                remote: "listener:8765",
                detail: "bind failed: \(error) — will retry"
            )
            listener?.cancel(); listener = nil
            scheduleBindRetry()
            return
        }

        guard let listener = listener else { return }
        attachHandlers(to: listener)
        listener.start(queue: networkQueue)
    }

    /// Build the IPv4-wildcard listener. Pinning the local endpoint via
    /// `requiredLocalEndpoint` is what forces the bind to `0.0.0.0:8765`
    /// instead of letting Network.framework default to `[::]:8765`. The
    /// seemingly-equivalent `NWProtocolIP.Options.version = .v4` is honored
    /// only for outbound connections — `NWListener(using:on:)` ignores it.
    private func makeListener() throws -> NWListener {
        // Aggressive TCP keepalives so zombie connections — phones that went
        // to background without sending FIN/RST — are reaped within ~30s
        // instead of waiting for the 2h default RTO. Without this, every
        // broadcast (including 300–700 KB TTS audio chunks) piles up in the
        // dead connection's NWConnection send buffer until the socket times out.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: 8765)
        parameters.allowLocalEndpointReuse = true

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        // Default max message size is ~1 MiB, which rejects image uploads
        // (base64 of a full-resolution phone photo is ~7-10 MB). See WSLimits.
        wsOptions.maximumMessageSize = WSLimits.maxMessageBytes
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        return try NWListener(using: parameters)
    }

    /// Wire state + new-connection handlers onto the listener.
    private func attachHandlers(to listener: NWListener) {
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener?.port?.rawValue ?? 0
                DispatchQueue.main.async {
                    self.isRunning = true
                    print("[WebSocketServer] Listening on 0.0.0.0:\(port)")
                }
            case .failed(let error):
                print("[WebSocketServer] Listener failed: \(error) — retrying in \(Self.bindRetryInterval)s")
                DispatchQueue.main.async {
                    self.connectionLog?.record(
                        .failed,
                        remote: "listener:8765",
                        detail: "listener failed: \(error) — will retry"
                    )
                    self.listener?.cancel(); self.listener = nil
                    self.isRunning = false
                    self.scheduleBindRetry()
                }
            case .cancelled:
                DispatchQueue.main.async {
                    if self.listener == nil {
                        self.isRunning = false
                    }
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
    }

    /// Per-connection setup. Identical for v4 and v6 acceptors.
    /// `nonisolated` because NWListener.newConnectionHandler runs on the
    /// network queue, not the main actor — same context the original inline
    /// closure ran in. Internal main-actor mutations are dispatched via
    /// `DispatchQueue.main.async` blocks, matching the prior pattern.
    private nonisolated func handleNewConnection(_ connection: NWConnection) {
        Self.wslog("newConnectionHandler fired for \(connection.endpoint)")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Self.wslog("Connection state: \(state) for \(connection.endpoint)")
            switch state {
            case .ready:
                Self.wslog("Connection ready (pending auth)")
                KokoroTTSDebug.log("WS connection ready from \(connection.endpoint)")
                // CRITICAL: fire the auth signal and start the receive loop
                // IMMEDIATELY on the network queue. We used to do this inside
                // DispatchQueue.main.async, but under reconnect storms main
                // would get backed up 3-26s by SwiftUI re-renders, iOS would
                // time out, and the socket would reset mid-handshake.
                let requireAuthNow = self.requireAuth
                let signalMsg: AuthResultMessage = requireAuthNow
                    ? AuthResultMessage(success: false, error: "auth_required")
                    : AuthResultMessage(success: true, error: nil)
                KokoroTTSDebug.log(requireAuthNow ? "WS sending auth_required" : "WS sending auth_result success (no auth required)")
                self.send(signalMsg, to: connection)
                // Send DeviceIdentityMessage so the phone can rekey its
                // paired-backend row to this Mac's stable UUID. Normally
                // sent inside handleAuthMessage on PIN success — but the
                // no-PIN path skips that entirely, so phone never sees
                // device_identity and same-Mac dedupe (Bonjour vs
                // Tailscale) can't run.
                if !requireAuthNow {
                    self.send(DeviceIdentityMessage(
                        deviceID: Self.deviceID(),
                        deviceKind: "mac",
                        displayName: Host.current().localizedName ?? "Mac"
                    ), to: connection)
                }
                self.receiveMessage(on: connection)
                Self.wslog("Sent auth signal, starting receiveMessage")
                let remoteStr = String(describing: connection.endpoint)
                DispatchQueue.main.async {
                    var client = ClientConnection(connection: connection)
                    client.isAuthenticated = !requireAuthNow
                    self.clients.append(client)
                    self.connectedClientCount = self.clients.count
                    self.connectionLog?.record(
                        .connected,
                        remote: remoteStr,
                        detail: requireAuthNow ? "awaiting PIN" : "no PIN required"
                    )
                    // requireAuth=false path bypasses handleAuthMessage,
                    // so onClientAuthenticated would never fire and the
                    // host's "send initial layout / permissions /
                    // prompt_library" handler never runs. Fire it here
                    // for the no-PIN case so phones get their catalog
                    // exactly the same way they would on a PIN-required
                    // server.
                    if !requireAuthNow {
                        self.onClientAuthenticated?()
                    }
                }
            case .failed(let error):
                Self.wslog("Connection FAILED: \(error)")
                KokoroTTSDebug.log("WS connection FAILED: \(error)")
                let remoteStr = String(describing: connection.endpoint)
                let errStr = String(describing: error)
                DispatchQueue.main.async {
                    self.connectionLog?.record(.failed, remote: remoteStr, detail: errStr)
                    self.removeConnection(connection)
                }
            case .cancelled:
                let remoteStr = String(describing: connection.endpoint)
                DispatchQueue.main.async {
                    self.connectionLog?.record(.disconnected, remote: remoteStr, detail: nil)
                    self.removeConnection(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
        Self.wslog("connection.start() called immediately")
    }

    /// Schedule a single-shot retry of `start()`. Idempotent — replaces any
    /// already-pending retry so we don't stack timers when `.failed` fires
    /// repeatedly.
    private func scheduleBindRetry() {
        bindRetryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.bindRetryWorkItem = nil
            self.start()
        }
        bindRetryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bindRetryInterval, execute: work)
    }

    func stop() {
        bindRetryWorkItem?.cancel()
        bindRetryWorkItem = nil
        listener?.cancel()
        listener = nil
        for client in clients {
            client.connection.cancel()
        }
        clients.removeAll()
        connectedClientCount = 0
        isRunning = false
        print("[WebSocketServer] Stopped")
    }

    /// Tunnel clients that handle their own WebSocket framing.
    /// Protected by its own lock so registration can happen from the proxy queue
    /// without waiting for the main queue, which may be congested.
    private struct TunnelBroadcaster: @unchecked Sendable {
        let id: ObjectIdentifier
        let sender: @Sendable (Data) -> Void
    }

    @ObservationIgnored
    private let tunnelBroadcastersLock = NSLock()
    @ObservationIgnored
    private nonisolated(unsafe) var tunnelBroadcasters: [TunnelBroadcaster] = []

    var hasConnectedClients: Bool {
        !clients.isEmpty || tunnelBroadcasterCount > 0
    }

    private var tunnelBroadcasterCount: Int {
        tunnelBroadcastersLock.lock()
        defer { tunnelBroadcastersLock.unlock() }
        return tunnelBroadcasters.count
    }

    /// Register a tunnel connection for receiving broadcast messages.
    /// Safe to call from any queue.
    nonisolated func registerTunnelClient(_ conn: NWConnection, sender: @escaping @Sendable (Data) -> Void) {
        let connId = ObjectIdentifier(conn)
        tunnelBroadcastersLock.lock()
        // Remove any existing broadcaster for this connection before adding
        tunnelBroadcasters.removeAll { $0.id == connId }
        tunnelBroadcasters.append(TunnelBroadcaster(id: connId, sender: sender))
        let count = tunnelBroadcasters.count
        tunnelBroadcastersLock.unlock()
        print("[WebSocketServer] Tunnel client registered. \(count) tunnel client(s)")
    }

    /// Unregister a tunnel connection when it disconnects.
    /// Safe to call from any queue.
    nonisolated func unregisterTunnelClient(_ conn: NWConnection) {
        let connId = ObjectIdentifier(conn)
        tunnelBroadcastersLock.lock()
        tunnelBroadcasters.removeAll { $0.id == connId }
        let count = tunnelBroadcasters.count
        tunnelBroadcastersLock.unlock()
        print("[WebSocketServer] Tunnel client unregistered. \(count) tunnel client(s)")
    }

    func broadcast<T: Encodable & Sendable>(_ message: T) {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            print("[WebSocketServer] Encode error: \(error)")
            return
        }

        // Send to authenticated direct WebSocket clients
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textMessage", metadata: [metadata])
        let payloadSize = data.count
        for i in clients.indices {
            guard clients[i].isAuthenticated else { continue }
            // Backpressure: skip this client if its NWConnection is already sitting
            // on a large backlog — a phone that backgrounded and hasn't been TCP-
            // reaped yet must not soak up layout updates, TTS chunks, and screenshots.
            if clients[i].pendingBytes + payloadSize > ClientConnection.maxPendingBytes {
                continue
            }
            clients[i].pendingBytes += payloadSize
            let conn = clients[i].connection
            conn.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let idx = self.clients.firstIndex(where: { $0.connection === conn }) {
                        self.clients[idx].pendingBytes = max(0, self.clients[idx].pendingBytes - payloadSize)
                    }
                    if error != nil {
                        self.removeConnection(conn)
                    }
                }
            }))
        }

        // Send to authenticated tunnel clients
        tunnelBroadcastersLock.lock()
        let broadcasters = tunnelBroadcasters
        tunnelBroadcastersLock.unlock()
        for broadcaster in broadcasters {
            broadcaster.sender(data)
        }
    }

    /// Send a message to a specific connection (used for auth results).
    /// `nonisolated` because it's a pure encode-then-write helper that touches
    /// no `self` state — safe to call from the network queue during handshake.
    private nonisolated func send<T: Encodable>(_ message: T, to connection: NWConnection) {
        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            print("[WebSocketServer] Encode error: \(error)")
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textMessage", metadata: [metadata])

        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
            if let error = error {
                print("[WebSocketServer] Send error: \(error)")
            }
        }))
    }

    // MARK: - Private

    private nonisolated static func wslog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        let path = LogPaths.webSocketPath
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
        print("[WebSocketServer] \(msg)")
    }

    // addConnection is handled inline in newConnectionHandler to avoid
    // DispatchQueue.main.async delay which causes ECONNABORTED

    private func removeConnection(_ connection: NWConnection) {
        clients.removeAll(where: { $0.connection === connection })
        connectedClientCount = clients.count
        // Force the NWConnection to tear down immediately. Without this the
        // socket's send buffer can sit on queued bytes (layout updates, TTS
        // chunks) until the kernel notices — which on a dead Wi-Fi link can
        // take the full TCP keepalive window (~30s). Repeated over a night,
        // that's how you grow to tens of GB of resident memory.
        connection.cancel()
        print("[WebSocketServer] Connection removed. \(clients.count) remaining.")
    }

    private func isAuthenticated(_ connection: NWConnection) -> Bool {
        clients.first(where: { $0.connection === connection })?.isAuthenticated ?? false
    }

    private func setAuthenticated(_ connection: NWConnection) {
        if let index = clients.firstIndex(where: { $0.connection === connection }) {
            clients[index].isAuthenticated = true
        }
    }

    /// Stable per-installation UUID. Generated on first call and persisted in
    /// `UserDefaults` under `quip.deviceID`. The phone uses this to key
    /// per-backend state (PIN in Keychain, paired-backend row) so that state
    /// survives URL/hostname changes.
    nonisolated static func deviceID() -> String {
        let key = "quip.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    /// Per-host auth throttle. See AuthThrottle.swift for policy.
    private let authThrottle = AuthThrottle()

    private func handleAuthMessage(_ data: Data, from connection: NWConnection) {
        KokoroTTSDebug.log("handleAuthMessage: \(data.count) bytes from \(connection.endpoint)")
        guard let authMsg = MessageCoder.decode(AuthMessage.self, from: data) else {
            KokoroTTSDebug.log("auth: failed to decode AuthMessage")
            send(AuthResultMessage(success: false, error: "Malformed auth message"), to: connection)
            return
        }

        guard let expectedPIN = pinManager?.pin, !expectedPIN.isEmpty else {
            KokoroTTSDebug.log("auth: no PIN configured in pinManager (pinManager=\(pinManager == nil ? "nil" : "set"))")
            send(AuthResultMessage(success: false, error: "Server PIN not configured"), to: connection)
            return
        }

        let remoteStr = String(describing: connection.endpoint)
        let host = AuthThrottle.host(from: remoteStr)

        // Reject locked-out hosts BEFORE comparing the PIN — there's nothing
        // they can send during a lockout window that we want to act on.
        if case .locked(let remaining) = authThrottle.check(host: host) {
            let secs = Int(remaining.rounded(.up))
            KokoroTTSDebug.log("auth: host \(host) locked, \(secs)s remaining")
            send(AuthResultMessage(success: false,
                                   error: "Too many attempts; try again in \(secs)s"),
                 to: connection)
            connectionLog?.record(.authFailed, remote: remoteStr,
                                  detail: "locked (\(secs)s remaining)")
            return
        }

        if authMsg.pin == expectedPIN {
            KokoroTTSDebug.log("auth: PIN matched, sending success")
            authThrottle.recordSuccess(host: host)
            setAuthenticated(connection)
            send(AuthResultMessage(success: true, error: nil), to: connection)
            // Stable backend UUID so the phone can key per-backend state
            // (PIN in Keychain, paired-backend row) against something that
            // survives URL/hostname changes. See DeviceIdentityMessage.
            send(DeviceIdentityMessage(
                deviceID: Self.deviceID(),
                deviceKind: "mac",
                displayName: Host.current().localizedName ?? "Mac"
            ), to: connection)
            print("[WebSocketServer] Client authenticated successfully")
            connectionLog?.record(.authSucceeded, remote: remoteStr, detail: nil)
            onClientAuthenticated?()
        } else {
            // Never log either PIN. Lengths only, so we can still spot a
            // misconfigured client.
            KokoroTTSDebug.log("auth: PIN mismatch (got len=\(authMsg.pin.count), expected len=\(expectedPIN.count))")
            authThrottle.recordFailure(host: host)
            // Schedule the response after a brief delay so a brute-force
            // script bottlenecks at one attempt per few seconds rather than
            // racing the network. Lower bound 0 means the first wrong PIN
            // gets answered immediately — typo tolerance.
            let delayMs: Int
            if case .proceed(let d) = authThrottle.check(host: host) { delayMs = d } else { delayMs = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self else { return }
                self.send(AuthResultMessage(success: false, error: "Incorrect PIN"), to: connection)
                print("[WebSocketServer] Authentication failed: incorrect PIN")
                self.connectionLog?.record(.authFailed, remote: remoteStr, detail: "incorrect PIN")
            }
        }
    }

    /// `nonisolated` because the body just arms an async receive callback on
    /// the NWConnection — all `self` access inside the callback already hops
    /// to main via `DispatchQueue.main.async`.
    private nonisolated func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, contentContext, isComplete, error in
            guard let self else { return }

            if let error = error {
                print("[WebSocketServer] Receive error: \(error)")
                DispatchQueue.main.async {
                    self.removeConnection(connection)
                }
                return
            }

            if let data = content, !data.isEmpty {
                // Application-layer drop: matches the WebSocket protocol's
                // maximumMessageSize above. Image uploads from the phone are
                // commonly 1-10 MiB (base64-encoded JPEG/PNG). The previous 64KB
                // cap silently murdered every image_upload, leaving the phone's
                // spinner hanging forever. TTS audio chunks run 300-700 KB so
                // they comfortably fit under the ceiling. See WSLimits.
                if data.count > WSLimits.maxMessageBytes {
                    KokoroTTSDebug.log("WS: dropping oversized msg \(data.count) bytes")
                    print("[WebSocketServer] Dropping oversized message (\(data.count) bytes)")
                    self.receiveMessage(on: connection)
                    return
                }

                let receivedData = data
                DispatchQueue.main.async {
                    let messageType = MessageCoder.messageType(from: receivedData)
                    KokoroTTSDebug.log("WS received: type=\(messageType ?? "unknown") (\(receivedData.count) bytes)")

                    // Auth messages bypass rate limiting and auth checks
                    if messageType == "auth" {
                        self.handleAuthMessage(receivedData, from: connection)
                        return
                    }

                    // Rate limit: drop excess messages beyond 10/sec per client
                    guard let clientIndex = self.clients.firstIndex(where: { $0.connection === connection }),
                          self.clients[clientIndex].allowMessage() else {
                        return
                    }

                    // All other messages require authentication
                    guard !self.requireAuth || self.isAuthenticated(connection) else {
                        print("[WebSocketServer] Dropping message from unauthenticated client: \(messageType ?? "unknown")")
                        return
                    }

                    self.onMessageReceived?(receivedData)
                }
            }

            // Continue receiving
            self.receiveMessage(on: connection)
        }
    }
}
