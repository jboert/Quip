import Foundation

/// "Make my own copy" of a VibeCut-inherited prompt (Q-80). A VibeCut sync
/// replaces every `vibecut__*` file on the Mac, so an edit made to the
/// inherited file is lost. The copy gets an id outside that namespace and drops
/// the `vibecut` tag, so sync never touches it.
enum PromptCopy {

    static func ownCopy(of entry: PromptEntry, label: String, body: String,
                        existingIDs: Set<String>) -> PromptEntry {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = unreserved(PromptID.sanitize(trimmed))
        if base.isEmpty { base = unreserved(PromptID.sanitize(entry.id)) }
        if base.isEmpty { base = "prompt" }

        var id = base
        var n = 2
        while existingIDs.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }

        let kept = entry.tags?.filter { $0 != VibeCutPromptMapper.providerTag }
        return PromptEntry(
            id: id,
            label: trimmed.isEmpty ? entry.label : trimmed,
            body: body,
            tags: (kept?.isEmpty ?? true) ? nil : kept,
            targetAgent: entry.targetAgent,
            description: entry.description
        )
    }

    /// `id` without any leading `vibecut__`, however many times it repeats.
    private static func unreserved(_ id: String) -> String {
        var out = id
        while out.hasPrefix(VibeCutPromptMapper.idPrefix) {
            out.removeFirst(VibeCutPromptMapper.idPrefix.count)
        }
        return out
    }
}
