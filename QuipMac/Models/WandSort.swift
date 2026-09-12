// WandSort.swift
// QuipMac — What the sidebar's magic-wand button does, and what it acts on.

import Foundation

/// The orders the wand can snap the sidebar into.
///
/// One tap applies one mode and advances to the next, because a single fixed
/// order cannot serve both "show me what needs me" and "show me what is
/// running". The rotation replaced an on/off toggle: the old second tap turned
/// every dev window back OFF, so double-clicking the wand reliably ended with
/// nothing selected and looked broken.
enum WandSortMode: String, CaseIterable, Identifiable, Sendable {
    /// Terminals (waiting-for-input first) → simulators → everything else,
    /// then by project subtitle. The original wand behaviour.
    case devFocused
    /// Whatever is producing output right now, newest first. Windows never
    /// observed to change sort last — "never moved" is not "moved long ago".
    case mostActive
    /// Anything waiting for you above everything else, regardless of kind.
    case attentionFirst

    var id: String { rawValue }

    var label: String {
        switch self {
        case .devFocused:     return "Dev"
        case .mostActive:     return "Active"
        case .attentionFirst: return "Waiting"
        }
    }

    var help: String {
        switch self {
        case .devFocused:     return "Terminals, then simulators, then everything else"
        case .mostActive:     return "Producing output most recently, first"
        case .attentionFirst: return "Waiting for input, first"
        }
    }

    /// Parse the stored preference. Unknown ids are dropped rather than
    /// defaulted, so a mode removed in a later build cannot resurrect itself as
    /// something else; an empty result falls back to the full rotation, because
    /// a wand that sorts into nothing is worse than one that ignores the
    /// setting.
    static func rotation(fromStored raw: String) -> [WandSortMode] {
        let parsed = raw.split(separator: ",").compactMap { WandSortMode(rawValue: String($0)) }
        return parsed.isEmpty ? allCases : parsed
    }

    static func stored(_ modes: [WandSortMode]) -> String {
        modes.map(\.rawValue).joined(separator: ",")
    }
}

/// Window kinds the wand switches on. Stored as a raw Int in `@AppStorage`.
///
/// Previously hardcoded as "tier 0 or 1", which silently meant iTerm2 AND
/// Terminal.app AND simulators — the reason a wand tap never selected just the
/// iTerm2 windows.
struct WandTargetKinds: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let iterm2      = WandTargetKinds(rawValue: 1 << 0)
    static let terminalApp = WandTargetKinds(rawValue: 1 << 1)
    static let simulator   = WandTargetKinds(rawValue: 1 << 2)

    /// The historical behaviour, so an existing install sees no change until it
    /// opts into something narrower.
    static let `default`: WandTargetKinds = [.iterm2, .terminalApp, .simulator]

    /// A stored 0 means "no kinds", which would make the wand do nothing at all
    /// and read as a broken button. Treat it as the default instead — the
    /// setting is a filter, not an off switch.
    static func fromStored(_ raw: Int) -> WandTargetKinds {
        raw == 0 ? .default : WandTargetKinds(rawValue: raw)
    }
}

/// One window, reduced to what the sort actually needs.
///
/// Deliberately not `ManagedWindow`: the ordering rules are the part worth
/// testing, and they have no business depending on window geometry, bundle ids,
/// or anything else that would drag AppKit into a unit test.
struct WandSortItem: Sendable, Equatable {
    let id: String
    /// 0 = terminal, 1 = simulator, 2 = everything else.
    let tier: Int
    let subtitle: String
    let isWaitingForInput: Bool
    let lastOutputChangeAt: Date?
}

enum WandSort {

    /// Order `items` for `mode`, returning window ids.
    ///
    /// Every mode ends with the same two tiebreaks — subtitle, then incoming
    /// position — so a tap is stable: tapping twice in the same mode never
    /// reshuffles equal windows, which would make the button feel random.
    static func order(_ items: [WandSortItem], mode: WandSortMode) -> [String] {
        items.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            switch mode {
            case .devFocused:
                if a.tier != b.tier { return a.tier < b.tier }
                // Within terminals only: the one that needs you is #1.
                if a.tier == 0, a.isWaitingForInput != b.isWaitingForInput {
                    return a.isWaitingForInput
                }
            case .mostActive:
                if a.lastOutputChangeAt != b.lastOutputChangeAt {
                    // A window never observed to change is not "changed long
                    // ago" — it goes last, behind everything that has moved.
                    switch (a.lastOutputChangeAt, b.lastOutputChangeAt) {
                    case let (l?, r?): return l > r
                    case (nil, _?):    return false
                    case (_?, nil):    return true
                    case (nil, nil):   break
                    }
                }
            case .attentionFirst:
                if a.isWaitingForInput != b.isWaitingForInput { return a.isWaitingForInput }
                if a.tier != b.tier { return a.tier < b.tier }
            }
            let sa = a.subtitle.lowercased(), sb = b.subtitle.lowercased()
            if sa != sb { return sa < sb }
            return lhs.offset < rhs.offset
        }.map(\.element.id)
    }

    /// The next mode in the rotation. Wraps, and survives a rotation the user
    /// has since shortened in Settings — a stored index past the end comes back
    /// as the first mode rather than trapping the wand on nothing.
    static func advance(index: Int, rotation: [WandSortMode]) -> Int {
        guard !rotation.isEmpty else { return 0 }
        return (max(index, 0) + 1) % rotation.count
    }

    static func mode(at index: Int, rotation: [WandSortMode]) -> WandSortMode {
        guard !rotation.isEmpty else { return .devFocused }
        return rotation[min(max(index, 0), rotation.count - 1) % rotation.count]
    }
}
