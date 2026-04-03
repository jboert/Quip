// TerminalStateDetector.swift
// VoiceCodeMac — Monitors terminal windows to detect Claude Code state
// Uses process tree inspection to determine if Claude is idle or busy

import Foundation
import Observation

// MARK: - TerminalStateDetector

@MainActor
@Observable
final class TerminalStateDetector {

    /// Maps window IDs to their detected terminal state
    var windowStates: [String: TerminalState] = [:]

    /// Window IDs currently being tracked, mapped to their shell PIDs
    var trackedWindows: [String: pid_t] = [:]

    /// CPU threshold below which a process is considered idle
    var cpuIdleThreshold: Double = 5.0

    /// Polling interval in seconds
    var pollingInterval: TimeInterval = 2.0

    private var pollTimer: Timer?

    // MARK: - Start / Stop Monitoring

    /// Begin periodic polling of tracked terminal windows
    func startMonitoring() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAllWindows()
            }
        }
        print("[TerminalStateDetector] Started monitoring (interval: \(pollingInterval)s)")
    }

    /// Stop monitoring
    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        print("[TerminalStateDetector] Stopped monitoring")
    }

    // MARK: - Track / Untrack

    /// Register a terminal window for state detection
    /// - Parameters:
    ///   - windowId: The VoiceCode window identifier
    ///   - shellPid: The PID of the shell process in that terminal window
    func trackWindow(_ windowId: String, shellPid: pid_t) {
        trackedWindows[windowId] = shellPid
        windowStates[windowId] = .neutral
        print("[TerminalStateDetector] Tracking window \(windowId) with shell PID \(shellPid)")
    }

    /// Remove a window from tracking
    func untrackWindow(_ windowId: String) {
        trackedWindows.removeValue(forKey: windowId)
        windowStates.removeValue(forKey: windowId)
    }

    /// Externally set a window to STT active state
    func setSTTActive(for windowId: String) {
        windowStates[windowId] = .sttActive
    }

    /// Clear STT state back to auto-detected
    func clearSTTState(for windowId: String) {
        // Will be updated on next poll
        windowStates[windowId] = .neutral
    }

    // MARK: - Polling

    /// Check all tracked windows' process states
    private func pollAllWindows() {
        for (windowId, shellPid) in trackedWindows {
            // Don't override externally-set STT state
            if windowStates[windowId] == .sttActive { continue }

            let state = detectState(shellPid: shellPid)
            windowStates[windowId] = state
        }
    }

    /// Detect whether a shell's child process (claude/node) is busy or idle
    private func detectState(shellPid: pid_t) -> TerminalState {
        // Find child processes of the shell
        guard let children = getChildProcesses(of: shellPid) else {
            return .waitingForInput
        }

        // Look for claude or node processes among children
        let claudeProcesses = children.filter { info in
            let comm = info.command.lowercased()
            return comm.contains("claude") || comm.contains("node")
        }

        if claudeProcesses.isEmpty {
            // No Claude process running -> waiting for input (shell prompt)
            return .waitingForInput
        }

        // Check CPU usage of Claude processes
        let totalCPU = claudeProcesses.reduce(0.0) { $0 + $1.cpuPercent }

        if totalCPU < cpuIdleThreshold {
            return .waitingForInput
        } else {
            return .neutral // busy
        }
    }

    // MARK: - Process Info

    private struct ProcessInfo {
        let pid: pid_t
        let cpuPercent: Double
        let command: String
    }

    /// Get child processes of a given PID using `ps`
    private func getChildProcesses(of parentPid: pid_t) -> [ProcessInfo]? {
        // Get all processes whose parent is parentPid
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid,pcpu,comm", "-g", "\(parentPid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // suppress stderr

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var results: [ProcessInfo] = []
        let lines = output.components(separatedBy: "\n").dropFirst() // skip header

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            guard let pid = pid_t(parts[0]) else { continue }
            guard pid != parentPid else { continue } // exclude the parent itself
            let cpu = Double(parts[1]) ?? 0.0
            let comm = String(parts[2])

            results.append(ProcessInfo(pid: pid, cpuPercent: cpu, command: comm))
        }

        return results
    }
}
