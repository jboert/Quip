import Foundation

/// Editing a keyboard button from the row itself (Q-67). A custom button is
/// edited in place. A built-in's label and command are fixed in the
/// `QuickButton` enum, so editing one makes a custom copy that takes the
/// built-in's place in the row and keeps its color.
enum QuickButtonEdit {

    /// A custom button that does what `button` does, ready to edit. Nil for
    /// Broadcast, which opens a phone sheet and has no text or keystroke.
    static func customCopy(of button: QuickButton, id: UUID = UUID()) -> CustomButton? {
        let payload: CustomPayload
        switch button.action {
        case .sendText(let text, let pressReturn):
            payload = text.hasPrefix("/")
                ? .slash(text: text, autoSubmit: pressReturn)
                : .rawText(text: text, autoSubmit: pressReturn)
        case .quickAction(let action):
            payload = .keystroke(action: action)
        case .openBroadcast:
            return nil
        }
        // Icon-only built-ins have an empty pill label; the form needs a name.
        let label = button.label.isEmpty ? button.displayName : button.label
        // Keeps the built-in's agents, so the copy stays out of the same
        // windows' palettes (Q-72).
        let agents = button.agents.map(\.rawValue).sorted()
        return CustomButton(id: id, label: label, systemImage: button.systemImage, payload: payload,
                            agentIDs: agents.isEmpty ? nil : agents)
    }

    /// The custom button the edit form opens with for `slot`, or nil when the
    /// slot can't be edited this way (prompts, spacers, Broadcast, a custom
    /// whose definition is gone).
    static func editable(_ slot: QuickSlot, defs: [CustomButton]) -> CustomButton? {
        switch slot {
        case .builtin(let b): return customCopy(of: b)
        case .custom(let id): return defs.first { $0.id == id }
        case .prompt, .promptsPicker, .spacer: return nil
        }
    }

    struct Result: Equatable {
        var slots: [QuickSlot]
        var defs: [CustomButton]
        var colors: [String: String]
    }

    /// Saves `edited` over `slot`. A custom slot's definition is replaced by
    /// id. A built-in slot gets `edited` as a new definition, and every place
    /// the built-in held in the row now points at it, with its color moved
    /// across.
    static func save(_ edited: CustomButton, over slot: QuickSlot,
                     slots: [QuickSlot], defs: [CustomButton],
                     colors: [String: String]) -> Result {
        var out = Result(slots: slots, defs: defs, colors: colors)
        switch slot {
        case .custom:
            if let i = out.defs.firstIndex(where: { $0.id == edited.id }) {
                out.defs[i] = edited
            } else {
                out.defs.append(edited)
            }
        case .builtin:
            out.defs.append(edited)
            let replacement = QuickSlot.custom(edited.id)
            out.slots = slots.map { $0 == slot ? replacement : $0 }
            if let tint = out.colors.removeValue(forKey: slot.id) {
                out.colors[replacement.id] = tint
            }
        case .prompt, .promptsPicker, .spacer:
            break
        }
        return out
    }

    /// The row without `slot`. The custom definition stays, so the button can
    /// be put back from Settings → Quick Buttons → +.
    static func removing(_ slot: QuickSlot, from slots: [QuickSlot]) -> [QuickSlot] {
        slots.filter { $0 != slot }
    }

    /// Undo for `removing`: `slot` back at `index`, or at the end when the
    /// row has since shrunk. A slot already back in the row is left alone.
    static func restoring(_ slot: QuickSlot, at index: Int, in slots: [QuickSlot]) -> [QuickSlot] {
        guard !slots.contains(slot) else { return slots }
        var out = slots
        out.insert(slot, at: min(max(index, 0), out.count))
        return out
    }

    /// The row with a new spacer right after `slot`, or at the end when
    /// `slot` is no longer in the row. Drag the spacer to move it.
    static func addingSpacer(after slot: QuickSlot, in slots: [QuickSlot],
                             id: UUID = UUID()) -> [QuickSlot] {
        var out = slots
        let at = out.firstIndex(of: slot).map { $0 + 1 } ?? out.endIndex
        out.insert(.spacer(id), at: at)
        return out
    }
}
