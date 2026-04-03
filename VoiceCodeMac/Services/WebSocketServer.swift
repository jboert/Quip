// WebSocketServer.swift
// VoiceCodeMac — NWListener-based WebSocket server
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

    private var listener: NWListener?
    private var connections: [NWConnection] = []

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
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectedClientCount = 0
        isRunning = false
        print("[WebSocketServer] Stopped")
    }

    func broadcast<T: Encodable & Sendable>(_ message: T) {
        guard !connections.isEmpty else { return }

        let data: Data
        do {
            data = try JSONEncoder().encode(message)
        } catch {
            print("[WebSocketServer] Encode error: \(error)")
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "textMessage", metadata: [metadata])

        for connection in connections {
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
                if let error = error {
                    print("[WebSocketServer] Send error: \(error)")
                }
            }))
        }
    }

    // MARK: - Private

    private func addConnection(_ connection: NWConnection) {
        connections.append(connection)
        connectedClientCount = connections.count

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[WebSocketServer] Connection ready")
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
        connections.removeAll(where: { $0 === connection })
        connectedClientCount = connections.count
        print("[WebSocketServer] Connection removed. \(connections.count) remaining.")
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
                    self.onMessageReceived?(receivedData)
                }
            }

            // Continue receiving
            self.receiveMessage(on: connection)
        }
    }
}
