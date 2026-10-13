import Foundation

/// What a row in the Slash Commands search list offers (Q-51 / US-209, the
/// slash half): the same swipe rule as the Prompts hub, right to send and
/// left to manage.
enum SlashRowAction: Equatable {
    case send, sendTo, pinToRow, removeFromRow, edit

    var title: String {
        switch self {
        case .send: return "Send"
        case .sendTo: return "Send to…"
        case .pinToRow: return "Pin to Row"
        case .removeFromRow: return "Remove from Row"
        case .edit: return "Edit…"
        }
    }

    var systemImage: String {
        switch self {
        case .send: return "return"
        case .sendTo: return "arrow.up.forward.app"
        case .pinToRow: return "pin"
        case .removeFromRow: return "pin.slash"
        case .edit: return "pencil"
        }
    }
}

enum SlashRowActions {
    /// Edit… is for custom commands only: a built-in's command is fixed, and
    /// editing one from the row makes a copy in its place, which a command
    /// that is not in the row has no place for.
    static func menu(inRow: Bool, isCustom: Bool) -> [SlashRowAction] {
        [.send, .sendTo, inRow ? .removeFromRow : .pinToRow] + (isCustom ? [.edit] : [])
    }

    /// Swipe right. A full swipe opens Send to…, which only opens a list.
    static let leadingSwipe: [SlashRowAction] = [.sendTo]

    /// Swipe left. Full swipe is off on this edge, so a long swipe never
    /// changes the row by itself.
    static func trailingSwipe(inRow: Bool, isCustom: Bool) -> [SlashRowAction] {
        (isCustom ? [.edit] : []) + [inRow ? .removeFromRow : .pinToRow]
    }
}
