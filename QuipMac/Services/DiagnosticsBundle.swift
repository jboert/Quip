// DiagnosticsBundle.swift
// QuipMac — packages the three log files + a system-info text blob into
// a single zip in NSTemporaryDirectory. Used by both the Settings →
// Diagnostics tab's "Bundle and share…" button and the WS handler that
// answers a phone-side `request_diagnostics`.

import Foundation
import AppKit
import CommonCrypto

enum DiagnosticsBundleError: Error {
    /// `zip` shelled out to /usr/bin/zip with a non-zero exit. Carries the
    /// stderr output for troubleshooting.
    case zipFailed(stderr: String, exitCode: Int32)
    /// Bundle size exceeds the requested cap. Used by the WS path so a
    /// 50 MB log set doesn't try to round-trip over a 16 MiB WebSocket.
    case overSizeCap(actual: Int, cap: Int)
}

enum DiagnosticsBundle {

    /// Build a `Quip-diagnostics-YYYYMMDD-HHMMSS.zip` in
    /// `NSTemporaryDirectory()` containing the three logs from `LogPaths`
    /// plus a `system-info.txt`. Returns the zip URL on success.
    ///
    /// `maxBytes` defaults to nil (no cap). The WS path passes 4 MiB so
    /// the round-trip stays well under the 16 MiB WebSocket payload cap
    /// even after base64 inflation.
    static func makeZip(maxBytes: Int? = nil) throws -> URL {
        let timestamp = filenameTimestamp()
        let filename = "Quip-diagnostics-\(timestamp).zip"
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        let stagingDir = tmpRoot.appendingPathComponent("Quip-diag-\(UUID().uuidString)", isDirectory: true)
        let zipURL = tmpRoot.appendingPathComponent(filename)

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // Copy each existing log into the staging dir. Missing log files
        // are tolerated — the user might never have triggered a push, for
        // instance — so the bundle still has whatever's available.
        // Each log is run through `LogRedactor` first so LAN / Tailscale
        // IPv4s and the host's name don't leave the machine.
        let hostname = Host.current().localizedName ?? ""
        let sources = [LogPaths.webSocketPath, LogPaths.pushPath, LogPaths.kokoroPath]
        for srcPath in sources {
            guard FileManager.default.fileExists(atPath: srcPath) else { continue }
            let srcURL = URL(fileURLWithPath: srcPath)
            let dest = stagingDir.appendingPathComponent(srcURL.lastPathComponent)
            if let raw = try? String(contentsOf: srcURL, encoding: .utf8) {
                let redacted = LogRedactor.redactAll(raw, hostname: hostname)
                try redacted.write(to: dest, atomically: true, encoding: .utf8)
            } else {
                // Binary or non-UTF8 — fall back to a verbatim copy. Logs
                // are append-only UTF-8 in practice, so this branch is for
                // belt-and-suspenders only.
                try FileManager.default.copyItem(at: srcURL, to: dest)
            }
        }

        // System info blob — gives the recipient enough environment
        // context to avoid a "what version are you on?" round-trip.
        // Already hostname-redacted by `systemInfoText()`.
        let info = systemInfoText()
        try info.write(to: stagingDir.appendingPathComponent("system-info.txt"),
                       atomically: true, encoding: .utf8)

        // Use /usr/bin/zip — it's always present, doesn't need an SDK
        // dependency, and produces a Finder-friendly archive. Run from
        // the staging dir so paths inside the zip are relative.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = stagingDir
        process.arguments = ["-r", "-q", zipURL.path, "."]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                   encoding: .utf8) ?? "(no stderr)"
            throw DiagnosticsBundleError.zipFailed(stderr: errOutput, exitCode: process.terminationStatus)
        }

        if let cap = maxBytes,
           let attrs = try? FileManager.default.attributesOfItem(atPath: zipURL.path),
           let size = attrs[.size] as? Int,
           size > cap {
            try? FileManager.default.removeItem(at: zipURL)
            throw DiagnosticsBundleError.overSizeCap(actual: size, cap: cap)
        }

        return zipURL
    }

    /// Compose the system-info.txt body. Pure function so tests can pin it.
    /// The `Host` line ships a stable 8-char hash of the machine name
    /// rather than the name itself — recipients can still correlate two
    /// bundles from the same host, but the user's chosen machine name
    /// stays on their machine.
    static func systemInfoText() -> String {
        let pinfo = ProcessInfo.processInfo
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(unknown)"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "(unknown)"
        let hostHash = stableHostHash(Host.current().localizedName ?? "")

        var lines: [String] = []
        lines.append("Quip Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("App version: \(bundleVersion) (\(buildNumber))")
        lines.append("macOS:       \(pinfo.operatingSystemVersionString)")
        lines.append("Host:        <redacted> (id=\(hostHash))")
        lines.append("Architecture: \(machineArchitecture())")
        lines.append("Uptime:      \(Int(pinfo.systemUptime))s")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 8-char lowercase hex of a salted SHA-256 over the host name. Stable
    /// for a given host across runs (not random per call), but doesn't
    /// reveal the name itself. Empty input returns "anon".
    static func stableHostHash(_ host: String) -> String {
        guard !host.isEmpty else { return "anon" }
        let salted = "quip-diag-v1:" + host
        let data = Data(salted.utf8)
        var hash: [UInt8] = Array(repeating: 0, count: 32)
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Filesystem-safe timestamp (YYYYMMDD-HHMMSS) for the zip filename.
    private static func filenameTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func machineArchitecture() -> String {
        var size: size_t = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// Open NSSharingServicePicker on the zip, anchored to the given view.
    /// Used by the Settings tab's "Bundle and share…" button. macOS-only.
    @MainActor
    static func presentSharePicker(zipURL: URL, anchor: NSView?) {
        let picker = NSSharingServicePicker(items: [zipURL])
        if let anchor {
            picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        } else if let window = NSApp.keyWindow,
                  let contentView = window.contentView {
            picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
        }
    }
}
