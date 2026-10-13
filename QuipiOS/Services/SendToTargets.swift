import Foundation

/// The windows a keyboard button can be sent to from its hold menu (Q-51,
/// "Send to…"): terminals only, the selected one first and marked, the rest
/// by folder.
enum SendToTargets {
    struct Target: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
        let color: String
        let isCurrent: Bool
    }

    static func targets(from windows: [WindowState], selectedID: String?) -> [Target] {
        let terminals = windows.filter(\.isTerminal)
        let current = terminals.filter { $0.id == selectedID }
        let others = terminals.filter { $0.id != selectedID }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        return (current + others).map { w in
            // With no folder the title is already the window name.
            let hasFolder = !(w.folder ?? "").isEmpty
            return Target(id: w.id, title: w.displayTitle,
                          detail: hasFolder ? "\(w.app) · \(w.name)" : w.app,
                          color: w.color, isCurrent: w.id == selectedID)
        }
    }
}

/// What a keyboard button sends, apart from which window it goes to, so
/// "Send to…" can aim the same action at a window other than the selected one.
enum QuickSend: Equatable {
    case text(String, pressReturn: Bool)
    case keystroke(String)
    case prompt(id: String, pressReturn: Bool)

    /// Nil for slots that send nothing themselves: Broadcast (opens its own
    /// sheet), the Prompts picker, spacers, a custom whose definition is gone.
    static func action(for slot: QuickSlot, defs: [CustomButton]) -> QuickSend? {
        switch slot {
        case .builtin(let b):
            switch b.action {
            case .sendText(let text, let pressReturn): return .text(text, pressReturn: pressReturn)
            case .quickAction(let action): return .keystroke(action)
            case .openBroadcast: return nil
            }
        case .custom(let id):
            switch defs.first(where: { $0.id == id })?.payload {
            case .slash(let text, let auto), .rawText(let text, let auto): return .text(text, pressReturn: auto)
            case .keystroke(let action): return .keystroke(action)
            case nil: return nil
            }
        case .prompt(let pid):
            return .prompt(id: pid, pressReturn: false)
        case .promptsPicker, .spacer:
            return nil
        }
    }

    /// Text that a tap only types, and prompts, can be sent with or without
    /// Return. A key, or text that already submits, sends as it is.
    var offersReturnChoice: Bool {
        switch self {
        case .text(_, let pressReturn): return !pressReturn
        case .prompt: return true
        case .keystroke: return false
        }
    }

    func pressingReturn(_ on: Bool) -> QuickSend {
        guard offersReturnChoice else { return self }
        switch self {
        case .text(let text, _): return .text(text, pressReturn: on)
        case .prompt(let id, _): return .prompt(id: id, pressReturn: on)
        case .keystroke: return self
        }
    }
}
