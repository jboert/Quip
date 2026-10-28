// VibeCutStatusText.swift
// QuipiOS — the one line the Prompts hub shows for the VibeCut sync state (Q-85).
//
// Pure: the Mac's `vibecut_status` answer in, a line (or nothing) out. The
// hub never guesses; Unknown shows nothing, exactly as the Mac's own
// Prompts pane does.

import Foundation

enum VibeCutStatusText {
    struct Line: Equatable {
        let text: String
        let tone: Tone
    }

    enum Tone: Equatable {
        /// Informational: up to date, or never synced.
        case neutral
        /// A sync is due; the row is tappable and runs it.
        case due
        /// The last attempt failed.
        case failed
    }

    /// nil for Unknown: the hub shows nothing rather than a guess. Rules, in
    /// order: a failed last attempt wins over any freshness; then never
    /// synced; then changed; then current with the count and a relative time.
    static func line(freshness: VibeCutFreshnessWire, lastSyncAt: Date?,
                     syncedCount: Int?, error: String?, now: Date = Date()) -> Line? {
        if let error, !error.isEmpty {
            return Line(text: "Last sync failed — \(error)", tone: .failed)
        }
        switch freshness {
        case .neverSynced:
            return Line(text: "Never synced from VibeCut", tone: .neutral)
        case .changed:
            return Line(text: "VibeCut changed since the last sync — Sync", tone: .due)
        case .current:
            var parts = ["Up to date with VibeCut"]
            if let syncedCount {
                parts.append("\(syncedCount) prompt\(syncedCount == 1 ? "" : "s")")
            }
            if let lastSyncAt {
                parts.append(relative(lastSyncAt, now: now))
            }
            return Line(text: parts.joined(separator: " · "), tone: .neutral)
        case .unknown:
            return nil
        }
    }

    /// "2 hours ago"; "just now" inside a minute, where the formatter would
    /// say "in 0 seconds" for a date a hair in the future.
    static func relative(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
