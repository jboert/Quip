import Foundation

/// The main button row's order, user-arranged by hold-and-drag (Q-65).
/// Visibility stays on the `mainRow.*` toggles; this is only the sequence.
/// The mic is an item too, so dragging past it moves a button from one
/// side of the mic to the other, but the mic itself is never dragged.
enum MainRowOrder {
    static let cycleLeft = "cycleLeft"
    static let cycleRight = "cycleRight"
    static let spawn = "spawn"
    static let arrange = "arrange"
    static let mic = "mic"
    static let broadcast = "broadcast"
    static let photo = "photo"
    static let prompts = "prompts"
    static let keyboard = "keyboard"
    static let `return` = "return"

    static let defaultOrder: [String] = [cycleLeft, cycleRight, spawn, arrange, mic, broadcast, photo, prompts, keyboard, `return`]

    /// PURE: a saved order with unknown ids dropped, duplicates removed, and
    /// any id it lacks (a button added in a later version) appended where
    /// the default puts it relative to the mic. Empty or broken JSON is the
    /// default order.
    static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let saved = try? JSONDecoder().decode([String].self, from: data) else { return defaultOrder }
        let known = Set(defaultOrder)
        var seen = Set<String>()
        var order = saved.filter { known.contains($0) && seen.insert($0).inserted }
        if order.isEmpty { return defaultOrder }
        if !order.contains(mic) { order.insert(mic, at: order.count / 2) }
        for id in defaultOrder where !order.contains(id) {
            // Keep a new button on the side of the mic the default has it.
            let micAt = order.firstIndex(of: mic)!
            let defaultMic = defaultOrder.firstIndex(of: mic)!
            let defaultAt = defaultOrder.firstIndex(of: id)!
            order.insert(id, at: defaultAt < defaultMic ? micAt : order.count)
        }
        return order
    }

    static func encode(_ order: [String]) -> String {
        (try? JSONEncoder().encode(order)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Tile sizes for the main row. `fitted` shrinks every width in proportion
/// when the visible buttons would not fit the row, so adding a button (or
/// the Prompts tile switching itself on) never pushes the row off-screen.
struct MainRowSizes: Equatable {
    var navW: CGFloat, navH: CGFloat
    var btnW: CGFloat, btnH: CGFloat
    var auxW: CGFloat, auxH: CGFloat
    var pttW: CGFloat
    var bcW: CGFloat = 30

    static let itemSpacing: CGFloat = 6
    static let micGap: CGFloat = 8

    func width(of id: String) -> CGFloat {
        switch id {
        case MainRowOrder.cycleLeft, MainRowOrder.cycleRight: return navW
        case MainRowOrder.spawn, MainRowOrder.arrange, MainRowOrder.prompts, MainRowOrder.keyboard: return auxW
        case MainRowOrder.photo, MainRowOrder.return: return btnW
        case MainRowOrder.broadcast: return bcW
        case MainRowOrder.mic: return pttW
        default: return 0
        }
    }

    /// PURE: the row's width at these sizes for `visible` (which includes the
    /// mic): tiles, 6 pt between neighbours in a group, 8 pt either side of
    /// the mic.
    func naturalWidth(for visible: [String]) -> CGFloat {
        let micAt = visible.firstIndex(of: MainRowOrder.mic) ?? visible.count
        let left = visible.prefix(micAt)
        let right = visible.dropFirst(min(micAt + 1, visible.count))
        func group(_ ids: ArraySlice<String>) -> CGFloat {
            ids.reduce(0) { $0 + width(of: $1) } + CGFloat(max(ids.count - 1, 0)) * Self.itemSpacing
        }
        return group(left) + group(right) + pttW + 2 * Self.micGap
    }

    /// PURE: these sizes, widths scaled down so `visible` fits `available`.
    /// Heights never change; nothing scales below 60 % so icons stay legible.
    func fitted(to available: CGFloat, visible: [String]) -> MainRowSizes {
        let natural = naturalWidth(for: visible)
        guard available > 0, natural > available else { return self }
        let fixed = CGFloat(max(visible.count - 1 - 2, 0)) * Self.itemSpacing + 2 * Self.micGap
        let scale = max(0.6, (available - fixed) / max(natural - fixed, 1))
        var out = self
        out.navW = (navW * scale).rounded(.down)
        out.btnW = (btnW * scale).rounded(.down)
        out.auxW = (auxW * scale).rounded(.down)
        out.pttW = (pttW * scale).rounded(.down)
        out.bcW = (bcW * scale).rounded(.down)
        return out
    }
}
