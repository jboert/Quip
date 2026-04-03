// WebSocketClient.swift
// VoiceCodeiOS — URLSessionWebSocketTask client for Mac communication
// Connects to Mac via Cloudflare tunnel (wss://) or local (ws://)

import Foundation
import Observation

@Observable
@MainActor
final class WebSocketClient {

    var isConnected = false
    var isConnecting = false
    var serverURL: URL?

    var onLayoutUpdate: ((LayoutUpdate) -> Void)?
    var onStateChange: ((String, String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var intentionalDisconnect = false
    private var reconnectDelay: TimeInterval = 1.0
    private var reconnectTask: Task<Void, Never>?

    func connect(to url: URL) {
        intentionalDisconnect = false
        serverURL = url
        reconnectDelay = 1.0
        isConnecting = true
        establishConnection()
    }

    func disconnect() {
        intentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        isConnecting = false
        NSLog("[WebSocketClient] Disconnected intentionally")
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

        let urlSession = URLSession(configuration: .default)
        session = urlSession

        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        NSLog("[WebSocketClient] Connecting to %@", url.absoluteString)

        // Start receive loop
        receiveNext()

        // Check connection by sending a ping
        task.sendPing { [weak self] error in
            guard let self else { return }
            if let error = error {
                NSLog("[WebSocketClient] Ping failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    self.handleDisconnect()
                }
            } else {
                NSLog("[WebSocketClient] Connected successfully")
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.isConnecting = false
                    self.reconnectDelay = 1.0
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
        case "layout_update":
            do {
                let update = try decoder.decode(LayoutUpdate.self, from: data)
                NSLog("[WebSocketClient] layout_update: %d windows", update.windows.count)
                onLayoutUpdate?(update)
            } catch {
                NSLog("[WebSocketClient] decode error: %@", "\(error)")
            }
        case "state_change":
            struct SC: Codable { let windowId: String; let state: String }
            if let c = try? decoder.decode(SC.self, from: data) {
                onStateChange?(c.windowId, c.state)
            }
        default:
            NSLog("[WebSocketClient] Unknown message type: %@", peek.type)
        }
    }

    private func handleDisconnect() {
        guard !intentionalDisconnect else { return }
        isConnected = false
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
