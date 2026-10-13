import SwiftUI
import AVFoundation

struct SavedConnection: Codable, Identifiable {
    var id = UUID()
    var url: String
    var name: String?
    var pinned: Bool = false
    var lastUsed: Date = Date()

    var displayName: String {
        if let name, !name.isEmpty { return name }
        // Extract hostname from URL
        if let u = URL(string: url), let host = u.host {
            let short = host.replacingOccurrences(of: ".trycloudflare.com", with: "")
            return short
        }
        return url
    }

    /// Pure merge for recents restore — union `incoming` into `existing` by
    /// URL (keep newest `lastUsed`, OR `pinned`, adopt a name only when the
    /// existing entry has none), then cap to `cap` (all pinned + newest
    /// unpinned), matching `addToRecents`. Value-in/value-out for unit testing.
    static func mergedRecents(existing: [SavedConnection], incoming: [SavedConnection], cap: Int) -> [SavedConnection] {
        var out = existing
        for r in incoming {
            if let i = out.firstIndex(where: { $0.url == r.url }) {
                if r.lastUsed > out[i].lastUsed { out[i].lastUsed = r.lastUsed }
                out[i].pinned = out[i].pinned || r.pinned
                if out[i].name == nil, let n = r.name, !n.isEmpty { out[i].name = n }
            } else {
                out.append(r)
            }
        }
        let pinned = out.filter(\.pinned)
        let unpinned = out.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        let unpinnedLimit = max(0, cap - pinned.count)
        return pinned + Array(unpinned.prefix(unpinnedLimit))
    }
}

// MARK: - Inline Terminal Content (portrait mode)
