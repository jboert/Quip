import Foundation

/// The prompt mode selected when a `ContentShareDraft` is turned into agent text.
///
/// Raw values are the stable, wire-safe identifiers used by the `quip://share`
/// deep link `mode` parameter and by non-Swift producers (nugget-expo,
/// FintechAdventures). Do not rename without updating the integration contract.
public enum ContentSharePromptMode: String, Codable, Sendable, CaseIterable {
    case summarize
    case augment_for_nugget
    case draft_followup

    /// Human-facing label for pickers.
    public var displayName: String {
        switch self {
        case .summarize: return "Summarize"
        case .augment_for_nugget: return "Augment for Nugget"
        case .draft_followup: return "Draft follow-up"
        }
    }
}

/// Renders a `ContentShareDraft` into a concise, reviewed prompt for a Quip
/// agent session (Claude, Codex, Grok, Cursor).
///
/// The output is deterministic for the same `(draft, mode)` pair — it never
/// reads the wall clock or any external state, so the same share always
/// produces byte-for-byte identical text.
public enum ContentSharePromptComposer {

    /// Compose the full prompt for `draft` in the given `mode`.
    ///
    /// The prompt always carries Source, Context, Claims, Suggested uses, and a
    /// mode-specific Requested action section. Empty sections (no summary, no
    /// claims, no suggested uses) are omitted rather than left blank, but Source
    /// attribution is never dropped when any URL is present.
    public static func compose(draft: ContentShareDraft, mode: ContentSharePromptMode) -> String {
        var sections: [String] = []

        if let source = sourceSection(for: draft) {
            sections.append(source)
        }
        if let context = contextSection(for: draft) {
            sections.append(context)
        }
        if let claims = claimsSection(for: draft) {
            sections.append(claims)
        }
        if let uses = suggestedUsesSection(for: draft) {
            sections.append(uses)
        }
        sections.append(requestedActionSection(for: mode))

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Sections

    private static func sourceSection(for draft: ContentShareDraft) -> String? {
        var lines: [String] = []
        let label = draft.sourceLabel ?? draft.sourceApp
        if let label, !label.isEmpty {
            lines.append("Title: \(draft.title) (\(label))")
        } else {
            lines.append("Title: \(draft.title)")
        }
        if let url = nonEmpty(draft.sourceUrl) {
            lines.append("Source URL: \(url)")
        }
        if let share = nonEmpty(draft.shareUrl) {
            lines.append("Share URL: \(share)")
        }
        if let published = nonEmpty(draft.publishedAt) {
            lines.append("Published: \(published)")
        }
        return "Source:\n" + lines.joined(separator: "\n")
    }

    private static func contextSection(for draft: ContentShareDraft) -> String? {
        var lines: [String] = []
        if let summary = nonEmpty(draft.summary) {
            lines.append(summary)
        }
        if !draft.entities.isEmpty {
            lines.append("Entities: \(draft.entities.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return nil }
        return "Context:\n" + lines.joined(separator: "\n")
    }

    private static func claimsSection(for draft: ContentShareDraft) -> String? {
        guard !draft.claims.isEmpty else { return nil }
        let lines = draft.claims.map { claim -> String in
            var parts = "- \(claim.text)"
            if let status = nonEmpty(claim.status) {
                parts += " [\(status)]"
            }
            if let url = nonEmpty(claim.sourceUrl) {
                parts += " (\(url))"
            }
            if let note = nonEmpty(claim.note) {
                parts += " — \(note)"
            }
            return parts
        }
        return "Claims:\n" + lines.joined(separator: "\n")
    }

    private static func suggestedUsesSection(for draft: ContentShareDraft) -> String? {
        guard !draft.suggestedUses.isEmpty else { return nil }
        let lines = draft.suggestedUses.map { "- \($0)" }
        return "Suggested uses:\n" + lines.joined(separator: "\n")
    }

    private static func requestedActionSection(for mode: ContentSharePromptMode) -> String {
        let body: String
        switch mode {
        case .summarize:
            body = "Summarize the content above in a few tight sentences. "
                + "Preserve the source attribution and flag anything that is unverified."
        case .augment_for_nugget:
            body = "Turn the content above into sales-ready Nugget context. Identify:\n"
                + "- Buyer angle: who this matters to and why now.\n"
                + "- Reusable claims: source-backed facts worth quoting.\n"
                + "- Asset gaps: what collateral is missing to act on this.\n"
                + "- Next best action: the single most useful follow-up."
        case .draft_followup:
            body = "Draft a concise follow-up message a rep could send about the content above. "
                + "Keep it grounded in the source-backed claims and end with a clear next step."
        }
        return "Requested action:\n" + body
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
