// OutputActivityTracker.swift
// QuipMac — When each tracked window last CHANGED what it was showing.

import Foundation
import Observation

/// "Most active" has to mean something measurable, and CPU is not it.
/// `TerminalStateDetector` already established that an idle CPU cannot separate
/// a network-blocked agent from one sitting at a prompt. Content movement can:
/// if the buffer differs from the last look, that window produced something.
///
/// This costs no new AppleScript. `ClaudeModeDetector` already reads every
/// tracked window's buffer every 2s for the mode scan — the slowest, most
/// expensive read in the app — and this rides that same read.
@MainActor
@Observable
final class OutputActivityTracker {

    /// Last time each window's buffer was observed to change. Absent means
    /// "never observed to change", which the sort treats as least active — not
    /// as "changed at the epoch".
    private(set) var lastOutputChangeAt: [String: Date] = [:]

    /// Last content hash per window. Process-local by construction
    /// (`hashValue` is seeded per launch), which is fine: it is only ever
    /// compared against another hash from the same run.
    private var lastHash: [String: Int] = [:]

    /// Record one observation of a window's buffer. Returns true when the
    /// content moved.
    ///
    /// First sight of a window seeds the hash WITHOUT stamping activity. The
    /// buffer was not observed to change — there was simply nothing to compare
    /// against — and stamping here would rank every newly tracked window as the
    /// most active thing on the desk, which is exactly backwards on app launch
    /// when every window is new at once.
    @discardableResult
    func record(windowId: String, content: String, now: Date = Date()) -> Bool {
        let hash = content.hashValue
        defer { lastHash[windowId] = hash }
        guard let previous = lastHash[windowId], previous != hash else { return false }
        lastOutputChangeAt[windowId] = now
        return true
    }

    /// Drop windows that are no longer tracked, so a long-lived session does
    /// not accumulate an entry per window it has ever seen.
    func prune(toTracked ids: Set<String>) {
        lastOutputChangeAt = lastOutputChangeAt.filter { ids.contains($0.key) }
        lastHash = lastHash.filter { ids.contains($0.key) }
    }
}
