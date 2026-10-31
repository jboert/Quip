import AppKit
import Foundation
import OSLog

/// Q-90 wiring: the pure decisions in Reliability.swift applied to this Mac.
/// launchd owns the running Quip, a heartbeat feeds the watchdog
/// (QuipMac/Resources/quip-watchdog.sh), and the phone hears whether Quip
/// will come back on its own.

/// Files shared with quip-watchdog.sh; the names must match the script.
enum ReliabilityFiles {
    static var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quip")
    }
    static var heartbeat: URL { stateDir.appendingPathComponent("heartbeat") }
    static var manualLaunch: URL { stateDir.appendingPathComponent("manual-launch") }
    static var exit: URL { stateDir.appendingPathComponent("exit") }
    static var crashLoopMarker: URL { stateDir.appendingPathComponent("stoppedForCrashLoop") }
    static var restarts: URL { stateDir.appendingPathComponent("restarts.json") }

    /// Best effort: a missed write is one stale check for the watchdog, which
    /// needs two in a row before it acts.
    static func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    static var epochNow: String { "\(Int(Date().timeIntervalSince1970))\n" }
}

/// Settings → General → Reliability. All on by default, so an existing
/// install that never saw these switches is protected too (spec §5).
enum ReliabilityPrefs {
    static let keepRunningKey = "reliability.keepRunning"
    static let afterQuitKey = "reliability.afterQuit"
    static let frozenKey = "reliability.frozen"

    static func isOn(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func agents(in defaults: UserDefaults = .standard)
        -> (crashAgent: Bool, keepAliveAlways: Bool, watchdog: Bool) {
        ReliabilitySettings.agents(
            keepRunning: isOn(keepRunningKey, in: defaults),
            afterQuit: isOn(afterQuitKey, in: defaults),
            frozen: isOn(frozenKey, in: defaults))
    }
}

enum ReliabilityAgents {
    private static let logger = Logger(subsystem: "com.quip.mac", category: "Reliability")

    static var watchdogPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(WatchdogAgent.label).plist")
    }

    /// Only the installed app manages agents: a build run from Xcode or
    /// DerivedData must never point launchd at itself.
    static var isInstallLocation: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// launchd names the job it started in XPC_SERVICE_NAME; a Finder or
    /// `open` launch reads `application.com.quip.mac.…`.
    static var launchedByAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == CrashRecoveryAgent.label
    }

    static var domain: String { "gui/\(getuid())" }

    /// Pure: the plist bytes each agent should have on disk; nil = not
    /// installed.
    static func desired(
        agents: (crashAgent: Bool, keepAliveAlways: Bool, watchdog: Bool),
        executablePath: String,
        scriptPath: String?
    ) -> (crash: Data?, watchdog: Data?) {
        func encode(_ dict: [String: Any]) -> Data? {
            try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        }
        let crash = agents.crashAgent
            ? encode(CrashRecoveryAgent.plistContent(executablePath: executablePath,
                                                    keepAliveAlways: agents.keepAliveAlways))
            : nil
        let watchdog = agents.watchdog
            ? scriptPath.flatMap { encode(WatchdogAgent.plistContent(scriptPath: $0)) }
            : nil
        return (crash, watchdog)
    }

    /// Brings both agents in line with the settings. Returns true when this
    /// Quip is the crash agent's own copy and has asked launchd to replace it
    /// (a changed KeepAlive needs a reload, and a reload ends the old copy).
    @discardableResult
    static func sync() -> Bool {
        guard isInstallLocation, let exec = Bundle.main.executablePath else { return false }
        let want = desired(agents: ReliabilityPrefs.agents(), executablePath: exec,
                           scriptPath: Bundle.main.path(forResource: "quip-watchdog", ofType: "sh"))
        apply(want.watchdog, url: watchdogPlistURL, label: WatchdogAgent.label, ownJob: false)
        return apply(want.crash, url: CrashRecoveryAgent.plistURL, label: CrashRecoveryAgent.label,
                     ownJob: launchedByAgent)
    }

    @discardableResult
    private static func apply(_ data: Data?, url: URL, label: String, ownJob: Bool) -> Bool {
        let service = "\(domain)/\(label)"
        let current = try? Data(contentsOf: url)
        guard let data else {
            guard current != nil else { return false }
            try? FileManager.default.removeItem(at: url)
            logger.notice("\(label, privacy: .public) removed")
            if ownJob {
                // Booting out our own job ends this copy; a plain `open`
                // brings Quip back unsupervised, as the owner asked.
                return spawnDetached("launchctl bootout \(service); sleep 1; open \(shellQuote(Bundle.main.bundlePath))")
            }
            launchctl(["bootout", service])
            return false
        }
        if current == data {
            // Loaded already (the usual case) or booted out by a crash-loop
            // stop or Stop Quip…: bootstrap is a no-op for the former.
            launchctl(["bootstrap", domain, url.path])
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("\(label, privacy: .public) not written: \(error.localizedDescription, privacy: .public)")
            return false
        }
        logger.notice("\(label, privacy: .public) written")
        if ownJob {
            return spawnDetached("launchctl bootout \(service); launchctl bootstrap \(domain) \(shellQuote(url.path))")
        }
        launchctl(["bootout", service])
        launchctl(["bootstrap", domain, url.path])
        return false
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        run("/bin/launchctl", args).status
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Runs `script` in its own session, so it outlives this process when
    /// launchd ends the job's process group (a bootout of our own job).
    static func spawnDetached(_ script: String) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid = pid_t()
        let rc = posix_spawn(&pid, "/bin/sh", nil, &attr, argv, environ)
        if rc != 0 { logger.error("detached launchctl failed rc=\(rc)") }
        return rc == 0
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ReliabilityLaunch {
    /// Before the instance lock. True when this copy handed the launch to
    /// the crash agent and must exit 0; false to keep running (also when the
    /// hand-off fails: fail open, like the lock).
    static func handOffIfNeeded() -> Bool {
        guard ReliabilityAgents.isInstallLocation else { return false }
        let byAgent = ReliabilityAgents.launchedByAgent
        if !byAgent {
            // The owner opened Quip: earlier restarts no longer count toward
            // a crash loop, and a crash-loop stop is lifted (and explained
            // once, by the copy that runs).
            ReliabilityFiles.write(ReliabilityFiles.epochNow, to: ReliabilityFiles.manualLaunch)
            if FileManager.default.fileExists(atPath: ReliabilityFiles.crashLoopMarker.path) {
                try? FileManager.default.removeItem(at: ReliabilityFiles.crashLoopMarker)
                UserDefaults.standard.set(true, forKey: ReliabilityCrashLoopNotice.pendingKey)
            }
        }
        if ReliabilityAgents.sync() {
            log(.info, "agent settings changed; launchd is replacing this copy")
            return false
        }
        guard LaunchOwnership.decide(agentInstalled: CrashRecoveryAgent.isInstalled,
                                     launchedByAgent: byAgent) == .handOff else { return false }
        let status = ReliabilityAgents.launchctl(
            ["kickstart", "\(ReliabilityAgents.domain)/\(CrashRecoveryAgent.label)"])
        guard status == 0 else {
            log(.warn, "hand-off to launchd failed (kickstart status \(status)); running unsupervised")
            return false
        }
        log(.info, "handed this launch to launchd (\(CrashRecoveryAgent.label)); quitting this copy")
        return true
    }

    private static func log(_ severity: QuipLog.Severity, _ message: String) {
        QuipLog.write(severity: severity, subsystem: "launch", message: message, to: LogPaths.webSocketPath)
    }
}

/// Writes the heartbeat the watchdog reads, from the main actor: a Quip
/// whose main thread is stuck stops writing, which is the point.
@MainActor
final class QuipHeartbeat {
    static let shared = QuipHeartbeat()
    static let interval: TimeInterval = 10

    /// When this Quip started serving: a restart newer than this (less a
    /// margin) is the one that started it.
    private(set) var startedAt = Date()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        // A menu-bar app with no window can be napped, which stretches
        // timers: a healthy Quip would look hung.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Quip serves the phone")
        beat()
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { QuipHeartbeat.shared.beat() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A quit through the app is not a crash: tell the watchdog which pid left.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            ReliabilityFiles.write("pid=\(getpid())\n", to: ReliabilityFiles.exit)
        }
    }

    func beat() {
        ReliabilityFiles.write(ReliabilityFiles.epochNow, to: ReliabilityFiles.heartbeat)
    }
}

/// Menu bar Quit / Stop Quip….
enum ReliabilityStop {
    /// With "Restart after Quit" on, a plain quit would come straight back,
    /// so the menu stops the agent on purpose instead.
    static var stopsAgent: Bool {
        ReliabilityPrefs.agents().keepAliveAlways && CrashRecoveryAgent.isInstalled
    }

    static var menuTitle: String { stopsAgent ? "Stop Quip…" : "Quit" }

    @MainActor
    static func quitOrStop() {
        guard stopsAgent else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Stop Quip?"
        alert.informativeText = "Quip won't restart until you open it again or log in. Your phone can't reach this Mac until then."
        alert.addButton(withTitle: "Stop Quip")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NotificationCenter.default.post(name: .quipStopping, object: nil)
        // Give the "stopped" status a moment to leave before the socket goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let service = "\(ReliabilityAgents.domain)/\(CrashRecoveryAgent.label)"
            if ReliabilityAgents.launchedByAgent {
                // Our own job: the bootout must outlive this process.
                _ = ReliabilityAgents.spawnDetached("launchctl bootout \(service)")
            } else {
                ReliabilityAgents.launchctl(["bootout", service])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }
}

/// The `reliability_status` this Mac sends the phone.
enum ReliabilityReport {
    /// Runs launchctl: call off the main thread.
    static func current(launchedAt: Date) -> ReliabilityStatusMessage {
        let agents = ReliabilityPrefs.agents()
        let print = ReliabilityAgents.run(
            "/bin/launchctl", ["print", "\(ReliabilityAgents.domain)/\(CrashRecoveryAgent.label)"])
        return ReliabilityStatus.build(
            agentLoaded: print.status == 0,
            agentPid: print.status == 0 ? agentPid(launchctlPrint: print.output) : nil,
            quipPid: Int(getpid()),
            afterQuit: agents.keepAliveAlways,
            watchdog: agents.watchdog,
            lastRestart: lastRestart(restartsJSON: try? Data(contentsOf: ReliabilityFiles.restarts),
                                     since: launchedAt.addingTimeInterval(-120)))
    }

    /// Pure: the job's `pid = N` line in `launchctl print`; nil when not running.
    static func agentPid(launchctlPrint: String) -> Int? {
        for line in launchctlPrint.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = "), let pid = Int(t.dropFirst("pid = ".count)) { return pid }
        }
        return nil
    }

    /// Pure: the newest restart at or after `since` (the one that started
    /// this Quip), so a phone that pairs days later hears nothing old.
    static func lastRestart(restartsJSON: Data?, since: Date) -> ReliabilityStatusMessage.LastRestart? {
        struct Entry: Decodable { let at: Double; let reason: String }
        guard let data = restartsJSON,
              let entries = try? JSONDecoder().decode([Entry].self, from: data),
              let newest = entries.max(by: { $0.at < $1.at }),
              newest.at >= since.timeIntervalSince1970
        else { return nil }
        return .init(reason: newest.reason, at: newest.at)
    }
}

/// The phone's Turn on (`reliability_turn_on`), and anything else that turns
/// every switch on.
enum ReliabilityTurnOn {
    @MainActor
    static func apply(source: String) {
        let d = UserDefaults.standard
        for key in [ReliabilityPrefs.keepRunningKey, ReliabilityPrefs.afterQuitKey, ReliabilityPrefs.frozenKey] {
            d.set(true, forKey: key)
        }
        QuipLog.write(severity: .info, subsystem: "launch",
                      message: "reliability turned on (\(source))", to: LogPaths.webSocketPath)
        let replaced = ReliabilityAgents.sync()
        NotificationCenter.default.post(name: .quipReliabilityChanged, object: nil)
        if !replaced, ReliabilityLaunch.handOffIfNeeded() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }
}

/// After a crash-loop stop, the owner's next open says why Quip had stopped.
enum ReliabilityCrashLoopNotice {
    static let pendingKey = "reliability.crashLoopNoticePending"

    @MainActor
    static func showIfPending() {
        let d = UserDefaults.standard
        guard d.bool(forKey: pendingKey) else { return }
        d.removeObject(forKey: pendingKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let crashes = ReliabilityRestarts.recent(restartsJSON: try? Data(contentsOf: ReliabilityFiles.restarts))
                .filter { $0.reason == "crash" }
            let frames = crashes.first.flatMap { ReliabilityFrames.load(for: [$0])[$0.at] } ?? []
            let alert = NSAlert()
            alert.messageText = "Quip was stopped after crashing 3 times in 10 minutes"
            alert.informativeText = "It is running again. Settings → General → Reliability lists the restarts, with Copy for a ticket."
                + (frames.isEmpty ? "" : "\n\nLast crash in:\n" + frames.joined(separator: "\n"))
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

/// Mac Settings → Reliability: the last restarts, newest first.
enum ReliabilityRestarts {
    struct Entry: Equatable {
        let at: Date
        let reason: String
        /// The same reason three or more times in the list: one bug, not three.
        let repeated: Bool
    }

    /// Pure.
    static func recent(restartsJSON: Data?, limit: Int = 5) -> [Entry] {
        struct Raw: Decodable { let at: Double; let reason: String }
        guard let data = restartsJSON,
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        let newest = raw.sorted { $0.at > $1.at }.prefix(limit)
        let counts = Dictionary(newest.map { ($0.reason, 1) }, uniquingKeysWith: +)
        return newest.map { Entry(at: Date(timeIntervalSince1970: $0.at), reason: $0.reason,
                                  repeated: (counts[$0.reason] ?? 0) >= 3) }
    }

    /// Plain words for a reason.
    static func words(_ reason: String) -> String {
        switch reason {
        case "crash": return "crashed"
        case "hang": return "froze"
        case "quit": return "was quit"
        default: return reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Pure: what "Copy for a ticket" puts on the clipboard. No home paths,
    /// no window titles.
    static func ticketText(_ entry: Entry, build: String, sample: String?, frames: [String] = []) -> String {
        var lines = [
            "Quip restart: \(entry.reason)",
            "at: \(entry.at.ISO8601Format())",
            "build: \(build)",
        ]
        if entry.repeated { lines.append("same cause 3+ times in the last restarts") }
        if !frames.isEmpty {
            lines.append("top Quip frames:")
            lines += frames.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        }
        if let sample { lines.append("hang sample: ~/Library/Logs/Quip/\(sample)") }
        return lines.joined(separator: "\n")
    }

    /// The hang sample written for a hang at `at` (the watchdog names it by
    /// the kill time, a few seconds before the restart is recorded).
    static func sampleName(for entry: Entry, in names: [String]) -> String? {
        guard entry.reason == "hang" else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return names
            .compactMap { name -> (String, Date)? in
                guard name.hasPrefix("hang-"), name.hasSuffix(".txt"),
                      let d = f.date(from: String(name.dropFirst(5).dropLast(4))) else { return nil }
                return (name, d)
            }
            .filter { abs($0.1.timeIntervalSince(entry.at)) <= 60 }
            .min { abs($0.1.timeIntervalSince(entry.at)) < abs($1.1.timeIntervalSince(entry.at)) }?.0
    }

    /// For the Diagnostics bundle: watchdog.log, restarts.json and the last
    /// three hang samples, where present.
    static func diagnosticsFiles() -> [String] {
        let logs = LogPaths.directory
        let hangs = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? [])
            .filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }
            .sorted()
            .suffix(3)
            .map { logs.appendingPathComponent($0).path }
        return [logs.appendingPathComponent("watchdog.log").path, ReliabilityFiles.restarts.path] + hangs
    }
}

/// Spec US-007: the top three Quip frames of a restart, innermost first: from
/// the crash report for a crash, from the watchdog's `sample` for a hang.
enum ReliabilityFrames {
    /// Images holding Quip's own code (a Debug build splits it into a dylib).
    static let quipImages: Set<String> = ["Quip", "Quip.debug.dylib"]
    /// Frames that name nothing a ticket reader could look up.
    static let unnamed: Set<String> = ["<deduplicated_symbol>", "???"]

    struct Report: Equatable {
        let at: Date
        let frames: [String]
    }

    /// Pure: a Mac Quip crash report (.ips). Nil for anything else, such as
    /// the simulator's Quip, whose reports land in the same folder.
    static func fromIPS(_ text: String) -> Report? {
        let parts = text.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
              let path = body["procPath"] as? String, path.hasSuffix(".app/Contents/MacOS/Quip"),
              let stamp = header["timestamp"] as? String, let at = ipsDate(stamp) else { return nil }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        guard threads.indices.contains(faulting) else { return Report(at: at, frames: []) }
        let frames = (threads[faulting]["frames"] as? [[String: Any]] ?? []).compactMap { f -> String? in
            guard let i = f["imageIndex"] as? Int, images.indices.contains(i),
                  let name = images[i], quipImages.contains(name),
                  let symbol = f["symbol"] as? String, !unnamed.contains(symbol) else { return nil }
            return label(symbol, file: f["sourceFile"] as? String, line: f["sourceLine"] as? Int)
        }
        return Report(at: at, frames: Array(frames.prefix(3)))
    }

    /// Pure: the main thread's heaviest stack in a `sample` report, Quip's
    /// innermost three frames. `sample` lists children heaviest first, so the
    /// heaviest stack is the run of lines that each go one level deeper.
    static func fromSample(_ text: String) -> [String] {
        guard let start = text.range(of: "Call graph:\n") else { return [] }
        var path: [String] = []
        var lastDepth = -1
        var threadDepth: Int?
        for line in text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            guard let m = line.firstMatch(of: #/^([\s+!:|]*)\d+ (.+?)  \(in ([^)]+)\)(?:.*\]  (\S+):(\d+))?/#) else {
                // The thread line ("2295 Thread_…") opens the call graph; the
                // next one closes the main thread.
                if threadDepth == nil, let t = line.firstMatch(of: #/^([\s+!:|]*)\d+ Thread_/#) {
                    threadDepth = t.1.count
                    continue
                }
                break
            }
            let depth = m.1.count
            guard threadDepth != nil, depth > lastDepth else { break }
            lastDepth = depth
            if quipImages.contains(String(m.3)), !unnamed.contains(String(m.2)) {
                path.append(label(String(m.2), file: m.4.map(String.init), line: m.5.flatMap { Int($0) }))
            }
        }
        return Array(path.reversed().prefix(3))
    }

    /// The crash report a crash restart came from. The report is written at
    /// the crash; the watchdog records the restart on its next check, 30 s
    /// apart, so the report is up to 2 min older than the entry.
    static func crashReport(for entry: ReliabilityRestarts.Entry, in reports: [Report]) -> Report? {
        guard entry.reason == "crash" else { return nil }
        return reports
            .filter { (-10...120).contains(entry.at.timeIntervalSince($0.at)) }
            .min { abs(entry.at.timeIntervalSince($0.at)) < abs(entry.at.timeIntervalSince($1.at)) }
    }

    /// The frames for each entry, read from disk. Call it off the main thread.
    static func load(for entries: [ReliabilityRestarts.Entry]) -> [Date: [String]] {
        guard let oldest = entries.map(\.at).min() else { return [:] }
        let fm = FileManager.default
        let reportsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let reports: [Report] = entries.contains(where: { $0.reason == "crash" })
            ? ((try? fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("Quip-") && $0.pathExtension == "ips" }
                .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= oldest.addingTimeInterval(-300) }
                .compactMap { (try? String(contentsOf: $0, encoding: .utf8)).flatMap(fromIPS) }
            : []
        let logs = LogPaths.directory
        let names = (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        var out: [Date: [String]] = [:]
        for entry in entries {
            if let report = crashReport(for: entry, in: reports), !report.frames.isEmpty {
                out[entry.at] = report.frames
            } else if let sample = ReliabilityRestarts.sampleName(for: entry, in: names),
                      let text = try? String(contentsOf: logs.appendingPathComponent(sample), encoding: .utf8) {
                let frames = fromSample(text)
                if !frames.isEmpty { out[entry.at] = frames }
            }
        }
        return out
    }

    /// "symbol (File.swift:12)": the file's name only, never its path.
    private static func label(_ symbol: String, file: String?, line: Int?) -> String {
        guard let file, let line, line > 0 else { return symbol }
        return "\(symbol) (\((file as NSString).lastPathComponent):\(line))"
    }

    private static func ipsDate(_ stamp: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f.date(from: stamp)
    }
}

extension Notification.Name {
    /// Posted after the Reliability settings change, so the phone hears it.
    static let quipReliabilityChanged = Notification.Name("quip.reliabilityChanged")
    /// Posted by Stop Quip… just before Quip stops on purpose.
    static let quipStopping = Notification.Name("quip.stopping")
}
