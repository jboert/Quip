import Foundation

/// A count that fades with time: every use adds 1, and the running total
/// halves once per `PromptRanker.halfLife`. Stored as the value at `at`, so
/// it is decayed lazily on read and on each new use — exact, with no need to
/// keep a list of past timestamps.
struct DecayedScore: Codable, Equatable, Sendable {
    var value: Double
    var at: Date

    func value(at now: Date, halfLife: TimeInterval) -> Double {
        let elapsed = max(0, now.timeIntervalSince(at))
        return value * pow(0.5, elapsed / halfLife)
    }

    func bumped(at now: Date, halfLife: TimeInterval) -> DecayedScore {
        DecayedScore(value: value(at: now, halfLife: halfLife) + 1, at: now)
    }
}

/// Usage history for one prompt on this phone.
struct PromptUsageRecord: Codable, Equatable, Sendable {
    /// Lifetime number of fires. Never decays; a tiebreak and a merge key.
    var uses: Int
    var lastUsed: Date
    /// Frecency across every context.
    var score: DecayedScore
    /// Frecency per context key (a `CLIKind` raw value: claude, codex, shell…),
    /// so a prompt used in Claude windows ranks up when a Claude window is the
    /// target, without hiding it from the others.
    var contexts: [String: DecayedScore]
}

/// Ranks the prompt picker by frecency instead of by last use.
///
/// Last-use order put whatever was fired most recently at the top, so one
/// stray tap outranked a prompt used every day. Frecency keeps the daily
/// workhorses on top: a prompt has to be used repeatedly to hold its place,
/// and an old habit fades instead of squatting forever.
enum PromptRanker {
    /// A use a week ago counts half as much as a use now.
    static let halfLife: TimeInterval = 7 * 24 * 60 * 60
    /// How much more a use in the target's context counts than a use anywhere.
    static let contextWeight: Double = 2
    /// The store is capped so prompts deleted from the catalog cannot grow it forever.
    static let maxRecords = 200

    typealias Store = [String: PromptUsageRecord]

    // MARK: Persistence

    static func decode(_ json: String) -> Store {
        guard let data = json.data(using: .utf8),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return [:] }
        return store
    }

    static func encode(_ store: Store) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(store),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Converts the old last-use map (`promptUsageMRUJSON`: id → ISO-8601) so an
    /// upgrade keeps the order the user had: each entry becomes one use at its
    /// recorded time. Unparseable dates are dropped.
    static func migrate(legacyMRUJSON json: String) -> Store {
        guard let data = json.data(using: .utf8),
              let mru = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let formatter = ISO8601DateFormatter()
        var store: Store = [:]
        for (id, iso) in mru {
            guard let date = formatter.date(from: iso) else { continue }
            store[id] = PromptUsageRecord(
                uses: 1, lastUsed: date,
                score: DecayedScore(value: 1, at: date), contexts: [:]
            )
        }
        return store
    }

    // MARK: Recording

    static func recording(_ promptID: String, context: String?, at now: Date, in store: Store) -> Store {
        var store = store
        let zero = DecayedScore(value: 0, at: now)
        var record = store[promptID]
            ?? PromptUsageRecord(uses: 0, lastUsed: now, score: zero, contexts: [:])
        record.uses += 1
        record.lastUsed = max(record.lastUsed, now)
        record.score = record.score.bumped(at: now, halfLife: halfLife)
        if let context, !context.isEmpty {
            record.contexts[context] = (record.contexts[context] ?? zero).bumped(at: now, halfLife: halfLife)
        }
        store[promptID] = record
        return capped(store, at: now)
    }

    /// Drops the lowest-scoring records beyond `maxRecords`.
    static func capped(_ store: Store, at now: Date) -> Store {
        guard store.count > maxRecords else { return store }
        let drop = store
            .sorted { $0.value.score.value(at: now, halfLife: halfLife) < $1.value.score.value(at: now, halfLife: halfLife) }
            .prefix(store.count - maxRecords)
            .map(\.key)
        var out = store
        for id in drop { out.removeValue(forKey: id) }
        return out
    }

    /// Combines a backup with the live store. Both are this phone's own history
    /// at different moments, so per prompt the record with more uses is the
    /// newer one and wins whole; mixing fields would double-count.
    static func merged(_ local: Store, with incoming: Store, at now: Date) -> Store {
        var out = local
        for (id, theirs) in incoming {
            guard let mine = out[id] else { out[id] = theirs; continue }
            if theirs.uses > mine.uses || (theirs.uses == mine.uses && theirs.lastUsed > mine.lastUsed) {
                out[id] = theirs
            }
        }
        return capped(out, at: now)
    }

    // MARK: Ranking

    static func score(_ record: PromptUsageRecord, context: String?, at now: Date) -> Double {
        var s = record.score.value(at: now, halfLife: halfLife)
        if let context, let c = record.contexts[context] {
            s += contextWeight * c.value(at: now, halfLife: halfLife)
        }
        return s
    }

    /// Used prompts first by score (then more recent, then more uses); unused
    /// prompts after them, alphabetical by label so the long tail stays
    /// predictable. Stable for equal keys via the id.
    static func ranked(_ prompts: [PromptEntry], store: Store, context: String?, at now: Date) -> [PromptEntry] {
        let scores: [String: Double] = store.mapValues { score($0, context: context, at: now) }
        return prompts.sorted { a, b in
            switch (store[a.id], store[b.id]) {
            case let (.some(ra), .some(rb)):
                let sa = scores[a.id] ?? 0, sb = scores[b.id] ?? 0
                if sa != sb { return sa > sb }
                if ra.lastUsed != rb.lastUsed { return ra.lastUsed > rb.lastUsed }
                if ra.uses != rb.uses { return ra.uses > rb.uses }
                return a.id < b.id
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                let order = a.label.localizedCaseInsensitiveCompare(b.label)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
        }
    }
}
