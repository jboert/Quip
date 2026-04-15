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
    var onMessageReceived: ((Data) -> Void)?
    var pinManager: PINManager?
    /// Read from the network queue during connection handshake, so it can't live
    /// on the MainActor. It's a plain Bool — atomic reads/writes are fine.
    @ObservationIgnored
    nonisolated(unsafe) var requireAuth: Bool = true

    private var listener: NWListener?
    private var clients: [ClientConnection] = []
    private let networkQueue = DispatchQueue(label: "quip.websocket", qos: .userInitiated)

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

        // Enable aggressive TCP keepalives so zombie connections — phones that
        // went to background without sending FIN/RST — are reaped within ~30s
        // instead of waiting for the 2h default RTO. Without this, every broadcast
        // (including 300–700 KB TTS audio chunks) piles up in the dead connection's
        // NWConnection send buffer until the socket finally times out.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15       // first probe after 15s of silence
        tcpOptions.keepaliveInterval = 5    // 5s between probes
        tcpOptions.keepaliveCount = 3       // 3 missed probes = dead (~30s total)

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        // Bind to IPv4 localhost only
        do {
            listener = try NWListener(using: parameters, on: 8765)
        } catch {
            print("[WebSocketServer] Failed to create listener: \(error)")
            return
        }

        guard let listener = listener else { return }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                DispatchQueue.main.async {
                    self.isRunning = true
                    print("[WebSocketServer] Listening on localhost:\(port)")
                }
            case .failed(let error):
                print("[WebSocketServer] Listener failed: \(error)")
                DispatchQueue.main.async {
                    self.isRunning = false
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self.isRunning = false
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
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
                    self.receiveMessage(on: connection)
                    Self.wslog("Sent auth signal, starting receiveMessage")
                    // State mutation hops to main (this can be slow under load,
                    // but the socket handshake no longer cares).
                    DispatchQueue.main.async {
                        var client = ClientConnection(connection: connection)
                        client.isAuthenticated = !requireAuthNow
                        self.clients.append(client)
                        self.connectedClientCount = self.clients.count
                    }
                case .failed(let error):
                    Self.wslog("Connection FAILED: \(error)")
                    KokoroTTSDebug.log("WS connection FAILED: \(error)")
                    DispatchQueue.main.async {
                        self.removeConnection(connection)
                    }
                case .cancelled:
                    DispatchQueue.main.async {
                        self.removeConnection(connection)
                    }
                default:
                    break
                }
            }
            connection.start(queue: self.networkQueue)
            Self.wslog("connection.start() called immediately")
        }

        listener.start(queue: networkQueue)
    }

    func stop() {
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
        let path = "/tmp/quip_ws_debug.log"
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

        if authMsg.pin == expectedPIN {
            KokoroTTSDebug.log("auth: PIN matched, sending success")
            setAuthenticated(connection)
            send(AuthResultMessage(success: true, error: nil), to: connection)
            print("[WebSocketServer] Client authenticated successfully")
        } else {
            KokoroTTSDebug.log("auth: PIN mismatch (got '\(authMsg.pin)', expected '\(expectedPIN)')")
            send(AuthResultMessage(success: false, error: "Incorrect PIN"), to: connection)
            print("[WebSocketServer] Authentication failed: incorrect PIN")
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
                // Drop oversized messages (64KB limit)
                if data.count > 65_536 {
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
