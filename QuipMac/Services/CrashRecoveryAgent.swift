import Foundation
import OSLog

/// Per-user LaunchAgent that auto-relaunches QuipMac after a crash.
///
/// Opt-in via Settings → Reliability → "Auto-restart on crash". Plist lives at
/// `~/Library/LaunchAgents/com.quip.QuipMac.crash-recovery.plist`. Restart is
/// gated on `KeepAlive.Crashed=true` + `SuccessfulExit=false` so a normal Cmd+Q
/// or `quit` AppleScript doesn't trigger a relaunch loop. ThrottleInterval=30
/// is the crash-loop guard.
enum CrashRecoveryAgent {
    static let label = "com.quip.QuipMac.crash-recovery"

    private static let logger = Logger(subsystem: "com.quip.mac", category: "CrashRecoveryAgent")

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Pure: build the plist payload as a serializable dict. No FS, no launchctl.
    /// Stable for round-trip + assertion in tests.
    static func plistContent(executablePath: String) -> [String: Any] {
        let keepAlive: [String: Any] = [
            "SuccessfulExit": false,
            "Crashed": true,
        ]
        return [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": keepAlive,
            "ThrottleInterval": 30,
            "ProcessType": "Interactive",
        ]
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Writes the plist + bootstraps it into the user's launchd domain.
    /// Idempotent: bootout-then-bootstrap so re-toggling picks up a moved app.
    static func install() throws {
        guard let exec = Bundle.main.executablePath else {
            throw CrashRecoveryError.cannotResolveExecutablePath
        }
        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dict = plistContent(executablePath: exec)
        let data = try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)

        // Best-effort bootout of any prior version. Non-zero exit is fine — means
        // it wasn't loaded yet.
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])

        logger.notice("CrashRecoveryAgent installed for \(exec, privacy: .public)")
    }

    /// Boots out the agent and removes the plist. Idempotent.
    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            _ = try? runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            try FileManager.default.removeItem(at: plistURL)
            logger.notice("CrashRecoveryAgent uninstalled")
        }
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = nil
        task.standardError = nil
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}

enum CrashRecoveryError: Error, LocalizedError {
    case cannotResolveExecutablePath

    var errorDescription: String? {
        switch self {
        case .cannotResolveExecutablePath:
            return "Cannot resolve the running app's executable path."
        }
    }
}
