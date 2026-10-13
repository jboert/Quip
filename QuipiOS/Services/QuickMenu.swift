import Foundation

/// One entry in the menu a held quick-row button shows (Q-67).
///
/// The hold menu and VoiceOver's Actions rotor are built from the same list
/// (Q-51 US-212), so a VoiceOver user, who cannot hold a pill still, reaches
/// every action a sighted user can, under the same name.
enum QuickMenuItem: String, CaseIterable, Identifiable {
    case pasteAndSend
    case allSlashCommands
    case sendTo
    case edit
    case color
    case addSpacerAfter
    case remove

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteAndSend: return "Paste & Send"
        case .allSlashCommands: return "All Slash Commands…"
        case .sendTo: return "Send to…"
        case .edit: return "Edit…"
        case .color: return "Color…"
        case .addSpacerAfter: return "Add Spacer After"
        case .remove: return "Remove from Row"
        }
    }

    var isDestructive: Bool { self == .remove }
}

enum QuickMenu {
    /// What the view knows about a slot that decides its menu. Kept as plain
    /// flags so the order and the conditions are testable without a view.
    struct Facts: Equatable {
        var isPrompt = false
        var isSlash = false
        var isSpacer = false
        var canSendTo = false
        var canEdit = false
    }

    /// The menu items for a slot, in menu order.
    static func items(_ facts: Facts) -> [QuickMenuItem] {
        var items: [QuickMenuItem] = []
        if facts.isPrompt { items.append(.pasteAndSend) }
        if facts.isSlash { items.append(.allSlashCommands) }
        if facts.canSendTo { items.append(.sendTo) }
        if facts.canEdit { items.append(.edit) }
        if !facts.isSpacer { items.append(.color) }
        items.append(.addSpacerAfter)
        items.append(.remove)
        return items
    }
}
