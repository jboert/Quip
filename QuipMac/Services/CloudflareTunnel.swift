import Foundation
import Observation

@MainActor
@Observable
final class CloudflareTunnel {

    var isRunning = false
    var publicURL: String = ""
    var webSocketURL: String = ""

    private var process: Process?
    private var pollTimer: Timer?
    private static let logPath = "/tmp/quip_tunnel.log"

    func start(localPort: UInt16 = 8765) {
        guard !isRunning else { return }

        // Use bundled binary first, fall back to Homebrew
        let bundledPath = Bundle.main.path(forResource: "cloudflared", ofType: nil)
        let homebrewPath = "/opt/homebrew/bin/cloudflared"
        let cfPath = bundledPath ?? homebrewPath
        guard FileManager.default.fileExists(atPath: cfPath) else {
            print("[CloudflareTunnel] cloudflared not found (checked bundle and /opt/homebrew/bin)")
            return
        }
        print("[CloudflareTunnel] Using: \(cfPath)")

        // Clear old log
        try? "".write(toFile: Self.logPath, atomically: true, encoding: .utf8)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Redirect all output to the log file
        shell.arguments = ["-c", "\(cfPath) tunnel --url http://localhost:\(localPort) > \(Self.logPath) 2>&1"]

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
}
