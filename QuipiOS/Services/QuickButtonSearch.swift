import Foundation

/// What a quick button can be found by (PRD broadcast-and-search, US-103):
/// the short label on the key, the full name from Settings, its id, and what
/// it sends, so "escape" finds Esc and "yes" finds Y.
extension QuickButton: QuipSearchable {
    var searchFields: [QuipSearchField] {
        var fields: [QuipSearchField] = []
        if !label.isEmpty { fields.append(QuipSearchField(.name, label)) }
        if displayName != label { fields.append(QuipSearchField(.name, displayName)) }
        fields.append(QuipSearchField(.id, rawValue))
        switch action {
        case .sendText(let text, _): fields.append(QuipSearchField(.body, text))
        case .quickAction(let name): fields.append(QuipSearchField(.body, name))
        }
        return fields
    }
}

extension CustomButton: QuipSearchable {
    var searchFields: [QuipSearchField] {
        [QuipSearchField(.name, label), QuipSearchField(.body, QuickButtonSearch.sentText(payload))]
    }
}

enum QuickButtonSearch {
    /// One row of the Quick Buttons editor's Row Order list.
    struct SlotRow: QuipSearchable {
        let slot: QuickSlot
        let searchFields: [QuipSearchField]
    }

    /// The entries at the top of the Add Button sheet, above the built-ins.
    enum AddItem: Hashable, QuipSearchable {
        case customButton, spacer, onePrompt, promptsPicker

        var searchFields: [QuipSearchField] {
            switch self {
            case .customButton:
                return [QuipSearchField(.name, "Custom Button…"),
                        QuipSearchField(.description, "Make your own slash, text or keystroke button")]
            case .spacer:
                return [QuipSearchField(.name, "Spacer"), QuipSearchField(.description, "Fixed gap between buttons")]
            case .onePrompt:
                return [QuipSearchField(.name, "One prompt as its own button…")]
            case .promptsPicker:
                return [QuipSearchField(.name, "Prompts button (opens all prompts)")]
            }
        }
    }

    /// The text a custom button sends, as searched and summarised.
    static func sentText(_ payload: CustomPayload) -> String {
        switch payload {
        case .slash(let text, _), .rawText(let text, _): return text
        case .keystroke(let action): return action
        }
    }

    /// What a Row Order slot can be found by. A spacer has nothing to find
    /// and never matches a query. A prompt slot whose prompt the phone has
    /// not seen yet is found by its id.
    static func row(_ slot: QuickSlot, customs: [UUID: CustomButton],
                    promptLabels: [String: String]) -> SlotRow {
        let fields: [QuipSearchField]
        switch slot {
        case .builtin(let button):
            fields = button.searchFields
        case .custom(let id):
            fields = customs[id]?.searchFields ?? [QuipSearchField(.name, "Custom button")]
        case .prompt(let promptID):
            fields = [QuipSearchField(.name, promptLabels[promptID] ?? promptID), QuipSearchField(.id, promptID)]
        case .promptsPicker:
            fields = [QuipSearchField(.name, "Prompts"),
                      QuipSearchField(.description, "Opens all prompts, ranked by use")]
        case .spacer:
            fields = []
        }
        return SlotRow(slot: slot, searchFields: fields)
    }

    /// The items that match `query`, best first; all of them, in order,
    /// without a query. An item with no search fields matches only the
    /// empty query.
    static func filter<Item: QuipSearchable>(_ items: [Item], query: String) -> [Item] {
        guard !QuipSearch.tokens(query).isEmpty else { return items }
        return QuipSearch.search(items, query: query).map(\.item)
    }
}
