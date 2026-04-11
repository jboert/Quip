// TailscaleService.swift
// QuipMac — Detects the Mac's Tailscale hostname by shelling out to the
// `tailscale status --json` CLI. Exposes an observable `webSocketURL` built
// from the MagicDNS name (or the 100.x IP as a fallback) and the configured
// WebSocket port. One-shot detection — refresh() is called on app launch,
// on network-mode change, on app activation, and from a manual "Re-detect"
// button in the Connection settings tab.

import Foundation
import Observation

@MainActor
@Observable
final class TailscaleService {

    var hostname: String = ""
    var webSocketURL: String = ""
    var isAvailable: Bool = false
    var lastError: String? = nil

    /// Generation counter — increments on every refresh() call so in-flight
    /// background detections can tell if they've been superseded before
    /// publishing their results.
    private var generation: Int = 0

    /// Hardcoded candidate paths for the Tailscale CLI. Checked in order.
    private static let cliCandidates: [String] = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Default WebSocket port — matches the @AppStorage("wsPort") default used
    /// elsewhere in the app. Read fresh on each refresh().
    private static let defaultPort: Int = 8765

    func refresh() {
        generation += 1
        let myGen = generation

        // Path 1: manual override wins — skip the CLI entirely.
        let override = UserDefaults.standard.string(forKey: "tailscaleHostnameOverride") ?? ""
        let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOverride.isEmpty {
            let port = UserDefaults.standard.integer(forKey: "wsPort")
            publish(
                hostname: trimmedOverride,
                port: port > 0 ? port : Self.defaultPort,
                error: nil,
                generation: myGen
            )
            return
        }

        // Path 2: auto-detect — run the CLI off the main actor.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.detectViaCLI()
            await MainActor.run {
                guard let self else { return }
                // Bail if a newer refresh() has been started.
                guard self.generation == myGen else { return }
                switch result {
                case .success(let detectedHost):
                    let port = UserDefaults.standard.integer(forKey: "wsPort")
                    self.publish(
                        hostname: detectedHost,
                        port: port > 0 ? port : Self.defaultPort,
                        error: nil,
                        generation: myGen
                    )
                case .failure(let message):
                    self.hostname = ""
                    self.webSocketURL = ""
                    self.isAvailable = false
                    self.lastError = message
                }
            }
        }
    }

    func stop() {
        generation += 1
        hostname = ""
        webSocketURL = ""
        isAvailable = false
        lastError = nil
    }

    // MARK: - Private

    private func publish(hostname: String, port: Int, error: String?, generation myGen: Int) {
        guard self.generation == myGen else { return }
        self.hostname = hostname
        self.webSocketURL = "ws://\(hostname):\(port)"
        self.isAvailable = true
        self.lastError = error
    }

    /// Runs on a background task. Locates the CLI, shells out to
    /// `tailscale status --json`, parses the response, returns either a
    /// detected hostname or a human-readable error message.
    private nonisolated static func detectViaCLI() -> Result<String, String> {
        // 1. Locate the CLI.
        let fm = FileManager.default
        let cliPath = cliCandidates.first { path in
            fm.isExecutableFile(atPath: path)
        }
        guard let cli = cliPath else {
            return .failure("Tailscale not installed — install from tailscale.com")
        }

        // 2. Shell out with a 3-second timeout.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["status", "--json"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure("Failed to run Tailscale CLI: \(error.localizedDescription)")
        }

        // Manual 3s timeout — Process has no built-in.
        let deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return .failure("Tailscale CLI timed out — is the daemon running?")
        }

        guard process.terminationStatus == 0 else {
            return .failure("Tailscale not running or not logged in")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return .failure("Tailscale CLI returned no output")
        }

        // 3. Parse JSON and extract the Self node's DNSName or first TailscaleIP.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = json["Self"] as? [String: Any] else {
            return .failure("Could not parse Tailscale status JSON")
        }

        if let dnsName = selfNode["DNSName"] as? String, !dnsName.isEmpty {
            // DNSName includes a trailing dot (e.g. "quip-mac.tail1234.ts.net.") — strip it.
            var trimmed = dnsName
            if trimmed.hasSuffix(".") {
                trimmed.removeLast()
            }
            return .success(trimmed)
        }

        if let ips = selfNode["TailscaleIPs"] as? [String], let first = ips.first, !first.isEmpty {
            return .success(first)
        }

        return .failure("No Tailscale identity found — try logging in")
    }
}
