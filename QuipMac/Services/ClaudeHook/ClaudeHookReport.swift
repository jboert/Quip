import Foundation

/// What `quip-claude-hook` hands Quip for one Claude Bash call that opened
/// files (Q-87): one JSON file per call in `inboxDirectory`. A drop file, not
/// a socket, so the hook works whether or not Quip is running and can never
/// block on it.
struct ClaudeHookReport: Codable, Equatable, Sendable {
    var v = 1
    /// Epoch seconds when the hook ran.
    var at: Double
    var sessionId: String?
    var cwd: String
    /// Absolute paths of the previewable files the command opened.
    var paths: [String]
    /// `/dev/ttysNNN` of the nearest ancestor with a terminal (the `claude`
    /// process); the hook itself runs with none.
    var tty: String?
    /// UUID part of `ITERM_SESSION_ID` (`w0t1p0:<UUID>`), when in iTerm2.
    var itermSessionId: String?
    /// `TERM_SESSION_ID` in Terminal.app. Diagnostics only.
    var termSessionId: String?
    /// `open` arguments skipped because they needed shell expansion.
    var skippedExpansion: Int = 0

    static func itermSessionUUID(_ env: String?) -> String? {
        guard let env, !env.isEmpty else { return nil }
        if let colon = env.firstIndex(of: ":") { return String(env[env.index(after: colon)...]) }
        return env
    }

    static var inboxDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Quip/claude-previews/inbox", isDirectory: true)
    }

    /// Writes to a dot-temp name, then renames, so Quip's directory watch never
    /// reads a half-written report.
    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".json"
        let tmp = directory.appendingPathComponent("." + name)
        try JSONEncoder().encode(self).write(to: tmp)
        try FileManager.default.moveItem(at: tmp, to: directory.appendingPathComponent(name))
    }
}

/// The subset of Claude Code's PostToolUse stdin the hook reads.
struct ClaudeHookInput: Decodable {
    struct ToolInput: Decodable { let command: String? }
    let session_id: String?
    let cwd: String?
    let tool_name: String?
    let tool_input: ToolInput?
}

/// Finds the terminal a hook process belongs to. Claude Code runs hooks with
/// no controlling terminal, so walk up the parent chain to the first process
/// that has one — the `claude` process in its terminal tab.
enum ProcessTTY {
    struct Info: Equatable { let parent: pid_t; let tty: String? }

    static func info(pid: pid_t) -> Info? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = kp.kp_eproc.e_tdev
        var tty: String?
        // NODEV (-1) means no terminal; devname answers "??" for one it can't name.
        if dev != -1, let name = devname(dev, S_IFCHR), String(cString: name) != "??" {
            tty = "/dev/" + String(cString: name)
        }
        return Info(parent: kp.kp_eproc.e_ppid, tty: tty)
    }

    /// The tty of the nearest ancestor of `start` that has one.
    static func nearestTTY(from start: pid_t = getppid(), maxDepth: Int = 8,
                           lookup: (pid_t) -> Info? = info(pid:)) -> String? {
        var pid = start
        for _ in 0..<maxDepth {
            guard pid > 1, let info = lookup(pid) else { return nil }
            if let tty = info.tty { return tty }
            pid = info.parent
        }
        return nil
    }
}
