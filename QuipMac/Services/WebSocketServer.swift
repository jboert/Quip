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

    private var listener: NWListener?
    private var clients: [ClientConnection] = []

    /// Tracks a WebSocket connection and its authentication state.
    private struct ClientConnection {
        let connection: NWConnection
        var isAuthenticated: Bool = false
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

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let endpoint = connection.endpoint
            print("[WebSocketServer] New connection from: \(endpoint)")
            DispatchQueue.main.async {
                self.addConnection(connection)
            }
        }

        listener.start(queue: .main)
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

    func broadcast<T: Encodable & Sendable>(_ message: T) {
        let authenticatedClients = clients.filter(\.isAuthenticated)
        guard !authenticatedClients.isEmpty else { return }

        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            print("[WebSocketServer] Encode error: \(error)")
            return
        }

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

    private func addConnection(_ connection: NWConnection) {
        clients.append(ClientConnection(connection: connection))
        connectedClientCount = clients.count

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[WebSocketServer] Connection ready (pending auth)")
                DispatchQueue.main.async {
                    self.receiveMessage(on: connection)
                }
            case .failed(let error):
                print("[WebSocketServer] Connection failed: \(error)")
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

        connection.start(queue: .main)
    }

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
                let receivedData = data
                DispatchQueue.main.async {
                    let messageType = MessageCoder.messageType(from: receivedData)

                    // Auth messages are always handled, regardless of auth state
                    if messageType == "auth" {
                        self.handleAuthMessage(receivedData, from: connection)
                        return
                    }

                    // All other messages require authentication
                    guard self.isAuthenticated(connection) else {
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
