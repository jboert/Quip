import Foundation

/// A broadcast of an unmodified library prompt counts toward its ranking
/// (PRD broadcast-and-search, US-112), through the same `PromptRanker`
/// recording a main-screen fire uses.
enum BroadcastUsage {
    /// `store` with the broadcast of `promptID` recorded once per distinct
    /// agent context among its targets (`contexts` holds one entry per
    /// window), in first-seen order. One broadcast is one decision to use
    /// the prompt, so four Claude windows count once, while a broadcast to
    /// Claude and Codex windows counts in each agent's ranking. Targets with
    /// no agent are counted once, without a context, only when no target has
    /// one. No targets, no change.
    static func recording(_ promptID: String, contexts: [String?], at now: Date,
                          in store: PromptRanker.Store) -> PromptRanker.Store {
        guard !contexts.isEmpty else { return store }
        var distinct: [String] = []
        for case let context? in contexts where !context.isEmpty && !distinct.contains(context) {
            distinct.append(context)
        }
        guard !distinct.isEmpty else {
            return PromptRanker.recording(promptID, context: nil, at: now, in: store)
        }
        return distinct.reduce(store) { store, context in
            PromptRanker.recording(promptID, context: context, at: now, in: store)
        }
    }
}
