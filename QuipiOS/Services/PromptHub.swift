import Foundation

/// What a prompt can be found by in every phone search (PRD
/// broadcast-and-search, US-102): its name, id, tags, target agent,
/// description and body.
extension PromptEntry: QuipSearchable {
    var searchFields: [QuipSearchField] {
        var fields = [QuipSearchField(.name, label), QuipSearchField(.id, id)]
        fields += (tags ?? []).map { QuipSearchField(.tag, $0) }
        if let targetAgent { fields.append(QuipSearchField(.agent, targetAgent)) }
        if let description { fields.append(QuipSearchField(.description, description)) }
        fields.append(QuipSearchField(.body, body))
        return fields
    }
}

enum PromptHub {
    struct Sections: Equatable {
        var visible: [PromptEntry]
        var hidden: [PromptEntry]
        /// Why a prompt matched the query, by prompt id, for the prompts whose
        /// row needs to say more than its name and first line. Empty without
        /// a query.
        var notes: [String: MatchNote] = [:]
    }

    struct MatchNote: Equatable {
        /// The body text around the match, shown in place of the body's
        /// first line when nothing matched in the name.
        var excerpt: String?
        /// "Close match: comimt → commit" when a word was found only with a
        /// typo.
        var closeMatch: String?
    }

    /// Without a query: visible prompts most used first, hidden ones by name.
    /// With a query: the prompts that match, best match first in each
    /// section; equally good matches keep the order above.
    static func sections(_ library: [PromptEntry], hiddenJSON: String, store: PromptRanker.Store,
                         context: String?, query: String, at now: Date,
                         cache: PromptSearchCache? = nil) -> Sections {
        let hiddenIDs = PromptHideState.decode(hiddenJSON)
        let visible = PromptRanker.ranked(library.filter { !hiddenIDs.contains($0.id) },
                                          store: store, context: context, at: now)
        let hidden = library
            .filter { hiddenIDs.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        guard !QuipSearch.tokens(query).isEmpty else {
            return Sections(visible: visible, hidden: hidden)
        }

        var order: [String: Int] = [:]
        for (position, entry) in (visible + hidden).enumerated() where order[entry.id] == nil {
            order[entry.id] = position
        }
        let index = cache?.index(for: library) ?? QuipSearch.Index(library)
        let hits = index.search(query, rank: library.map { order[$0.id] ?? Int.max })

        var sections = Sections(visible: [], hidden: [])
        for hit in hits {
            let entry = hit.item
            if hiddenIDs.contains(entry.id) {
                sections.hidden.append(entry)
            } else {
                sections.visible.append(entry)
            }
            let note = MatchNote(excerpt: hit.excerptWord.flatMap { QuipSearch.excerpt(of: entry.body, around: $0) },
                                 closeMatch: hit.closeMatch)
            if note != MatchNote() { sections.notes[entry.id] = note }
        }
        return sections
    }
}

/// The search index for the last library seen. SwiftUI asks for the hub's
/// sections on every keystroke, and indexing a large library takes longer
/// than a frame in a debug build, so the index is rebuilt only when the
/// library changes.
final class PromptSearchCache {
    private var library: [PromptEntry] = []
    private var index: QuipSearch.Index<PromptEntry>?

    func index(for library: [PromptEntry]) -> QuipSearch.Index<PromptEntry> {
        if let index, library == self.library { return index }
        let built = QuipSearch.Index(library)
        self.library = library
        index = built
        return built
    }
}
