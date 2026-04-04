// TerminalStateDetector.swift
// QuipMac — Monitors terminal windows to detect Claude Code state
// Uses process tree inspection to determine if Claude is idle or busy

import Foundation
import Observation

// MARK: - TerminalStateDetector

@MainActor
@Observable
final class TerminalStateDetector {

    /// Maps window IDs to their detected terminal state
    var windowStates: [String: TerminalState] = [:]

    /// Called with (windowId, oldState, newState) when a window's state changes
    var onStateTransition: ((String, TerminalState, TerminalState) -> Void)?

    /// Window IDs currently being tracked, mapped to their shell PIDs
    var trackedWindows: [String: pid_t] = [:]

    /// CPU threshold below which a process is considered idle
    var cpuIdleThreshold: Double = 5.0

    /// Polling interval in seconds
    var pollingInterval: TimeInterval = 0.25

    private var pollTimer: Timer?

    /// kqueue-based process sources that fire when a child process exits or forks
    private var processSources: [String: [DispatchSourceProcess]] = [:]

    /// Known child PIDs per window, used to detect new/exited children
    private var knownChildren: [String: Set<pid_t>] = [:]

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
        cancelAllProcessSources()
        print("[TerminalStateDetector] Stopped monitoring")
    }

    // MARK: - Track / Untrack

    /// Register a terminal window for state detection
    func trackWindow(_ windowId: String, shellPid: pid_t) {
        trackedWindows[windowId] = shellPid
        windowStates[windowId] = .neutral
        knownChildren[windowId] = []
        installProcessSource(windowId: windowId, pid: shellPid)
        print("[TerminalStateDetector] Tracking window \(windowId) with shell PID \(shellPid)")
    }

    /// Remove a window from tracking
    func untrackWindow(_ windowId: String) {
        trackedWindows.removeValue(forKey: windowId)
        windowStates.removeValue(forKey: windowId)
        knownChildren.removeValue(forKey: windowId)
        cancelProcessSources(for: windowId)
    }

    /// Externally set a window to STT active state
    func setSTTActive(for windowId: String) {
        windowStates[windowId] = .sttActive
    }

    /// Clear STT state back to auto-detected
    func clearSTTState(for windowId: String) {
        windowStates[windowId] = .neutral
    }

    // MARK: - kqueue Process Sources

    /// Watch a process for exit events via kqueue; triggers an immediate re-poll
    private func installProcessSource(windowId: String, pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleProcessEvent(windowId: windowId)
            }
        }
        source.setCancelHandler {} // prevent crashes on dealloc
        source.resume()
        processSources[windowId, default: []].append(source)
    }

    /// Called when a watched process exits — re-detect state but DO NOT transition immediately.
    /// The debounce in pollAllWindows will confirm it over the next couple polls.
    private func handleProcessEvent(windowId: String) {
        guard let shellPid = trackedWindows[windowId] else { return }
        refreshChildWatches(windowId: windowId, shellPid: shellPid)
    }

    /// Discover current children and install kqueue watches on any new ones
    private func refreshChildWatches(windowId: String, shellPid: pid_t) {
        guard let children = getChildProcesses(of: shellPid) else { return }
        let currentPids = Set(children.map(\.pid))
        let known = knownChildren[windowId] ?? []
        let newPids = currentPids.subtracting(known)
        knownChildren[windowId] = currentPids

        for pid in newPids {
            installProcessSource(windowId: windowId, pid: pid)
        }
    }

    private func cancelProcessSources(for windowId: String) {
        if let sources = processSources.removeValue(forKey: windowId) {
            for source in sources { source.cancel() }
        }
    }

    private func cancelAllProcessSources() {
        for (_, sources) in processSources {
            for source in sources { source.cancel() }
        }
        processSources.removeAll()
    }

    // MARK: - Polling

    /// Debounce counter: how many consecutive polls have shown the same "candidate" state.
    /// 2 consecutive agreeing polls (~0.5s at 0.25s polling) is enough to avoid most
    /// false transitions while keeping latency low.
    private var debounceCount: [String: (state: TerminalState, count: Int)] = [:]
    private let debounceThreshold = 2

    /// Check all tracked windows' process states
    private func pollAllWindows() {
        for (windowId, shellPid) in trackedWindows {
            if windowStates[windowId] == .sttActive { continue }

            let detected = detectState(shellPid: shellPid)
            let currentState = windowStates[windowId] ?? .neutral

            if detected == currentState {
                // No change — clear debounce
                debounceCount[windowId] = nil
            } else {
                // Different from current — accumulate evidence before transitioning
                let prev = debounceCount[windowId]
                if prev?.state == detected {
                    debounceCount[windowId] = (detected, (prev?.count ?? 0) + 1)
                } else {
                    debounceCount[windowId] = (detected, 1)
                }
                if let entry = debounceCount[windowId], entry.count >= debounceThreshold {
                    windowStates[windowId] = detected
                    debounceCount[windowId] = nil
                    onStateTransition?(windowId, currentState, detected)
                }
            }

            refreshChildWatches(windowId: windowId, shellPid: shellPid)
        }
    }

    /// Detect whether a shell's child process (claude/node) is busy or idle
    private func detectState(shellPid: pid_t) -> TerminalState {
        guard let children = getChildProcesses(of: shellPid) else {
            return .waitingForInput
        }

        let claudeProcesses = children.filter { info in
            let comm = info.command.lowercased()
            return comm.contains("claude") || comm.contains("node")
        }

        if claudeProcesses.isEmpty {
            return .waitingForInput
        }

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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid,pcpu,comm", "-g", "\(parentPid)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var results: [ProcessInfo] = []
        let lines = output.components(separatedBy: "\n").dropFirst()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            guard let pid = pid_t(parts[0]) else { continue }
            guard pid != parentPid else { continue }
            let cpu = Double(parts[1]) ?? 0.0
            let comm = String(parts[2])

            results.append(ProcessInfo(pid: pid, cpuPercent: cpu, command: comm))
        }

        return results
    }
}
