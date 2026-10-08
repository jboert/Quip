import Foundation

/// What the Broadcast sheet offers under its prompt field (PRD
/// broadcast-and-search, US-106): the most used prompts while the field is
/// empty, the prompts matching the draft once it holds a couple of
/// characters, and nothing in between. A suggestion only fills the field;
/// nothing is sent until the user taps Send.
enum BroadcastSuggestions {
    /// The most suggestions shown at once.
    static let limit = 6
    /// Characters the draft needs, not counting surrounding whitespace,
    /// before it is searched: one letter matches too much to help.
    static let minimumQueryLength = 2

    enum Kind: Equatable, Sendable {
        /// The field is empty: the top prompts by `PromptRanker` frecency.
        case mostUsed
        /// Prompts matching the draft, best match first.
        case matches
        /// Nothing to show: the draft is too short to search, or it is still
        /// the body of the prompt the user just chose.
        case none
    }

    struct Result: Equatable, Sendable {
        var kind: Kind
        var prompts: [PromptEntry]
    }

    /// Suggestions for `draft`, ranked and filtered as the Prompts hub ranks
    /// and filters (`PromptHub.sections`): hidden prompts are never offered,
    /// and matches come best first, with frecency in `context` breaking ties.
    /// `chosenBody` is the body of the prompt the draft was filled from;
    /// while the draft still equals it the list stays out of the way.
    static func suggestions(draft: String, library: [PromptEntry], hiddenJSON: String,
                            store: PromptRanker.Store, context: String?, at now: Date,
                            chosenBody: String? = nil,
                            cache: PromptSearchCache? = nil) -> Result {
        let query = BroadcastPromptPlan.normalizedText(draft)
        if let chosenBody, query == BroadcastPromptPlan.normalizedText(chosenBody) {
            return Result(kind: .none, prompts: [])
        }
        if !query.isEmpty, query.count < minimumQueryLength {
            return Result(kind: .none, prompts: [])
        }
        let visible = PromptHub.sections(library, hiddenJSON: hiddenJSON, store: store,
                                         context: context, query: query, at: now, cache: cache).visible
        return Result(kind: query.isEmpty ? .mostUsed : .matches, prompts: Array(visible.prefix(limit)))
    }
}
