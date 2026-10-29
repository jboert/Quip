import Foundation

/// Adds and removes Quip's one Claude Code hook in `~/.claude/settings.json`,
/// for the "Show Claude's previews on phone" switch (Q-87).
///
/// The rules that keep the owner's own hooks safe:
/// - Quip's hook is recognised only by `marker` at the end of its command.
///   Uninstall removes exactly those hooks and nothing else.
/// - The rest of the file round-trips unchanged (`OrderedJSON` keeps key
///   order and number spelling).
/// - A file that is not valid JSON is never written.
///
/// The byte-level functions are pure so every case is a unit test; the
/// `OnDisk` ones add the backup and the atomic write.
enum ClaudeHookInstaller {
    static let marker = "# quip-previews"

    enum Status: Equatable {
        case off
        case on
        /// Quip's hook is there but runs a different helper path (Quip moved,
        /// or an old copy installed it). Repair rewrites it.
        case stale(command: String)
        /// The settings file exists but is not valid JSON.
        case unreadable
    }

    enum InstallError: Error, Equatable {
        case unreadable
        /// `hooks` or `hooks.PostToolUse` has a shape Claude Code would not
        /// accept either; Quip will not guess how to merge into it.
        case unexpectedShape(String)
    }

    /// The hook's command line: the helper path, single-quoted for the shell,
    /// then the marker as a shell comment.
    static func command(hookPath: String) -> String {
        "'" + hookPath.replacingOccurrences(of: "'", with: "'\\''") + "' " + marker
    }

    static func hookEntry(hookPath: String) -> OrderedJSON {
        .object([
            ("type", .string("command")),
            ("command", .string(command(hookPath: hookPath))),
            ("timeout", .number("5")),
            // Runs in the background: Claude never waits on Quip.
            ("async", .bool(true)),
        ])
    }

    static func isQuipHook(_ hook: OrderedJSON) -> Bool {
        hook["command"]?.stringValue?.hasSuffix(marker) == true
    }

    // MARK: - Pure

    static func status(settings: Data?, hookPath: String) -> Status {
        guard let settings, !settings.isEmpty else { return .off }
        guard let root = try? OrderedJSON.parse(settings) else { return .unreadable }
        let commands = quipHookCommands(in: root)
        guard !commands.isEmpty else { return .off }
        let want = command(hookPath: hookPath)
        if let other = commands.first(where: { $0 != want }) { return .stale(command: other) }
        return .on
    }

    /// `settings` with Quip's hook present exactly once, pointing at
    /// `hookPath`. Already-correct input comes back byte-for-byte.
    static func install(into settings: Data?, hookPath: String) throws -> Data {
        if status(settings: settings, hookPath: hookPath) == .on, let settings { return settings }
        var root = try parsedRoot(settings)
        root = try removingQuipHooks(from: root)
        var hooks = root["hooks"] ?? .object([])
        guard case .object = hooks else { throw InstallError.unexpectedShape("hooks") }
        var post = hooks["PostToolUse"]?.arrayValue ?? []
        if let existing = hooks["PostToolUse"], existing.arrayValue == nil {
            throw InstallError.unexpectedShape("hooks.PostToolUse")
        }
        post.append(.object([
            ("matcher", .string("Bash")),
            ("hooks", .array([hookEntry(hookPath: hookPath)])),
        ]))
        hooks.set("PostToolUse", .array(post))
        root.set("hooks", hooks)
        return encode(root, like: settings)
    }

    /// `settings` with every Quip hook removed. A matcher group is removed only
    /// when Quip's hook was its last one; `PostToolUse` only when that left it
    /// empty. Input without a Quip hook comes back byte-for-byte.
    static func uninstall(from settings: Data?) throws -> Data? {
        guard let settings, !settings.isEmpty else { return settings }
        guard let root = try? OrderedJSON.parse(settings) else { throw InstallError.unreadable }
        guard !quipHookCommands(in: root).isEmpty else { return settings }
        return encode(try removingQuipHooks(from: root), like: settings)
    }

    // MARK: - On disk

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/settings.json")
    }

    static var backupURL: URL {
        settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.quip-backup")
    }

    static func statusOnDisk(hookPath: String, url: URL = settingsURL) -> Status {
        status(settings: try? Data(contentsOf: url), hookPath: hookPath)
    }

    static func installOnDisk(hookPath: String, url: URL = settingsURL) throws {
        let fm = FileManager.default
        let original = try? Data(contentsOf: url)
        let updated = try install(into: original, hookPath: hookPath)
        guard updated != original else { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One backup of the owner's file as it was before Quip ever touched it.
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".quip-backup")
        if let original, !fm.fileExists(atPath: backup.path) {
            try original.write(to: backup)
        }
        try writeAtomically(updated, to: url)
    }

    static func uninstallOnDisk(url: URL = settingsURL) throws {
        guard let original = try? Data(contentsOf: url) else { return }
        guard let updated = try uninstall(from: original), updated != original else { return }
        try writeAtomically(updated, to: url)
    }

    // MARK: - Helpers

    private static func parsedRoot(_ settings: Data?) throws -> OrderedJSON {
        guard let settings, !settings.isEmpty else { return .object([]) }
        guard let root = try? OrderedJSON.parse(settings) else { throw InstallError.unreadable }
        guard case .object = root else { throw InstallError.unexpectedShape("root") }
        return root
    }

    private static func quipHookCommands(in root: OrderedJSON) -> [String] {
        (root["hooks"]?["PostToolUse"]?.arrayValue ?? []).flatMap { group in
            (group["hooks"]?.arrayValue ?? []).filter(isQuipHook).compactMap { $0["command"]?.stringValue }
        }
    }

    private static func removingQuipHooks(from root: OrderedJSON) throws -> OrderedJSON {
        guard var hooks = root["hooks"], let post = hooks["PostToolUse"]?.arrayValue else { return root }
        var kept: [OrderedJSON] = []
        for var group in post {
            guard let inner = group["hooks"]?.arrayValue, inner.contains(where: isQuipHook) else {
                kept.append(group); continue
            }
            let rest = inner.filter { !isQuipHook($0) }
            if rest.isEmpty { continue }
            group.set("hooks", .array(rest))
            kept.append(group)
        }
        if kept.isEmpty { hooks.remove("PostToolUse") } else { hooks.set("PostToolUse", .array(kept)) }
        var out = root
        out.set("hooks", hooks)
        return out
    }

    /// Serialized the way Claude Code writes the file, keeping whether the
    /// original ended in a newline (a new file gets one).
    private static func encode(_ root: OrderedJSON, like original: Data?) -> Data {
        var text = root.serialized()
        if original?.isEmpty != false || original?.last == UInt8(ascii: "\n") { text += "\n" }
        return Data(text.utf8)
    }

    /// Temp file beside the target, then rename, so Claude Code never reads a
    /// half-written file. Keeps the original's permissions.
    private static func writeAtomically(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        // A dotfiles setup symlinks settings.json; write through the link
        // rather than replacing it with a plain file.
        let url = target.resolvingSymlinksInPath()
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).quip-\(UUID().uuidString)")
        try data.write(to: tmp)
        if let perms = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        }
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)])
        }
    }
}
