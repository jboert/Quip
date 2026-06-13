// TerminalStateDetector.swift
// QuipMac — Monitors terminal windows to detect Claude Code state
// Uses process tree inspection to determine if Claude is idle or busy

import Foundation
import Observation

/// Append one structured line per on-demand CLI classification to
/// `classify.log`. Append-only, failures swallowed — a logger must never crash
/// the detector. Companion to latency.log: latency records what we *did* with
/// the routed input, this records *why* a given CLIKind was chosen.
fileprivate func appendClassifyLog(_ message: String) {
    let line = "\(Date().ISO8601Format()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = LogPaths.classifyPath
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

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

    /// Per-window TTY (iTerm2 only) — kept alongside `trackedWindows` so the
    /// detector can re-resolve a stale shell PID after a session respawn.
    /// iTerm2's TTY (e.g. `/dev/ttys013`) is stable across `exit` + new shell
    /// in the same session; the shell PID is not. Without this, a respawned
    /// shell leaves Quip polling descendants of a dead PID, classifier
    /// returns `.shell`, and codex pastes silently fall back to the legacy
    /// PTY-write branch (which Codex's composer drops on the floor).
    var trackedTty: [String: String] = [:]

    /// Windows where Claude/node processes are currently running (regardless of CPU).
    /// Updated every poll cycle. Used to drive the "thinking" indicator on iOS.
    var windowsWithClaudeProcess: Set<String> = []

    /// Per-window CLI kind, derived from process-tree sniffing in `detectState`.
    /// Drives per-CLI input routing on the Mac side (notably image_upload —
    /// Codex CLI's interactive composer takes pasted image bytes via Cmd+V,
    /// Claude Code accepts an absolute path typed inline). (GH I.)
    var windowCLIKind: [String: CLIKind] = [:]

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
            let (tracked, ttys, sttWindows, threshold): ([String: pid_t], [String: String], Set<String>, Double) =
                MainActor.assumeIsolated {
                    let states = self.windowStates
                    let stt = Set(states.filter { $0.value == .sttActive }.keys)
                    return (self.trackedWindows, self.trackedTty, stt, self.cpuIdleThreshold)
                }
            self.pollQueue.async { [weak self] in
                guard let self else { return }
                var results: [(String, TerminalState)] = []
                var claudePresence: [String: Bool] = [:]
                var cliByWindow: [String: CLIKind] = [:]
                // PID re-resolutions when the cached shell PID has died but the
                // iTerm2 TTY still hosts a live shell. Applied on main below.
                var pidUpdates: [String: pid_t] = [:]
                // Collect child PIDs off main (spawns ps processes)
                var childPidsByWindow: [String: Set<pid_t>] = [:]
                let processSnapshot = Self.captureProcessSnapshot()
                for (windowId, shellPid) in tracked {
                    if sttWindows.contains(windowId) { continue }
                    let (detected, hasClaude, cli, resolvedPid, children) = self.detectState(
                        shellPid: shellPid,
                        tty: ttys[windowId],
                        cpuThreshold: threshold,
                        snapshot: processSnapshot
                    )
                    results.append((windowId, detected))
                    claudePresence[windowId] = hasClaude
                    cliByWindow[windowId] = cli
                    if let resolvedPid { pidUpdates[windowId] = resolvedPid }
                    childPidsByWindow[windowId] = Set(children.map(\.pid))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Apply re-resolved shell PIDs FIRST so kqueue installs
                    // below watch the live shell, not the dead one.
                    for (windowId, newPid) in pidUpdates {
                        let oldPid = self.trackedWindows[windowId] ?? 0
                        self.trackedWindows[windowId] = newPid
                        NSLog("[TerminalStateDetector] Re-resolved shell PID for window %@: %d -> %d (TTY respawn)", windowId, oldPid, newPid)
                        self.installProcessSource(windowId: windowId, pid: newPid)
                    }
                    self.applyPollResults(results)
                    // Update Claude process presence for thinking indicator
                    for (windowId, hasClaude) in claudePresence {
                        if hasClaude {
                            self.windowsWithClaudeProcess.insert(windowId)
                        } else {
                            self.windowsWithClaudeProcess.remove(windowId)
                        }
                    }
                    // GH I — track per-window CLI kind so image_upload can
                    // route to the right paste path.
                    for (windowId, cli) in cliByWindow {
                        self.windowCLIKind[windowId] = cli
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

    /// Register a terminal window for state detection.
    /// `tty` is iTerm2's pseudo-terminal device path; pass it whenever the
    /// caller has it so the poll loop can re-resolve a stale shell PID after
    /// a session respawn (see `trackedTty` for the why).
    func trackWindow(_ windowId: String, shellPid: pid_t, tty: String? = nil) {
        trackedWindows[windowId] = shellPid
        if let tty, !tty.isEmpty {
            trackedTty[windowId] = tty
        } else {
            trackedTty.removeValue(forKey: windowId)
        }
        windowStates[windowId] = .neutral
        knownChildren[windowId] = []
        installProcessSource(windowId: windowId, pid: shellPid)
        print("[TerminalStateDetector] Tracking window \(windowId) with shell PID \(shellPid) tty=\(tty ?? "<none>")")
    }

    /// Remove a window from tracking
    func untrackWindow(_ windowId: String) {
        trackedWindows.removeValue(forKey: windowId)
        trackedTty.removeValue(forKey: windowId)
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
        let processSnapshot = Self.captureProcessSnapshot()
        for (windowId, shellPid) in trackedWindows {
            if windowStates[windowId] == .sttActive { continue }
            let (detected, hasClaude, cli, resolvedPid, _) = detectState(
                shellPid: shellPid,
                tty: trackedTty[windowId],
                cpuThreshold: cpuIdleThreshold,
                snapshot: processSnapshot
            )
            if let resolvedPid {
                trackedWindows[windowId] = resolvedPid
                installProcessSource(windowId: windowId, pid: resolvedPid)
            }
            applyPollResults([(windowId, detected)])
            if hasClaude {
                windowsWithClaudeProcess.insert(windowId)
            } else {
                windowsWithClaudeProcess.remove(windowId)
            }
            windowCLIKind[windowId] = cli
        }
    }

    /// Synchronous one-window refresh for command handlers that are about to
    /// route input. The periodic poll loop normally keeps `windowCLIKind`
    /// fresh, but image upload needs a just-in-time answer because Codex uses
    /// a different injection path than Claude/shell and stale classification
    /// turns into a saved-but-not-attached image.
    func refreshCLIKind(for windowId: String) -> CLIKind {
        guard let shellPid = trackedWindows[windowId] else {
            return windowCLIKind[windowId] ?? .shell
        }

        if windowStates[windowId] == .sttActive {
            return windowCLIKind[windowId] ?? .shell
        }

        let processSnapshot = Self.captureProcessSnapshot()
        let (detected, hasClaude, cli, resolvedPid, children) = detectState(
            shellPid: shellPid,
            tty: trackedTty[windowId],
            cpuThreshold: cpuIdleThreshold,
            snapshot: processSnapshot
        )
        if let resolvedPid {
            let oldPid = trackedWindows[windowId] ?? 0
            trackedWindows[windowId] = resolvedPid
            NSLog("[TerminalStateDetector] Re-resolved shell PID for window %@: %d -> %d (on-demand)", windowId, oldPid, resolvedPid)
            installProcessSource(windowId: windowId, pid: resolvedPid)
        }
        applyPollResults([(windowId, detected)])
        if hasClaude {
            windowsWithClaudeProcess.insert(windowId)
        } else {
            windowsWithClaudeProcess.remove(windowId)
        }
        let prevCli = windowCLIKind[windowId]
        windowCLIKind[windowId] = cli

        // Durable breadcrumb for "voice/image landed nowhere": record the
        // chosen kind, the kind we'd have used off the stale poll cache, the
        // resolved shell PID, and the raw `comm` list the classifier matched
        // against. When PTT into a Codex/Grok pane silently drops, this line
        // tells us which layer failed (classifier vs PID-tracking vs inject).
        let comms = children.map { $0.command }.joined(separator: "|")
        appendClassifyLog("refresh window=\(windowId) chosen=\(cli.rawValue) cached=\(prevCli?.rawValue ?? "none") pid=\(resolvedPid ?? shellPid) children=\(children.count) comms=[\(comms)]")

        let currentPids = Set(children.map(\.pid))
        let known = knownChildren[windowId] ?? []
        knownChildren[windowId] = currentPids
        for pid in currentPids.subtracting(known) {
            installProcessSource(windowId: windowId, pid: pid)
        }

        return cli
    }

    /// Detect whether a shell's child process (claude/codex/node) is busy or idle.
    /// Returns (state, hasAIProcess, cliKind, resolvedPid):
    /// - state, hasAIProcess, cliKind: same as before
    /// - resolvedPid: non-nil when the cached shell PID had no descendants
    ///   (likely dead / respawned) AND the supplied iTerm2 TTY now points
    ///   to a different live shell. Caller writes it back into
    ///   `trackedWindows` so the next poll watches the live shell.
    /// - children: descendant processes used for this decision, returned so
    ///   the poll loop can install kqueue watches without running ps again.
    private nonisolated func detectState(
        shellPid: pid_t,
        tty: String?,
        cpuThreshold: Double,
        snapshot: ProcessSnapshot? = nil
    ) -> (TerminalState, Bool, CLIKind, pid_t?, [ProcessInfo]) {
        var resolvedPid: pid_t? = nil
        var children = childProcesses(of: shellPid, snapshot: snapshot)

        // Empty descendants for an iTerm2 window with a known TTY usually
        // means the original shell has exited and a new shell now owns the
        // session. Re-resolve via the stable TTY and try once more.
        if children.isEmpty, let tty, !tty.isEmpty,
           let liveShell = Self.shellPidForTTY(tty), liveShell != shellPid {
            resolvedPid = liveShell
            children = childProcesses(of: liveShell, snapshot: snapshot)
        }

        let cliKind = Self.classifyCLI(children: children)
        let aiProcesses = children.filter { Self.isAIProcess(comm: $0.command.lowercased()) }

        if aiProcesses.isEmpty {
            return (.waitingForInput, false, cliKind, resolvedPid, children)
        }

        let totalCPU = aiProcesses.reduce(0.0) { $0 + $1.cpuPercent }
        let state: TerminalState = totalCPU < cpuThreshold ? .waitingForInput : .neutral
        return (state, true, cliKind, resolvedPid, children)
    }

    /// Classify which AI CLI (if any) is the dominant process running in
    /// this shell. Order matters: explicit agent matches win over
    /// `claude`/`node` because several agent CLIs may run under Node.
    /// Pure function so tests can drive every combination without spawning
    /// real processes. (GH I.)
    nonisolated static func classifyCLI(children: [ProcessInfo]) -> CLIKind {
        let comms = children.map { $0.command.lowercased() }
        if comms.contains(where: { $0.contains("codex") }) { return .codex }
        if comms.contains(where: { $0.contains("grok") }) { return .grok }
        // cursor-agent before the node→claude fallback: Cursor's CLI may run
        // under node, and the specific match must win (mirrors codex). (§7.4)
        if comms.contains(where: { $0.contains("cursor-agent") }) { return .cursor }
        if comms.contains(where: { $0.contains("claude") || $0.contains("node") }) { return .claude }
        return .shell
    }

    /// Is this process name part of the AI-CLI family we treat as
    /// "thinking-eligible" for the busy/idle indicator? Currently
    /// matches the same set as before plus codex.
    nonisolated static func isAIProcess(comm: String) -> Bool {
        comm.contains("claude") || comm.contains("node") || comm.contains("codex")
            || comm.contains("grok") || comm.contains("cursor-agent")
    }

    // MARK: - Process Info

    /// Internal so static helpers like `classifyCLI(children:)` can be
    /// driven by unit tests without needing to spawn real processes.
    struct ProcessInfo {
        let pid: pid_t
        let cpuPercent: Double
        let command: String
    }

    private struct RawProcess {
        let pid: pid_t
        let cpu: Double
        let command: String
    }

    private struct ProcessSnapshot {
        let childrenByParent: [pid_t: [RawProcess]]
        let processByPid: [pid_t: RawProcess]

        func childProcesses(of parentPid: pid_t) -> [ProcessInfo] {
            var descendants: Set<pid_t> = []
            var queue = childrenByParent[parentPid] ?? []
            var index = 0

            while index < queue.count {
                let proc = queue[index]
                index += 1
                guard descendants.insert(proc.pid).inserted else { continue }
                queue.append(contentsOf: childrenByParent[proc.pid] ?? [])
            }

            return descendants.compactMap { pid -> ProcessInfo? in
                guard let proc = processByPid[pid] else { return nil }
                return ProcessInfo(pid: proc.pid, cpuPercent: proc.cpu, command: proc.command)
            }
        }
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
        Self.captureProcessSnapshot()?.childProcesses(of: parentPid)
    }

    private nonisolated func childProcesses(of parentPid: pid_t, snapshot: ProcessSnapshot?) -> [ProcessInfo] {
        if let snapshot {
            return snapshot.childProcesses(of: parentPid)
        }
        return getChildProcesses(of: parentPid) ?? []
    }

    private nonisolated static func captureProcessSnapshot() -> ProcessSnapshot? {
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
        var childrenByParent: [pid_t: [RawProcess]] = [:]
        var processByPid: [pid_t: RawProcess] = [:]
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
            let proc = RawProcess(pid: pid, cpu: cpu, command: comm)
            childrenByParent[ppid, default: []].append(proc)
            processByPid[pid] = proc
        }

        return ProcessSnapshot(childrenByParent: childrenByParent, processByPid: processByPid)
    }
}
