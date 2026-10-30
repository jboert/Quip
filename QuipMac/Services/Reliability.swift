import Foundation

/// Q-90 pure decisions for keeping Quip running. No FS, no launchctl, no UI:
/// the Mac app wiring (heartbeat writer, launch hand-off, Reliability settings,
/// agent install) connects these once the owner is at the Mac for the rebuild.

/// Who should own this launch of Quip.
enum LaunchOwnership: Equatable {
    /// Keep running in this process.
    case run
    /// Exit and let the installed agent launch Quip, so launchd owns the
    /// process and can restart it.
    case handOff

    /// Hands off only when the agent is installed and this launch did not come
    /// from it. Without an agent there is nobody to hand off to; a launch that
    /// already came from the agent is the one launchd watches.
    static func decide(agentInstalled: Bool, launchedByAgent: Bool) -> LaunchOwnership {
        agentInstalled && !launchedByAgent ? .handOff : .run
    }
}

/// Settings → General → Reliability mapped to the agents to install.
enum ReliabilitySettings {
    /// - Parameters:
    ///   - keepRunning: "Keep Quip running", the master switch. Off installs nothing.
    ///   - afterQuit: "Restart after Quit" — `KeepAlive` true instead of crash-only.
    ///   - frozen: "Restart a frozen Quip" — the hang watchdog.
    static func agents(
        keepRunning: Bool,
        afterQuit: Bool,
        frozen: Bool
    ) -> (crashAgent: Bool, keepAliveAlways: Bool, watchdog: Bool) {
        (
            crashAgent: keepRunning,
            keepAliveAlways: keepRunning && afterQuit,
            watchdog: keepRunning && frozen
        )
    }
}

/// Builds the `reliability_status` message the phone keeps per Mac.
enum ReliabilityStatus {
    /// `watching` is true only when the agent is loaded and its pid is this
    /// Quip: a Quip the owner launched by hand while the agent runs another
    /// copy (or none) is not the one launchd will bring back.
    static func build(
        agentLoaded: Bool,
        agentPid: Int?,
        quipPid: Int,
        afterQuit: Bool,
        watchdog: Bool,
        lastRestart: ReliabilityStatusMessage.LastRestart?
    ) -> ReliabilityStatusMessage {
        ReliabilityStatusMessage(
            watching: agentLoaded && agentPid == quipPid,
            afterQuit: afterQuit,
            watchdog: watchdog,
            lastRestart: lastRestart
        )
    }
}

/// Per-user LaunchAgent that runs `quip-watchdog.sh` every 30 s.
enum WatchdogAgent {
    static let label = "com.quip.QuipMac.watchdog"

    static func plistContent(scriptPath: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": ["/bin/sh", scriptPath],
            "StartInterval": 30,
            "RunAtLoad": true,
        ]
    }
}
