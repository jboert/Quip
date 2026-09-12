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

    /// Defence-in-depth for a corrupt or pre-migration stored value. The
    /// Settings UI refuses to let the last kind be unchecked, so an empty set
    /// should be unreachable from the app; if one arrives anyway, a wand that
    /// does nothing reads as a broken button, so fall back to the default.
    static func fromStored(_ raw: Int) -> WandTargetKinds {
        raw == 0 ? .default : WandTargetKinds(rawValue: raw)
    }

    /// The kinds in the order they rank, which is also the order the Settings
    /// checkboxes appear in — so "first in the list" means the same thing in
    /// both places.
    static let ordered: [WandTargetKinds] = [.iterm2, .terminalApp, .simulator]

    /// Which kind a window is, or nil for an app the wand does not act on.
    ///
    /// Pure, and deliberately taking the two raw fields rather than a
    /// `ManagedWindow`, so the classification that answers "why didn't the wand
    /// pick just my iTerm2 windows" is testable without AppKit.
    ///
    /// Simulator is checked FIRST and by `targetKind`, which is itself derived
    /// from `bundleId`. The two can never collide today — the simulator bundle
    /// id is neither terminal — but the order is load-bearing if `targetKind`
    /// ever widens (its own docs plan a `"browser_localhost"`), so it stays
    /// explicit rather than incidental.
    static func kind(bundleId: String, targetKind: String?) -> WandTargetKinds? {
        if targetKind == "simulator" { return .simulator }
        if bundleId == TerminalApp.iterm2.bundleIdentifier { return .iterm2 }
        if bundleId == TerminalApp.terminal.bundleIdentifier { return .terminalApp }
        return nil
    }

    /// Whether this configuration acts on that window.
    func matches(bundleId: String, targetKind: String?) -> Bool {
        guard let kind = WandTargetKinds.kind(bundleId: bundleId, targetKind: targetKind)
        else { return false }
        return contains(kind)
    }

    /// True for the kinds where "waiting for input" means an agent is waiting on
    /// YOU. A simulator has no prompt to wait at.
    static func isTerminal(_ kind: WandTargetKinds?) -> Bool {
        kind == .iterm2 || kind == .terminalApp
    }
}

/// What a window is, as far as the wand is concerned.
///
/// Separate from `WandTargetKinds` because that is a SET (what the user asked
/// for) and this is a single value (what a given window happens to be). `other`
/// has no `WandTargetKinds` counterpart on purpose: the setting can never name
/// it, so it can never be configured and always ranks last.
enum WandWindowKind: Sendable, Equatable, CaseIterable {
    case iterm2
    case terminalApp
    case simulator
    case other
}

/// One window, reduced to what the sort actually needs.
///
/// Deliberately not `ManagedWindow`: the ordering rules are the part worth
/// testing, and they have no business depending on window geometry, bundle ids,
/// or anything else that would drag AppKit into a unit test.
struct WandSortItem: Sendable, Equatable {
    let id: String
    /// Rank of this window's kind under the wand's configured target kinds —
    /// see `WandSort.tier(of:configured:)`. Lower sorts first. NOT a fixed
    /// table: which kinds lead depends on what the user asked the wand to
    /// care about.
    let tier: Int
    let subtitle: String
    let isWaitingForInput: Bool
    let lastOutputChangeAt: Date?
}

enum WandSort {

    /// The kinds the setting can name, in the order they rank. Declaration
    /// order rather than `rawValue` order so the ranking is something a reader
    /// can see rather than derive from bit positions.
    private static let rankableKinds: [(option: WandTargetKinds, kind: WandWindowKind)] = [
        (.iterm2, .iterm2),
        (.terminalApp, .terminalApp),
        (.simulator, .simulator),
    ]

    /// Where a window of `kind` sorts, given the wand's configured target kinds.
    ///
    /// Configured kinds lead, in the order above; unconfigured ones follow in
    /// the same order; `.other` is always last. One setting therefore means one
    /// thing — "these are the windows I care about" — governing both what rises
    /// and what gets switched on.
    ///
    /// Previously the tier came from a fixed table in the sidebar where
    /// `isTerminal` lumped iTerm2 and Terminal.app together, so narrowing the
    /// wand to iTerm2 changed what it enabled but not what sorted first: your
    /// Terminal.app windows still outranked your simulators.
    ///
    /// Unconfigured kinds are demoted rather than dropped, because the sidebar
    /// still lists those windows and every listed window needs a position.
    ///
    /// The default (`.iterm2, .terminalApp, .simulator`) preserves the historical
    /// ordering — terminals, then simulators, then the rest. The one change is
    /// that iTerm2 now ranks strictly above Terminal.app instead of tying with
    /// it; the tie used to be broken by subtitle, so this only ever moves
    /// Terminal.app windows below iTerm2 ones.
    static func tier(of kind: WandWindowKind, configured: WandTargetKinds) -> Int {
        let selected = rankableKinds.filter { configured.contains($0.option) }
        if let i = selected.firstIndex(where: { $0.kind == kind }) { return i }
        let rest = rankableKinds.filter { !configured.contains($0.option) }
        if let i = rest.firstIndex(where: { $0.kind == kind }) { return selected.count + i }
        return rankableKinds.count
    }

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
