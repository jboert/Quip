import Foundation
import Network
import Observation
import CommonCrypto

@MainActor
@Observable
final class CloudflareTunnel {

    var isRunning = false
    var publicURL: String = ""
    var webSocketURL: String = ""

    /// Set by QuipMacApp to allow tunnel clients to send messages
    /// to the same handler as direct WebSocket clients
    var webSocketServer: WebSocketServer? {
        didSet {
            cachedPIN = webSocketServer?.pinManager?.pin ?? ""
            cachedServer = webSocketServer
        }
    }

    /// Snapshot of the PIN for the proxy queue — avoids MainActor isolation issues.
    /// Updated whenever webSocketServer is assigned.
    @ObservationIgnored
    nonisolated(unsafe) var cachedPIN: String = ""

    /// Cached reference to the server for proxy-queue access.
    @ObservationIgnored
    nonisolated(unsafe) var cachedServer: WebSocketServer?

    private var process: Process?
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var proxyListener: NWListener?
    private let proxyPort: UInt16 = 8766
    private let proxyQueue = DispatchQueue(label: "quip.tunnel-proxy")
    private var stoppedIntentionally = false

    private static var logPath: String {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("Quip/tunnel.log").path
    }

    func start(localPort: UInt16 = 8765) {
        guard !isRunning else { return }
        stoppedIntentionally = false

        // Kill any orphaned cloudflared processes from previous app sessions.
        // When the app is force-quit, cloudflared gets reparented to PID 1 and
        // lives forever with stale edge connections, blocking new tunnels.
        killOrphanedCloudflared()

        // Start the tunnel proxy — handles WebSocket framing that cloudflared strips
        startProxy()

        // Use bundled binary first, fall back to Homebrew
        let bundledPath = Bundle.main.path(forResource: "cloudflared", ofType: nil)
        let homebrewPath = "/opt/homebrew/bin/cloudflared"
        let cfPath = bundledPath ?? homebrewPath
        guard FileManager.default.fileExists(atPath: cfPath) else {
            print("[CloudflareTunnel] cloudflared not found (checked bundle and /opt/homebrew/bin)")
            return
        }
        print("[CloudflareTunnel] Using: \(cfPath)")

        // Ensure log directory exists with private permissions
        let logDir = (Self.logPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        // Clear old log with private permissions
        fm.createFile(atPath: Self.logPath, contents: Data(), attributes: [.posixPermissions: 0o600])

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Point cloudflared to the proxy port
        shell.arguments = ["-c", "\(cfPath) tunnel --url http://localhost:\(proxyPort) > \(Self.logPath) 2>&1"]

        shell.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.pollTimer?.invalidate()
                self.healthTimer?.invalidate()
                if !self.stoppedIntentionally {
                    print("[CloudflareTunnel] Process died, restarting in 3 seconds")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, !self.stoppedIntentionally, !self.isRunning else { return }
                        self.publicURL = ""
                        self.webSocketURL = ""
                        self.start()
                    }
                }
            }
        }

        do {
            try shell.run()
            process = shell
            isRunning = true

            // Poll the log file for the URL
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.publicURL.isEmpty { self.pollTimer?.invalidate(); return }
                    self.checkLogForURL()
                }
            }

            // Health check — verify cloudflared is still alive every 60 seconds
            healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let proc = self.process, !proc.isRunning {
                        print("[CloudflareTunnel] Health check: process not running, restarting")
                        self.publicURL = ""
                        self.webSocketURL = ""
                        self.isRunning = false
                        self.start()
                    }
                }
            }
        } catch {
            isRunning = false
        }
    }

    func stop() {
        stoppedIntentionally = true
        pollTimer?.invalidate()
        pollTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        process?.terminate()
        process = nil
        proxyListener?.cancel()
        proxyListener = nil
        isRunning = false
        publicURL = ""
        webSocketURL = ""
    }

    private func checkLogForURL() {
        guard let content = try? String(contentsOfFile: Self.logPath, encoding: .utf8) else { return }
        guard let range = content.range(of: "https://[a-zA-Z0-9\\-]+\\.trycloudflare\\.com", options: .regularExpression) else { return }
        let url = String(content[range])
        publicURL = url
        webSocketURL = url.replacingOccurrences(of: "https://", with: "wss://")
    }

    private func killOrphanedCloudflared() {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "cloudflared tunnel"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let myPid = ProcessInfo.processInfo.processIdentifier
        for line in output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != myPid {
                print("[CloudflareTunnel] Killing orphaned cloudflared (pid \(pid))")
                kill(pid, SIGTERM)
            }
        }
    }

    // MARK: - Tunnel Proxy
    // Cloudflared strips WebSocket upgrade headers and handles framing at the edge.
    // This proxy speaks plain HTTP/TCP with cloudflared and handles WebSocket
    // handshake + framing manually, then routes messages to WebSocketServer.

    private func startProxy() {
        // The proxy listener survives cloudflared restarts — only create once.
        // When cloudflared dies, its TCP connections to us get FIN/RST which
        // fires .failed on each tunnel NWConnection and cleans up naturally via
        // cleanupTunnelConnection. Recreating the listener on every restart
        // leaks the old one (and any in-flight connections accepted on it) since
        // nothing cancels it before the new one stomps the var.
        guard proxyListener == nil else {
            print("[TunnelProxy] Already listening on \(proxyPort), reusing")
            return
        }

        do {
            // Keepalive here too — cloudflared dying ungracefully wouldn't send
            // TCP shutdown, so short probes speed up cleanup of dead tunnels.
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 15
            tcpOptions.keepaliveInterval = 5
            tcpOptions.keepaliveCount = 3
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            proxyListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: proxyPort)!)
        } catch {
            print("[TunnelProxy] Failed to create listener: \(error)")
            return
        }

        proxyListener?.newConnectionHandler = { [weak self] conn in
            self?.handleTunnelConnection(conn)
        }

        proxyListener?.start(queue: proxyQueue)
        print("[TunnelProxy] Listening on \(proxyPort)")
    }

    private nonisolated func handleTunnelConnection(_ conn: NWConnection) {
        // Monitor connection state so we clean up dead connections immediately
        // — prevents send buffers from growing unboundedly on zombie connections.
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cleanupTunnelConnection(conn)
            default:
                break
            }
        }
        conn.start(queue: proxyQueue)

        // Read the HTTP request from cloudflared
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self, let data = content, !data.isEmpty else {
                conn.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""

            // Extract WebSocket key for the handshake response
            var wsKey = ""
            for line in request.components(separatedBy: "\r\n") {
                if line.lowercased().hasPrefix("sec-websocket-key:") {
                    wsKey = String(line.dropFirst("sec-websocket-key:".count)).trimmingCharacters(in: .whitespaces)
                }
            }

            // Send 101 Switching Protocols back to cloudflared
            let acceptKey = self.computeWebSocketAccept(key: wsKey)
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"

            conn.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
                // Send auth_required as a WebSocket text frame
                let authMsg = "{\"type\":\"auth_result\",\"success\":false,\"error\":\"auth_required\"}"
                self.sendWSFrame(text: authMsg, on: conn)

                // Start receiving WebSocket frames from cloudflared
                self.receiveTunnelFrames(on: conn)
            }))
        }
    }

    // MARK: - WebSocket Frame Handling

    private nonisolated func computeWebSocketAccept(key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        magic.data(using: .utf8)!.withUnsafeBytes { CC_SHA1($0.baseAddress, CC_LONG(magic.count), &hash) }
        return Data(hash).base64EncodedString()
    }

    /// Send a WebSocket text frame (opcode 0x81)
    private nonisolated func sendWSFrame(text: String, on conn: NWConnection) {
        let payload = Data(text.utf8)
        var frame = Data()
        frame.append(0x81) // FIN + text opcode
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65535 {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed({ [weak self] error in
            if error != nil {
                self?.cleanupTunnelConnection(conn)
                conn.cancel()
            }
        }))
    }

    /// Receive and parse WebSocket frames from the tunnel client
    private nonisolated func receiveTunnelFrames(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self, let data = content, !data.isEmpty else {
                self?.cleanupTunnelConnection(conn)
                conn.cancel()
                return
            }

            // Parse WebSocket frame(s) from the data
            self.parseWSFrames(data: data, conn: conn)

            if !isComplete && error == nil {
                self.receiveTunnelFrames(on: conn)
            } else {
                self.cleanupTunnelConnection(conn)
            }
        }
    }

    private nonisolated func parseWSFrames(data: Data, conn: NWConnection) {
        var offset = 0
        while offset < data.count {
            guard offset + 1 < data.count else { break }

            let byte0 = data[offset]
            let byte1 = data[offset + 1]
            let opcode = byte0 & 0x0F
            let masked = (byte1 & 0x80) != 0
            var payloadLen = Int(byte1 & 0x7F)
            offset += 2

            if payloadLen == 126 {
                guard offset + 2 <= data.count else { break }
                payloadLen = Int(data[offset]) << 8 | Int(data[offset + 1])
                offset += 2
            } else if payloadLen == 127 {
                guard offset + 8 <= data.count else { break }
                payloadLen = 0
                for i in 0..<8 { payloadLen = (payloadLen << 8) | Int(data[offset + i]) }
                offset += 8
            }

            var maskKey: [UInt8] = []
            if masked {
                guard offset + 4 <= data.count else { break }
                maskKey = Array(data[offset..<offset+4])
                offset += 4
            }

            guard offset + payloadLen <= data.count else { break }
            var payload = Data(data[offset..<offset+payloadLen])
            offset += payloadLen

            // Unmask if needed
            if masked {
                for i in 0..<payload.count {
                    payload[i] ^= maskKey[i % 4]
                }
            }

            // Handle based on opcode
            switch opcode {
            case 0x01: // Text frame
                self.handleTunnelMessage(payload, on: conn)
            case 0x08: // Close
                self.cleanupTunnelConnection(conn)
                conn.cancel()
                return
            case 0x09: // Ping — respond with pong
                self.sendWSPong(payload: payload, on: conn)
            default:
                break
            }
        }
    }

    private nonisolated func sendWSPong(payload: Data, on conn: NWConnection) {
        var frame = Data()
        frame.append(0x8A) // FIN + pong opcode
        frame.append(UInt8(payload.count))
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    private nonisolated func cleanupTunnelConnection(_ conn: NWConnection) {
        tunnelAuthenticated.removeValue(forKey: ObjectIdentifier(conn))
        cachedServer?.unregisterTunnelClient(conn)
    }

    /// Whether this tunnel connection has been authenticated.
    /// Accessed only from the proxyQueue so no synchronization needed.
    @ObservationIgnored
    private nonisolated(unsafe) var tunnelAuthenticated: [ObjectIdentifier: Bool] = [:]

    private nonisolated func handleTunnelMessage(_ data: Data, on conn: NWConnection) {
        let messageType = MessageCoder.messageType(from: data)

        if messageType == "auth" {
            // Auth is handled entirely on the proxy queue — no main-queue hop.
            // This prevents auth hangs when the main queue is congested.
            if let authMsg = MessageCoder.decode(AuthMessage.self, from: data) {
                let pin = self.cachedPIN
                let response: AuthResultMessage
                if !pin.isEmpty && authMsg.pin == pin {
                    response = AuthResultMessage(success: true, error: nil)
                    self.tunnelAuthenticated[ObjectIdentifier(conn)] = true
                    print("[TunnelProxy] Client authenticated")
                    // Register for broadcasts immediately — registerTunnelClient is thread-safe
                    self.cachedServer?.registerTunnelClient(conn) { [weak self] (data: Data) in
                        if let json = String(data: data, encoding: .utf8) {
                            self?.sendWSFrame(text: json, on: conn)
                        }
                    }
                } else {
                    response = AuthResultMessage(success: false, error: pin.isEmpty ? "Server PIN not configured" : "Incorrect PIN")
                    print("[TunnelProxy] Auth failed: \(pin.isEmpty ? "no PIN configured" : "wrong PIN")")
                }
                if let responseData = try? JSONEncoder().encode(response),
                   let json = String(data: responseData, encoding: .utf8) {
                    self.sendWSFrame(text: json, on: conn)
                }
            }
        } else {
            // Non-auth messages must be authenticated and forwarded on main
            guard self.tunnelAuthenticated[ObjectIdentifier(conn)] == true else {
                print("[TunnelProxy] Dropping message from unauthenticated tunnel client")
                return
            }
            let arrivedAt = Date()
            let msgType = messageType ?? "?"
            KokoroTTSDebug.log("TUNNEL recv \(msgType) at proxy queue")
            DispatchQueue.main.async { [weak self] in
                let mainDelay = Date().timeIntervalSince(arrivedAt)
                KokoroTTSDebug.log("TUNNEL \(msgType) reached main after \(String(format: "%.1f", mainDelay))s")
                guard let self, let server = self.cachedServer else { return }
                server.onMessageReceived?(data)
            }
        }
    }
}
