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
/// the per-prompt hide filter) and its id is namespaced `vibecut__<slug>` (the slug of the name when first seen; see
/// `map(catalog:knownIDs:)`) so the
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
    /// Projects this prompt belongs to (VibeCut's private project store). Each
    /// becomes a `project:<name>` tag, and any prompt with projects is tagged
    /// `local-only` so it never leaves the owner's devices.
    var projects: [String]?
    /// Set by the Mac reader for a prompt that came from VibeCut's private
    /// project store. Never decoded from JSON: a shared catalog or pack cannot
    /// claim to be (or avoid being) private by carrying this field itself.
    var fromPrivateStore: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, slug, name, category, tags, prompt, mode, type, purpose, requirements, kind, projects
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
         purpose: String? = nil, requirements: [String]? = nil, kind: String? = nil,
         projects: [String]? = nil, fromPrivateStore: Bool = false) {
        self.id = id; self.slug = slug; self.name = name; self.category = category
        self.tags = tags; self.prompt = prompt; self.mode = mode; self.type = type
        self.skipPreamble = skipPreamble
        self.purpose = purpose; self.requirements = requirements; self.kind = kind
        self.projects = projects; self.fromPrivateStore = fromPrivateStore
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
        projects = try? c.decodeIfPresent([String].self, forKey: .projects)
    }

    /// Encoded without `fromPrivateStore` on purpose (see the property).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(slug, forKey: .slug)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(skipPreamble, forKey: .skipPreamble)
        try c.encodeIfPresent(purpose, forKey: .purpose)
        try c.encodeIfPresent(requirements, forKey: .requirements)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(projects, forKey: .projects)
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
        let r = map(catalog: catalog, knownIDs: [:])
        return (r.entries, r.skipped)
    }

    /// Same mapping, but a prompt keeps the Quip id an earlier sync gave its VibeCut
    /// source `id`, so renaming it in VibeCut does not mint a new phone prompt and
    /// lose its hide state, project tags and usage ranking (Q-79). `knownIDs` is
    /// source id → Quip id; the returned `idMap` is that map updated for this run.
    ///   - Known ids are reserved BEFORE any name-derived id is assigned, so a new
    ///     prompt whose slug equals a reserved id takes a `-2` suffix instead.
    ///   - If two present sources claim one Quip id, the first in the sort order
    ///     below keeps it and the other is re-derived from its name.
    ///   - Map values outside the `vibecut__` namespace are ignored (and dropped):
    ///     the Mac deletes `vibecut__*` files, so the map must never point at a
    ///     user's own file.
    ///   - Entries for sources absent from this catalog are kept, so a prompt that
    ///     comes back reuses its id. A prompt with no source id gets a name-derived
    ///     id and no map entry; a collapsed content duplicate adds none either.
    static func map(catalog: VibeCutCatalog, knownIDs: [String: String])
        -> (entries: [PromptEntry], skipped: Int, idMap: [String: String]) {
        let known = knownIDs.filter { !$0.key.isEmpty && $0.value.hasPrefix(idPrefix) }
        let included = catalog.prompts.filter(isInheritable)
        var skipped = catalog.prompts.count - included.count

        // Deterministic ordering so collision suffixes (-2/-3) and output order are
        // stable across runs: sort by display name, then by source id.
        let sorted = included.sorted { lhs, rhs in
            let ln = lhs.name ?? "", rn = rhs.name ?? ""
            if ln != rn { return ln < rn }
            return (lhs.id ?? "") < (rhs.id ?? "")
        }

        // Reserve every kept id up front. Walks the same content-dedupe as the main
        // loop so a collapsed duplicate never holds an id for a row that is not there.
        var used = Set<String>()
        var keptID: [Int: String] = [:]
        var seenContent = Set<ContentKey>()
        for (i, p) in sorted.enumerated() {
            guard seenContent.insert(ContentKey(name: p.name ?? "", body: p.prompt ?? "")).inserted,
                  let sourceID = p.id, let id = known[sourceID], used.insert(id).inserted
            else { continue }
            keptID[i] = id
        }
        var idMap = known
        var mappedThisRun = Set<String>()

        var fallbackCounter = 0
        var entries: [PromptEntry] = []
        entries.reserveCapacity(sorted.count)
        // (raw name, body) → index of the entry that owns that content. Keyed on
        // the raw name, not the label, so two unnamed copies still match before
        // each is handed its own `untitled-N` fallback (Q-27).
        var entryIndexByContent: [ContentKey: Int] = [:]

        for (i, p) in sorted.enumerated() {
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
            // A private-store prompt is named by its opaque source id, so the
            // prompt's name never lands in the Quip id (ids reach logs, usage
            // history and the quick-button row).
            var core = slug(p.fromPrivateStore ? (p.id ?? name) : name)
            if core.isEmpty {
                fallbackCounter += 1
                core = "untitled-\(fallbackCounter)"
            }
            let id = keptID[i] ?? uniqueID(idPrefix + core, used: &used)
            // First owner per source id only: a source id repeated across packs must
            // not hand its map entry to the second row and swap ids next sync.
            if let sourceID = p.id, !sourceID.isEmpty, mappedThisRun.insert(sourceID).inserted {
                idMap[sourceID] = id
            }
            // One line: the Mac writes the label as the file's `# ` header, and a
            // newline from an imported pack would start a header line of its own.
            let label = name.isEmpty ? core : singleLine(name)

            entryIndexByContent[key] = entries.count
            entries.append(PromptEntry(id: id, label: label, body: p.prompt ?? "",
                                       tags: tags(for: p), targetAgent: nil, description: nil))
        }
        return (entries, skipped, idMap)
    }

    /// A VibeCut entry inherits iff it is a real text prompt: a non-empty body, a
    /// text (or absent) type, and not a send-immediately shortcut. `kind` overrides
    /// that: `runtime-command` / `local-command` never inherit; `prompt` ignores
    /// `mode` (a send-mode prompt like "Proceed" is still a prompt).
    static func isInheritable(_ p: VibeCutPrompt) -> Bool {
        if p.kind == "runtime-command" || p.kind == "local-command" { return false }
        guard let body = p.prompt, !body.isEmpty else { return false }
        let typeOK = (p.type == nil || p.type == "text")
        // A project prompt is something the owner wrote for a project; its
        // mode (paste or send) is VibeCut's tap behaviour, not a reason to skip.
        if p.kind == "prompt" || p.fromPrivateStore { return typeOK }
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
        let projects = (p.projects ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for name in projects { tags.append("project:\(name)") }
        if !projects.isEmpty || p.fromPrivateStore { tags.append(PromptPrivacy.localOnlyTag) }
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

/// Which prompts must stay on the owner's own devices. A prompt tagged
/// `local-only` (every VibeCut project prompt) is never sent over the
/// Cloudflare tunnel and never recorded in iCloud. Pure, shared by Mac and phone.
enum PromptPrivacy {
    static let localOnlyTag = "local-only"

    static func isLocalOnly(_ entry: PromptEntry) -> Bool {
        (entry.tags ?? []).contains { $0.lowercased() == localOnlyTag }
    }

    static func localOnlyIDs(_ entries: [PromptEntry]) -> Set<String> {
        Set(entries.filter(isLocalOnly).map(\.id))
    }

    /// `entries` without the local-only ones.
    static func strippingLocalOnly(_ entries: [PromptEntry]) -> [PromptEntry] {
        entries.filter { !isLocalOnly($0) }
    }
}
