import Foundation
import Network
import Observation

@MainActor
@Observable
final class CloudflareTunnel {

    var isRunning = false
    var publicURL: String = ""
    var webSocketURL: String = ""

    private var process: Process?
    private var pollTimer: Timer?
    private var proxyListener: NWListener?
    private let proxyPort: UInt16 = 8766
    private let proxyQueue = DispatchQueue(label: "quip.tunnel-proxy")

    private static var logPath: String {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("Quip/tunnel.log").path
    }

    func start(localPort: UInt16 = 8765) {
        guard !isRunning else { return }

        // Start the WebSocket header proxy first
        startProxy(backendPort: localPort)

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
        // Point cloudflared to the proxy port, not the WebSocket port directly
        shell.arguments = ["-c", "\(cfPath) tunnel --url http://localhost:\(proxyPort) > \(Self.logPath) 2>&1"]

        shell.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.isRunning = false
                self?.pollTimer?.invalidate()
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
        } catch {
            isRunning = false
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
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

    // MARK: - WebSocket Header Proxy
    // Cloudflared strips Connection: Upgrade and Upgrade: websocket headers
    // when proxying to HTTP backends. This proxy sits between cloudflared and
    // the NWListener WebSocket server, reconstructing the proper upgrade headers.

    private func startProxy(backendPort: UInt16) {
        do {
            let params = NWParameters.tcp
            proxyListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: proxyPort)!)
        } catch {
            print("[TunnelProxy] Failed to create listener: \(error)")
            return
        }

        proxyListener?.newConnectionHandler = { [weak self] clientConn in
            guard let self else { return }
            self.handleProxyConnection(clientConn, backendPort: backendPort)
        }

        proxyListener?.start(queue: proxyQueue)
        print("[TunnelProxy] Listening on \(proxyPort) -> \(backendPort)")
    }

    private nonisolated func handleProxyConnection(_ clientConn: NWConnection, backendPort: UInt16) {
        clientConn.start(queue: proxyQueue)

        // Read the HTTP request from cloudflared
        clientConn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, _, error in
            guard let self, let data = content, !data.isEmpty else {
                clientConn.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""

            // Extract WebSocket key from the request
            var wsKey = ""
            var wsVersion = "13"
            var host = "localhost"
            for line in request.components(separatedBy: "\r\n") {
                let lower = line.lowercased()
                if lower.hasPrefix("sec-websocket-key:") {
                    wsKey = String(line.dropFirst("sec-websocket-key:".count)).trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("sec-websocket-version:") {
                    wsVersion = String(line.dropFirst("sec-websocket-version:".count)).trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("host:") {
                    host = String(line.dropFirst("host:".count)).trimmingCharacters(in: .whitespaces)
                }
            }

            // Build a clean WebSocket upgrade request
            let cleanRequest = "GET / HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(wsKey)\r\nSec-WebSocket-Version: \(wsVersion)\r\n\r\n"

            // Connect to the actual WebSocket server
            let backendConn = NWConnection(host: "::1", port: NWEndpoint.Port(rawValue: backendPort)!, using: .tcp)
            backendConn.start(queue: self.proxyQueue)

            backendConn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send the clean upgrade request
                    backendConn.send(content: Data(cleanRequest.utf8), completion: .contentProcessed({ _ in
                        // Read the 101 response — parse until \r\n\r\n to avoid
                        // eating WebSocket frames that follow immediately
                        self.consumeHTTPResponse(from: backendConn, buffer: Data()) {
                            self.bridgeConnections(clientConn, backendConn)
                        }
                    }))
                case .failed, .cancelled:
                    clientConn.cancel()
                default:
                    break
                }
            }
        }
    }

    /// Read from connection byte-by-byte until the HTTP response headers end (\r\n\r\n).
    /// Any data after the headers (WebSocket frames) is forwarded to the client connection
    /// via the bridge, not consumed here.
    private nonisolated func consumeHTTPResponse(from conn: NWConnection, buffer: Data, then completion: @escaping () -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { content, _, _, error in
            guard let data = content, !data.isEmpty else {
                completion()
                return
            }
            var combined = buffer + data
            // Look for the end of HTTP headers
            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            if let range = combined.range(of: separator) {
                // Headers end found — any data after is WebSocket frames, leave it for the bridge
                // The NWConnection buffers unread data, so the bridge will pick it up
                completion()
            } else {
                // Haven't found the end of headers yet, keep reading
                self.consumeHTTPResponse(from: conn, buffer: combined, then: completion)
            }
        }
    }

    private nonisolated func bridgeConnections(_ a: NWConnection, _ b: NWConnection) {
        pipeData(from: a, to: b)
        pipeData(from: b, to: a)
    }

    private nonisolated func pipeData(from src: NWConnection, to dst: NWConnection) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                dst.send(content: data, completion: .contentProcessed({ _ in
                    self?.pipeData(from: src, to: dst)
                }))
            } else if isComplete || error != nil {
                dst.cancel()
            } else {
                self?.pipeData(from: src, to: dst)
            }
        }
    }
}
