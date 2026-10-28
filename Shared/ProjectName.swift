import Foundation

/// Which project a working directory belongs to: the basename of the nearest
/// ancestor that holds a `.git` entry (directory or file, so worktrees count),
/// else the basename of the directory itself. Empty or "/" has no project.
///
/// The same rule runs in VibeCut (`app/ProjectName.swift`); both are checked
/// against one vector file (`Shared/Tests/Fixtures/project_name_vectors.json`
/// here), so the two apps cannot drift on what "the project" means.
///
/// The filesystem is injected so the rule is a pure function in tests.
enum ProjectName {
    /// `exists(path)` answers "is there a `.git` entry at this exact path?".
    static func resolve(cwd: String?, hasGit: (String) -> Bool) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let path = normalized(cwd)
        guard path != "/" else { return nil }
        var dir = path
        while dir != "/" {
            if hasGit(dir + "/.git") { return basename(dir) }
            dir = parent(dir)
        }
        return basename(path)
    }

    /// Resolve against the real filesystem. Cached for a short time: window
    /// layouts are rebuilt many times a second and a git root does not move.
    static func resolve(cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let now = Date()
        cacheLock.lock()
        if let hit = cache[cwd], now.timeIntervalSince(hit.at) < cacheTTL {
            cacheLock.unlock()
            return hit.name
        }
        cacheLock.unlock()
        let name = resolve(cwd: cwd) { FileManager.default.fileExists(atPath: $0) }
        cacheLock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[cwd] = (name, now)
        cacheLock.unlock()
        return name
    }

    private static let cacheTTL: TimeInterval = 30
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (name: String?, at: Date)] = [:]

    /// Drop repeated and trailing slashes so "/a//b/" and "/a/b" agree.
    private static func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    private static func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    private static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }
}
