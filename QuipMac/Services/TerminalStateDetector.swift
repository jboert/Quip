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

    /// Windows where Claude/node processes are currently running (regardless of CPU).
    /// Updated every poll cycle. Used to drive the "thinking" indicator on iOS.
    var windowsWithClaudeProcess: Set<String> = []

    /// CPU threshold below which a process is considered idle
    var cpuIdleThreshold: Double = 5.0

    /// Polling interval in seconds
    var pollingInterval: TimeInterval = 0.25

    private var pollTimer: Timer?

    /// kqueue-based process sources that fire when a child process exits, keyed by
    /// window and PID so an exited source can be located and removed after firing.
    /// Without the pid key, sources for dead children pile up over the app's lifetime
    /// — every claude/node/git helper spawned by a shell leaves a zombie watch behind.
    private var processSources: [String: [pid_t: DispatchSourceProcess]] = [:]

    /// Known child PIDs per window, used to detect new/exited children
    private var knownChildren: [String: Set<pid_t>] = [:]

    // MARK: - Start / Stop Monitoring

    /// Begin periodic polling of tracked terminal windows
    private let pollQueue = DispatchQueue(label: "quip.terminal-state-poll", qos: .utility)

    func startMonitoring() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer fires on the main runloop. Snapshot MainActor state inside
            // assumeIsolated, then do the heavy ps(1) work off main.
            let (tracked, sttWindows, threshold): ([String: pid_t], Set<String>, Double) =
                MainActor.assumeIsolated {
                    let states = self.windowStates
                    let stt = Set(states.filter { $0.value == .sttActive }.keys)
                    return (self.trackedWindows, stt, self.cpuIdleThreshold)
                }
            self.pollQueue.async { [weak self] in
                guard let self else { return }
                var results: [(String, TerminalState)] = []
                var claudePresence: [String: Bool] = [:]
                // Collect child PIDs off main (spawns ps processes)
                var childPidsByWindow: [String: Set<pid_t>] = [:]
                for (windowId, shellPid) in tracked {
                    if sttWindows.contains(windowId) { continue }
                    let (detected, hasClaude) = self.detectState(shellPid: shellPid, cpuThreshold: threshold)
                    results.append((windowId, detected))
                    claudePresence[windowId] = hasClaude
                    if let children = self.getChildProcesses(of: shellPid) {
                        childPidsByWindow[windowId] = Set(children.map(\.pid))
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyPollResults(results)
                    // Update Claude process presence for thinking indicator
                    for (windowId, hasClaude) in claudePresence {
                        if hasClaude {
                            self.windowsWithClaudeProcess.insert(windowId)
                        } else {
                            self.windowsWithClaudeProcess.remove(windowId)
                        }
                    }
                    // Install kqueue watches on main where MainActor state lives
                    for (windowId, currentPids) in childPidsByWindow {
                        let known = self.knownChildren[windowId] ?? []
                        let newPids = currentPids.subtracting(known)
                        self.knownChildren[windowId] = currentPids
                        for pid in newPids {
                            self.installProcessSource(windowId: windowId, pid: pid)
                        }
                    }
                }
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

    /// Resolve an iTerm2 tty (e.g. "ttys009") to its session-leader shell PID.
    /// Used so each iTerm window can be polled against its own process tree
    /// instead of sharing the iTerm app PID (which conflates all sessions
    /// into one big "is any claude busy?" answer). Nil if the tty has no
    /// active processes — typically means the session just closed.
    nonisolated static func shellPidForTTY(_ tty: String) -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-t", tty, "-o", "pid=,ppid=,stat=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }

        // Walk: find the shallowest process on this tty — usually login, then
        // shell. We want the SHELL (zsh/bash/fish) not login, because Claude
        // and friends are descendants of the shell, not login.
        struct Row { let pid: pid_t; let ppid: pid_t; let comm: String }
        var rows: [Row] = []
        for line in out.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4, let p = pid_t(parts[0]), let pp = pid_t(parts[1]) else { continue }
            let comm = parts[3]
            rows.append(Row(pid: p, ppid: pp, comm: comm))
        }
        // Prefer the shell itself (zsh/bash/fish/sh). Fall back to session
        // leader, then any process on the tty — beats returning nil and
        // blindly trusting the app PID.
        let shellNames: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh"]
        if let shell = rows.first(where: { shellNames.contains(($0.comm as NSString).lastPathComponent) }) {
            return shell.pid
        }
        return rows.first?.pid
    }

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

    /// Watch a process for exit events via kqueue; triggers an immediate re-poll.
    /// After the exit fires, the source cancels and removes itself from the map
    /// so stale watches don't accumulate across the many short-lived children a
    /// shell spawns during a Claude session.
    private func installProcessSource(windowId: String, pid: pid_t) {
        // Skip if this PID is already being watched under this window.
        if processSources[windowId]?[pid] != nil { return }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The watched process has exited — cancel and drop the source
                // before handling the event, so we don't leak kqueue entries.
                if let src = self.processSources[windowId]?.removeValue(forKey: pid) {
                    src.cancel()
                }
                self.handleProcessEvent(windowId: windowId)
            }
        }
        source.setCancelHandler {} // prevent crashes on dealloc
        source.resume()
        processSources[windowId, default: [:]][pid] = source
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
            for source in sources.values { source.cancel() }
        }
    }

    private func cancelAllProcessSources() {
        for (_, sources) in processSources {
            for source in sources.values { source.cancel() }
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
    /// Apply poll results on main — only does lightweight state comparisons.
    private func applyPollResults(_ results: [(String, TerminalState)]) {
        for (windowId, detected) in results {
            let currentState = windowStates[windowId] ?? .neutral

            if detected == currentState {
                debounceCount[windowId] = nil
            } else {
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
        }
    }

    private func pollAllWindows() {
        for (windowId, shellPid) in trackedWindows {
            if windowStates[windowId] == .sttActive { continue }
            let (detected, hasClaude) = detectState(shellPid: shellPid, cpuThreshold: cpuIdleThreshold)
            applyPollResults([(windowId, detected)])
            if hasClaude {
                windowsWithClaudeProcess.insert(windowId)
            } else {
                windowsWithClaudeProcess.remove(windowId)
            }
        }
    }

    /// Detect whether a shell's child process (claude/node) is busy or idle.
    /// Returns (state, hasClaudeProcess) — the bool tracks process presence
    /// regardless of CPU for the "thinking" indicator.
    private nonisolated func detectState(shellPid: pid_t, cpuThreshold: Double) -> (TerminalState, Bool) {
        guard let children = getChildProcesses(of: shellPid) else {
            return (.waitingForInput, false)
        }

        let claudeProcesses = children.filter { info in
            let comm = info.command.lowercased()
            return comm.contains("claude") || comm.contains("node")
        }

        if claudeProcesses.isEmpty {
            return (.waitingForInput, false)
        }

        let totalCPU = claudeProcesses.reduce(0.0) { $0 + $1.cpuPercent }

        if totalCPU < cpuThreshold {
            return (.waitingForInput, true)
        } else {
            return (.neutral, true) // busy
        }
    }

    // MARK: - Process Info

    private struct ProcessInfo {
        let pid: pid_t
        let cpuPercent: Double
        let command: String
    }

    /// Get ALL descendant processes of a given PID by walking the process tree.
    /// Uses `ps -ax` to get the full process list, then filters to descendants.
    ///
    /// IMPORTANT: read stdout BEFORE waitUntilExit. On a busy Mac, ps output
    /// often exceeds the pipe buffer (~64KB). Calling waitUntilExit first
    /// deadlocks: ps blocks writing to a full pipe, we block waiting for it
    /// to exit. Reading first drains the pipe until ps closes it at exit,
    /// which unblocks ps and makes waitUntilExit instant. Stderr goes to
    /// /dev/null so we never risk the mirror-image deadlock on errPipe.
    private nonisolated func getChildProcesses(of parentPid: pid_t) -> [ProcessInfo]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "pid,ppid,pcpu,comm"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try task.run()
        } catch {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        // Parse all processes into (pid, ppid, cpu, comm)
        struct RawProc { let pid: pid_t; let ppid: pid_t; let cpu: Double; let comm: String }
        var allProcs: [RawProc] = []
        let lines = output.components(separatedBy: "\n").dropFirst()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            let cpu = Double(parts[2]) ?? 0.0
            let comm = String(parts[3])
            allProcs.append(RawProc(pid: pid, ppid: ppid, cpu: cpu, comm: comm))
        }

        // Walk the tree: find all descendants of parentPid
        var descendantPids: Set<pid_t> = [parentPid]
        var changed = true
        while changed {
            changed = false
            for proc in allProcs {
                if descendantPids.contains(proc.ppid) && !descendantPids.contains(proc.pid) {
                    descendantPids.insert(proc.pid)
                    changed = true
                }
            }
        }
        descendantPids.remove(parentPid)

        return allProcs
            .filter { descendantPids.contains($0.pid) }
            .map { ProcessInfo(pid: $0.pid, cpuPercent: $0.cpu, command: $0.comm) }
    }
}
