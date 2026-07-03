import Foundation

/// Pure helpers for the iOS per-prompt hide feature. Because inherited (and all)
/// prompts are Mac-sourced and not persisted on the phone, the hidden state lives
/// on iOS only, as a JSON string array in `@AppStorage("hiddenPromptIDsJSON")`.
///
/// Everything here is deterministic and platform-free so it can be unit-tested on
/// the macOS test target. Hidden prompts are filtered OUT of the paste / quick
/// picker (via `visible`) but stay visible-but-dimmed in the settings editor so
/// the user can re-enable them.
enum PromptHideState {
    /// Decode the stored JSON array into a set of hidden ids (empty on garbage).
    static func decode(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    /// Encode a set of hidden ids back to JSON, sorted for stable storage.
    static func encode(_ ids: Set<String>) -> String {
        guard let data = try? JSONEncoder().encode(ids.sorted()),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Flip one id's hidden membership, returning the new JSON.
    static func toggled(_ id: String, in json: String) -> String {
        var set = decode(json)
        if !set.insert(id).inserted { set.remove(id) }
        return encode(set)
    }

    static func isHidden(_ id: String, in json: String) -> Bool {
        decode(json).contains(id)
    }

    /// Prompts that should appear in paste / quick-picker flows — hidden ids dropped.
    static func visible(_ prompts: [PromptEntry], hiddenJSON: String) -> [PromptEntry] {
        let hidden = decode(hiddenJSON)
        guard !hidden.isEmpty else { return prompts }
        return prompts.filter { !hidden.contains($0.id) }
    }

    /// Drop hidden ids no longer present in the catalog (e.g. a prompt removed by a
    /// later sync) so the set can't grow unbounded and a re-created prompt can't be
    /// silently re-hidden. Returns the new JSON when it changed, else nil so callers
    /// can skip a redundant `@AppStorage` write.
    static func pruned(hiddenJSON: String, presentIDs: Set<String>) -> String? {
        let set = decode(hiddenJSON)
        let kept = set.intersection(presentIDs)
        return kept == set ? nil : encode(kept)
    }
}
