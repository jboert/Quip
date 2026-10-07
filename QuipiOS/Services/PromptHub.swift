import Foundation

/// What the Prompts hub lists. Visible prompts come first in frecency order
/// for the selected window's agent (`PromptRanker`), so the most-used are on
/// top. Hidden prompts are kept apart, alphabetical, so they can be shown
/// again without crowding the list. Search matches label, body or id in both.
enum PromptHub {
    struct Sections: Equatable {
        var visible: [PromptEntry]
        var hidden: [PromptEntry]
    }

    static func sections(_ library: [PromptEntry], hiddenJSON: String, store: PromptRanker.Store,
                         context: String?, query: String, at now: Date) -> Sections {
        let hiddenIDs = PromptHideState.decode(hiddenJSON)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: (PromptEntry) -> Bool = { entry in
            q.isEmpty
                || entry.label.lowercased().contains(q)
                || entry.body.lowercased().contains(q)
                || entry.id.lowercased().contains(q)
        }
        let visible = PromptRanker.ranked(library.filter { !hiddenIDs.contains($0.id) },
                                          store: store, context: context, at: now)
        let hidden = library
            .filter { hiddenIDs.contains($0.id) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return Sections(visible: visible.filter(matches), hidden: hidden.filter(matches))
    }
}
