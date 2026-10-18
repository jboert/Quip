import Foundation

/// How often each slash command is fired, so the long-press palette and its
/// search sheet list the user's most-used commands first.
///
/// Kept in the prompt usage store (`promptUsageJSON`) under a `slash:` key
/// prefix rather than a store of its own: that store already decays with
/// frecency, merges on restore and rides the iCloud and desktop backups, so
/// the order survives a reinstall with no new `PreferencesSnapshot` field.
/// Prompt lookups are by prompt id, so the prefixed keys never surface there.
enum SlashUsage {
    static let keyPrefix = "slash:"

    /// Store key for a palette member (`SlashGroupMember.id`, e.g. "b:compact").
    static func key(_ memberID: String) -> String { keyPrefix + memberID }

    /// `context` is the agent the command was fired in (a `CLIKind` raw
    /// value), so each agent's palette gets its own order (Q-73), as prompts
    /// do since Q-33.
    static func recording(_ memberID: String, context: String? = nil, at now: Date,
                          in store: PromptRanker.Store) -> PromptRanker.Store {
        PromptRanker.recording(key(memberID), context: context, at: now, in: store)
    }

    /// Used commands first, highest decayed score first (ties: most recent).
    /// Commands never used keep their incoming order below them. A use in
    /// `context` counts `PromptRanker.contextWeight` times more.
    static func ranked<T>(_ items: [T], id: (T) -> String, store: PromptRanker.Store,
                          context: String? = nil, at now: Date) -> [T] {
        let rows = items.enumerated().map { offset, item in
            (offset: offset, item: item, record: store[key(id(item))])
        }
        return rows.sorted { a, b in
            switch (a.record, b.record) {
            case let (.some(ra), .some(rb)):
                let sa = PromptRanker.score(ra, context: context, at: now)
                let sb = PromptRanker.score(rb, context: context, at: now)
                if sa != sb { return sa > sb }
                if ra.lastUsed != rb.lastUsed { return ra.lastUsed > rb.lastUsed }
                return a.offset < b.offset
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }.map(\.item)
    }
}
