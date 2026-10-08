import Foundation

/// Which build this is, for the phone's Settings, the Mac's menu and the
/// diagnostics snapshot. The marketing version alone never changes between
/// installs (1.5.6 was 1.5.6 for weeks), so every build also carries the git
/// commit and the build time, stamped into Info.plist by
/// tools/stamp-build-info.sh as a post-build phase on both targets.
enum BuildInfo {
    struct Stamp: Equatable {
        var short: String
        var build: String
        var commit: String?
        var date: String?
    }

    /// Read from `Bundle.main` once per launch.
    static let current: Stamp = stamp(from: Bundle.main.infoDictionary ?? [:])

    static func stamp(from info: [String: Any]) -> Stamp {
        Stamp(short: info["CFBundleShortVersionString"] as? String ?? "?",
              build: info["CFBundleVersion"] as? String ?? "?",
              commit: nonEmpty(info["QuipBuildCommit"] as? String),
              date: nonEmpty(info["QuipBuildDate"] as? String))
    }

    /// The full line: "1.5.7 (a8f2308, 2026-10-08 08:30)". Without a stamp
    /// (a build that skipped the phase) it is the old "1.5.7 (1)".
    static func display(_ stamp: Stamp) -> String {
        guard let commit = stamp.commit else {
            return stamp.short == stamp.build ? stamp.short : "\(stamp.short) (\(stamp.build))"
        }
        if let date = stamp.date { return "\(stamp.short) (\(commit), \(date))" }
        return "\(stamp.short) (\(commit))"
    }

    /// The short form for a status line: "1.5.7 a8f2308".
    static func shortDisplay(_ stamp: Stamp) -> String {
        guard let commit = stamp.commit else { return stamp.short }
        return "\(stamp.short) \(commit)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
