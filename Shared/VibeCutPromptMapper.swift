import Foundation

/// Decodes VibeCut's `shared/prompts.json` catalog and maps its prompts into Quip
/// `PromptEntry` rows for one-way inherit. Pure — no file IO, no `Date()`, fully
/// deterministic for a given input.
///
/// Source of truth: `<vibecut-repo>/shared/prompts.json` (git-tracked in the
/// VibeCut project). Only "real" text prompts inherit:
///   - `kind` is not `runtime-command` / `local-command` (those are VibeCut
///     machinery, not prompts), AND
///   - `type` is `text` or absent, AND
///   - the `prompt` body is non-empty, AND
///   - `mode != "send"` — unless `kind == "prompt"`, which VibeCut sets on a real
///     prompt it sends on tap (e.g. "Proceed"); then `mode` is ignored. With no
///     `kind` the send-immediately slash shortcuts like `/clear`, `/compact` are
///     intentionally skipped.
/// `kind`, `purpose` and `requirements` come from `shared/prompt-organization.json`
/// (or the prompt row itself, which wins) and ride along as `purpose:` / `needs:` tags.
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
    /// VibeCut organization metadata. `requirements == []` is an explicit "needs
    /// nothing" and is NOT the same as nil ("not stated").
    var purpose: String?
    var requirements: [String]?
    var kind: String?

    private enum CodingKeys: String, CodingKey {
        case id, slug, name, category, tags, prompt, mode, type, purpose, requirements, kind
        case skipPreamble = "skip_preamble"
    }

    /// One `shared/prompt-organization.json` annotation. Every field optional.
    struct Organization: Sendable, Equatable {
        var purpose: String?
        var requirements: [String]?
        var kind: String?

        init(purpose: String? = nil, requirements: [String]? = nil, kind: String? = nil) {
            self.purpose = purpose; self.requirements = requirements; self.kind = kind
        }
    }

    init(id: String? = nil, slug: String? = nil, name: String? = nil,
         category: String? = nil, tags: [String]? = nil, prompt: String? = nil,
         mode: String? = nil, type: String? = nil, skipPreamble: Bool? = nil,
         purpose: String? = nil, requirements: [String]? = nil, kind: String? = nil) {
        self.id = id; self.slug = slug; self.name = name; self.category = category
        self.tags = tags; self.prompt = prompt; self.mode = mode; self.type = type
        self.skipPreamble = skipPreamble
        self.purpose = purpose; self.requirements = requirements; self.kind = kind
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
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        requirements = try c.decodeIfPresent([String].self, forKey: .requirements)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
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
    /// entries that were not synced: those the include filter rejected, and
    /// content duplicates (same name AND same body) collapsed into an earlier
    /// entry. `skipped` feeds the sync ack, so the phone's "synced N" always
    /// equals the number of rows it will show.
    static func map(catalog: VibeCutCatalog) -> (entries: [PromptEntry], skipped: Int) {
        let included = catalog.prompts.filter(isInheritable)
        var skipped = catalog.prompts.count - included.count

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
        // (raw name, body) → index of the entry that owns that content. Keyed on
        // the raw name, not the label, so two unnamed copies still match before
        // each is handed its own `untitled-N` fallback (Q-27).
        var entryIndexByContent: [ContentKey: Int] = [:]

        for p in sorted {
            let name = p.name ?? ""
            let key = ContentKey(name: name, body: p.prompt ?? "")
            if let owner = entryIndexByContent[key] {
                // Same name and same body would otherwise become a second row,
                // identical on screen and differing only by an id suffix —
                // exactly what "sync duplicated my prompts" looks like. Fold it
                // in, keeping any tags the first copy did not carry.
                let kept = entries[owner]
                entries[owner] = PromptEntry(id: kept.id, label: kept.label, body: kept.body,
                                             tags: dedupePreservingOrder((kept.tags ?? []) + tags(for: p)),
                                             targetAgent: nil, description: nil)
                skipped += 1
                continue
            }
            var core = slug(name)
            if core.isEmpty {
                fallbackCounter += 1
                core = "untitled-\(fallbackCounter)"
            }
            let id = uniqueID(idPrefix + core, used: &used)
            // One line: the Mac writes the label as the file's `# ` header, and a
            // newline from an imported pack would start a header line of its own.
            let label = name.isEmpty ? core : singleLine(name)

            entryIndexByContent[key] = entries.count
            entries.append(PromptEntry(id: id, label: label, body: p.prompt ?? "",
                                       tags: tags(for: p), targetAgent: nil, description: nil))
        }
        return (entries, skipped)
    }

    /// A VibeCut entry inherits iff it is a real text prompt: a non-empty body, a
    /// text (or absent) type, and not a send-immediately shortcut. `kind` overrides
    /// that: `runtime-command` / `local-command` never inherit; `prompt` ignores
    /// `mode` (a send-mode prompt like "Proceed" is still a prompt).
    static func isInheritable(_ p: VibeCutPrompt) -> Bool {
        if p.kind == "runtime-command" || p.kind == "local-command" { return false }
        guard let body = p.prompt, !body.isEmpty else { return false }
        let typeOK = (p.type == nil || p.type == "text")
        if p.kind == "prompt" { return typeOK }
        let modeOK = (p.mode != "send")
        return typeOK && modeOK
    }

    /// Fill the organization fields from `prompt-organization.json` annotations,
    /// matched by prompt `id`. Only nil fields are filled: an explicit row field
    /// wins, including an explicit empty `requirements: []` (VibeCut's
    /// `applyOrganization` has the same precedence).
    static func applyOrganization(in catalog: VibeCutCatalog,
                                  annotations: [String: VibeCutPrompt.Organization]) -> VibeCutCatalog {
        guard !annotations.isEmpty else { return catalog }
        var out = catalog
        for i in out.prompts.indices {
            guard let id = out.prompts[i].id, let note = annotations[id] else { continue }
            if out.prompts[i].purpose == nil { out.prompts[i].purpose = note.purpose }
            if out.prompts[i].requirements == nil { out.prompts[i].requirements = note.requirements }
            if out.prompts[i].kind == nil { out.prompts[i].kind = note.kind }
        }
        return out
    }

    /// Decode `{"actions": {id: {purpose, requirements, kind}}}`. Bad JSON or
    /// shape reads as no annotations; non-dict entries are skipped and non-string
    /// values ignored (non-string items inside `requirements` are dropped).
    static func decodeOrganization(_ data: Data) -> [String: VibeCutPrompt.Organization] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = object["actions"] as? [String: Any] else { return [:] }
        var out: [String: VibeCutPrompt.Organization] = [:]
        for (id, value) in actions {
            guard let entry = value as? [String: Any] else { continue }
            out[id] = VibeCutPrompt.Organization(
                purpose: entry["purpose"] as? String,
                requirements: (entry["requirements"] as? [Any])?.compactMap { $0 as? String },
                kind: entry["kind"] as? String)
        }
        return out
    }

    /// Fill VibeCut's `{{name}}` placeholders from `shared/prompt-fragments.json`,
    /// as VibeCut's own `prompt_fragments.py` / `PromptFragments.swift` do: one
    /// pass, names of `[a-z0-9-]` only, unknown names (and the compiler-owned
    /// `{{screenshot}}`) left verbatim. Without this, Autopilot, Enforce PRD and
    /// Plan Orchestrator reached the phone with a literal `{{merge-back}}` where
    /// VibeCut pastes its merge-back rules (Q-74).
    static func expandFragments(in catalog: VibeCutCatalog, fragments: [String: String]) -> VibeCutCatalog {
        guard !fragments.isEmpty else { return catalog }
        var out = catalog
        for i in out.prompts.indices {
            if let body = out.prompts[i].prompt {
                out.prompts[i].prompt = expandFragments(body, fragments: fragments)
            }
        }
        return out
    }

    static func expandFragments(_ text: String, fragments: [String: String]) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = afterOpen[..<close.lowerBound]
            let isName = !name.isEmpty && name.allSatisfy {
                ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
            }
            if isName, let body = fragments[String(name)] {
                out += body
                rest = afterOpen[close.upperBound...]
            } else {
                // Not a fragment: keep the "{{" and rescan just after it, so
                // "{{{{merge-back}}" still finds the inner placeholder.
                out += "{{"
                rest = afterOpen
            }
        }
        out += rest
        return out
    }

    /// Decode `{"fragments": {name: body}}`; anything else reads as no fragments.
    static func decodeFragments(_ data: Data) -> [String: String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["fragments"] as? [String: Any] else { return [:] }
        return raw.compactMapValues { $0 as? String }
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

    private struct ContentKey: Hashable {
        let name: String
        let body: String
    }

    /// `vibecut` first, then the category, then the prompt's own tags, then
    /// `purpose:<p>` and `needs:<r>` per requirement, deduped. The `purpose:` /
    /// `needs:` spellings are a contract with the iOS filters — do not rename.
    private static func tags(for p: VibeCutPrompt) -> [String] {
        var tags = [providerTag]
        if let cat = p.category, !cat.isEmpty { tags.append(cat) }
        if let extra = p.tags { for t in extra where !t.isEmpty { tags.append(t) } }
        if let purpose = p.purpose, !purpose.isEmpty { tags.append("purpose:\(purpose)") }
        if let needs = p.requirements { for r in needs where !r.isEmpty { tags.append("needs:\(r)") } }
        // The Mac stores tags as one comma-separated `tags:` line in the file's
        // meta block (Q-78). A comma or line break from an imported pack would
        // split a tag or add an `agent:` / `desc:` line, so such a tag is dropped.
        return dedupePreservingOrder(tags.filter { tag in
            !tag.contains(where: { $0 == "," || $0.isNewline })
        })
    }

    private static func singleLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

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
