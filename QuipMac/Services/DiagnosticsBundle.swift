// DiagnosticsBundle.swift
// QuipMac — packages the three log files + a system-info text blob into
// a single zip in NSTemporaryDirectory. Used by both the Settings →
// Diagnostics tab's "Bundle and share…" button and the WS handler that
// answers a phone-side `request_diagnostics`.

import Foundation
import AppKit

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
        let sources = [LogPaths.webSocketPath, LogPaths.pushPath, LogPaths.kokoroPath]
        for srcPath in sources {
            guard FileManager.default.fileExists(atPath: srcPath) else { continue }
            let srcURL = URL(fileURLWithPath: srcPath)
            let dest = stagingDir.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: dest)
        }

        // System info blob — gives the recipient enough environment
        // context to avoid a "what version are you on?" round-trip.
        // TODO: redact tunnel URLs / device tokens before share.
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
    static func systemInfoText() -> String {
        let pinfo = ProcessInfo.processInfo
        let host = Host.current().localizedName ?? "(unknown)"
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(unknown)"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "(unknown)"

        var lines: [String] = []
        lines.append("Quip Diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("App version: \(bundleVersion) (\(buildNumber))")
        lines.append("macOS:       \(pinfo.operatingSystemVersionString)")
        lines.append("Host:        \(host)")
        lines.append("Architecture: \(machineArchitecture())")
        lines.append("Uptime:      \(Int(pinfo.systemUptime))s")
        return lines.joined(separator: "\n") + "\n"
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
