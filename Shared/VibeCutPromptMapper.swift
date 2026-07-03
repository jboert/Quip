import Foundation

/// Decodes VibeCut's `shared/prompts.json` catalog and maps its prompts into Quip
/// `PromptEntry` rows for one-way inherit. Pure — no file IO, no `Date()`, fully
/// deterministic for a given input.
///
/// Source of truth: `<vibecut-repo>/shared/prompts.json` (git-tracked in the
/// VibeCut project). Only "real" text prompts inherit:
///   - `type` is `text` or absent, AND
///   - the `prompt` body is non-empty, AND
///   - `mode != "send"` (the send-immediately slash shortcuts like `/clear`,
///     `/compact` are intentionally skipped).
/// VibeCut's shared `preamble` is deliberately NOT prepended (strip decision) — we
/// inherit only the per-prompt body.
///
/// Every inherited row is tagged `"vibecut"` (drives the iOS "VibeCut" badge and
/// the per-prompt hide filter) and its id is namespaced `vibecut__<slug>` so the
/// Mac re-sync can cleanly replace the whole inherited set without touching the
/// user's own prompts.

/// One prompt object inside VibeCut's `prompts.json`. All fields optional so a
/// minimal / future entry still decodes; unknown extra fields are ignored.
struct VibeCutPrompt: Codable, Sendable, Equatable {
    var id: String?
    var slug: String?
    var name: String?
    var category: String?
    var tags: [String]?
    var prompt: String?
    var mode: String?
    var type: String?
    var skipPreamble: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, slug, name, category, tags, prompt, mode, type
        case skipPreamble = "skip_preamble"
    }

    init(id: String? = nil, slug: String? = nil, name: String? = nil,
         category: String? = nil, tags: [String]? = nil, prompt: String? = nil,
         mode: String? = nil, type: String? = nil, skipPreamble: Bool? = nil) {
        self.id = id; self.slug = slug; self.name = name; self.category = category
        self.tags = tags; self.prompt = prompt; self.mode = mode; self.type = type
        self.skipPreamble = skipPreamble
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        skipPreamble = try c.decodeIfPresent(Bool.self, forKey: .skipPreamble)
    }
}

/// The top-level `prompts.json` shape. `categories` is tolerated but unused for
/// mapping (we do not need the human category labels, only the per-prompt key).
struct VibeCutCatalog: Codable, Sendable, Equatable {
    var version: String?
    var preamble: String?
    var prompts: [VibeCutPrompt]

    private enum CodingKeys: String, CodingKey { case version, preamble, prompts }

    init(version: String? = nil, preamble: String? = nil, prompts: [VibeCutPrompt] = []) {
        self.version = version; self.preamble = preamble; self.prompts = prompts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        preamble = try c.decodeIfPresent(String.self, forKey: .preamble)
        prompts = try c.decodeIfPresent([VibeCutPrompt].self, forKey: .prompts) ?? []
    }
}

enum VibeCutPromptMapper {
    /// Provenance tag stamped on every inherited prompt.
    static let providerTag = "vibecut"
    /// Reserved filename / id namespace for inherited prompts.
    static let idPrefix = "vibecut__"

    /// Map a decoded catalog into inheritable Quip prompts plus a count of the
    /// entries that were skipped by the include filter.
    static func map(catalog: VibeCutCatalog) -> (entries: [PromptEntry], skipped: Int) {
        let included = catalog.prompts.filter(isInheritable)
        let skipped = catalog.prompts.count - included.count

        // Deterministic ordering so collision suffixes (-2/-3) and output order are
        // stable across runs: sort by display name, then by source id.
        let sorted = included.sorted { lhs, rhs in
            let ln = lhs.name ?? "", rn = rhs.name ?? ""
            if ln != rn { return ln < rn }
            return (lhs.id ?? "") < (rhs.id ?? "")
        }

        var used = Set<String>()
        var fallbackCounter = 0
        var entries: [PromptEntry] = []
        entries.reserveCapacity(sorted.count)

        for p in sorted {
            let name = p.name ?? ""
            var core = slug(name)
            if core.isEmpty {
                fallbackCounter += 1
                core = "untitled-\(fallbackCounter)"
            }
            let id = uniqueID(idPrefix + core, used: &used)
            let label = name.isEmpty ? core : name

            var tags = [providerTag]
            if let cat = p.category, !cat.isEmpty { tags.append(cat) }
            if let extra = p.tags { for t in extra where !t.isEmpty { tags.append(t) } }
            tags = dedupePreservingOrder(tags)

            entries.append(PromptEntry(id: id, label: label, body: p.prompt ?? "",
                                       tags: tags, targetAgent: nil, description: nil))
        }
        return (entries, skipped)
    }

    /// A VibeCut entry inherits iff it is a real text prompt: a non-empty body, a
    /// text (or absent) type, and not a send-immediately shortcut.
    static func isInheritable(_ p: VibeCutPrompt) -> Bool {
        guard let body = p.prompt, !body.isEmpty else { return false }
        let typeOK = (p.type == nil || p.type == "text")
        let modeOK = (p.mode != "send")
        return typeOK && modeOK
    }

    /// Lowercase, collapse every run of non-`[a-z0-9]` to a single `-`, trim `-`.
    static func slug(_ s: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in s.lowercased() {
            if (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") {
                out.append(ch)
                pendingDash = false
            } else if !pendingDash {
                out.append("-")
                pendingDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Private helpers

    private static func uniqueID(_ base: String, used: inout Set<String>) -> String {
        if !used.contains(base) { used.insert(base); return base }
        var n = 2
        while used.contains("\(base)-\(n)") { n += 1 }
        let id = "\(base)-\(n)"
        used.insert(id)
        return id
    }

    private static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where seen.insert(item).inserted { out.append(item) }
        return out
    }
}
