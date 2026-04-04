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
    var requireAuth: Bool = true

    private var listener: NWListener?
    private var clients: [ClientConnection] = []
    private let networkQueue = DispatchQueue(label: "quip.websocket", qos: .userInitiated)

    /// Tracks a WebSocket connection, its authentication state, and rate limiting.
    private struct ClientConnection {
        let connection: NWConnection
        var isAuthenticated: Bool = false
        var messageCount: Int = 0
        var windowStart: Date = Date()

        static let maxMessagesPerSecond = 10

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

        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
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
                    DispatchQueue.main.async {
                        self.clients.append(ClientConnection(connection: connection))
                        self.connectedClientCount = self.clients.count
                        // Send auth_required immediately so the client knows
                        // the connection is alive (bypasses WebSocket ping/pong issues)
                        if self.requireAuth {
                            self.send(AuthResultMessage(success: false, error: "auth_required"), to: connection)
                        } else {
                            // Auto-authenticate when PIN not required
                            if let idx = self.clients.firstIndex(where: { $0.connection === connection }) {
                                self.clients[idx].isAuthenticated = true
                            }
                        }
                        Self.wslog("Sent auth_required, starting receiveMessage")
                        self.receiveMessage(on: connection)
                    }
                case .failed(let error):
                    Self.wslog("Connection FAILED: \(error)")
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

    /// Tunnel clients that handle their own WebSocket framing
    private var tunnelBroadcasters: [(Data) -> Void] = []

    var hasConnectedClients: Bool {
        !clients.isEmpty || !tunnelBroadcasters.isEmpty
    }

    /// Register a tunnel connection for receiving broadcast messages
    func registerTunnelClient(_ conn: NWConnection, sender: @escaping (Data) -> Void) {
        tunnelBroadcasters.append(sender)
        print("[WebSocketServer] Tunnel client registered. \(tunnelBroadcasters.count) tunnel client(s)")
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
        let authenticatedClients = clients.filter(\.isAuthenticated)
        if !authenticatedClients.isEmpty {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "textMessage", metadata: [metadata])

            for client in authenticatedClients {
                client.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
                    if let error = error {
                        print("[WebSocketServer] Send error: \(error)")
                    }
                }))
            }
        }

        // Send to authenticated tunnel clients
        for sender in tunnelBroadcasters {
            sender(data)
        }
    }

    /// Send a message to a specific connection (used for auth results).
    private func send<T: Encodable>(_ message: T, to connection: NWConnection) {
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
        guard let authMsg = MessageCoder.decode(AuthMessage.self, from: data) else {
            send(AuthResultMessage(success: false, error: "Malformed auth message"), to: connection)
            return
        }

        guard let expectedPIN = pinManager?.pin, !expectedPIN.isEmpty else {
            send(AuthResultMessage(success: false, error: "Server PIN not configured"), to: connection)
            return
        }

        if authMsg.pin == expectedPIN {
            setAuthenticated(connection)
            send(AuthResultMessage(success: true, error: nil), to: connection)
            print("[WebSocketServer] Client authenticated successfully")
        } else {
            send(AuthResultMessage(success: false, error: "Incorrect PIN"), to: connection)
            print("[WebSocketServer] Authentication failed: incorrect PIN")
        }
    }

    private func receiveMessage(on connection: NWConnection) {
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
                    print("[WebSocketServer] Dropping oversized message (\(data.count) bytes)")
                    self.receiveMessage(on: connection)
                    return
                }

                let receivedData = data
                DispatchQueue.main.async {
                    let messageType = MessageCoder.messageType(from: receivedData)

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
