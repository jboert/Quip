import Foundation

/// The library prompt a broadcast draft was filled from.
struct BroadcastSource: Equatable, Sendable {
    let promptID: String
    let body: String
}

/// How a broadcast reaches each window (PRD broadcast-and-search, US-107).
///
/// Only the Mac can fill `{{folder}}`, `{{agent}}` and the other
/// placeholders, and only when it pastes a library prompt by id. So a draft
/// that is still exactly the chosen prompt goes as `paste_prompt`, one per
/// window, and each window gets its own values. Any edit makes it the user's
/// text, sent through `send_text` as written, placeholders and all.
enum BroadcastRoute: Equatable, Sendable {
    /// Unmodified library prompt: the Mac fills `{{…}}` per window.
    case pastePrompt(id: String)
    /// Typed or edited text, sent as written (normalized).
    case sendText(String)

    /// Whitespace around the text is not an edit: the field adds and drops
    /// it freely, and the send trims it anyway.
    static func route(text: String, source: BroadcastSource?) -> BroadcastRoute {
        let normalized = BroadcastPromptPlan.normalizedText(text)
        if let source, normalized == BroadcastPromptPlan.normalizedText(source.body) {
            return .pastePrompt(id: source.promptID)
        }
        return .sendText(normalized)
    }

    /// The line under the field when typed or edited text carries
    /// placeholders the Mac will not fill, else nil. Names appear as
    /// `PromptTemplate.variables` reads them (lowercased, first appearance
    /// first); past three, the rest are counted.
    static func placeholderHint(text: String, source: BroadcastSource?) -> String? {
        guard case .sendText = route(text: text, source: source) else { return nil }
        let names = PromptTemplate.variables(in: text).map { "{{\($0)}}" }
        let list: String
        switch names.count {
        case 0: return nil
        case 1: return "Edited text is sent as written; \(names[0]) is not filled."
        case 2, 3: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: list = names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
        return "Edited text is sent as written; \(list) are not filled."
    }
}
