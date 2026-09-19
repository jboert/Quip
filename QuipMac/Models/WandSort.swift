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

    /// Where "waiting for input" means an agent is waiting on YOU. A simulator
    /// has no prompt to wait at, and neither does an arbitrary app.
    ///
    /// The sort keys its waiting rule on this rather than on `tier == 0`,
    /// because the tier now moves with the configuration: under the default
    /// config iTerm2 is tier 0 and Terminal.app is tier 1, so a tier test would
    /// silently stop raising a waiting Terminal.app window.
    var isTerminal: Bool { self == .iterm2 || self == .terminalApp }
}

/// One window, reduced to what the SELECTION needs — which is less than the
/// sort needs, because switching a window on or off does not care where it
/// ranks.
struct WandSelectionItem: Sendable, Equatable {
    let id: String
    let kind: WandWindowKind
    let isEnabled: Bool

    init(id: String, kind: WandWindowKind, isEnabled: Bool) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

/// One window, reduced to what the sort actually needs.
///
/// Deliberately not `ManagedWindow`: the ordering rules are the part worth
/// testing, and they have no business depending on window geometry, bundle ids,
/// or anything else that would drag AppKit into a unit test.
struct WandSortItem: Sendable, Equatable {
    let id: String
    /// What the window is. The tier below is derived from this plus the
    /// configuration; the kind itself is still needed because some rules (the
    /// waiting-for-input raise) depend on what a window IS, not on where the
    /// current configuration happens to rank it.
    let kind: WandWindowKind
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
        /// Tier, then the waiting raise within terminals. Shared, because it is
        /// both `.devFocused`'s whole rule and the fallback `.mostActive` needs
        /// for windows it has no activity data about. nil = indistinguishable.
        func byKindThenAttention(_ a: WandSortItem, _ b: WandSortItem) -> Bool? {
            if a.tier != b.tier { return a.tier < b.tier }
            // Keyed on the KIND, not on `tier == 0`. The tier moves with the
            // configuration — under the default, iTerm2 is 0 and Terminal.app
            // is 1 — so a tier test would quietly stop raising a waiting
            // Terminal.app window.
            if a.kind.isTerminal, b.kind.isTerminal,
               a.isWaitingForInput != b.isWaitingForInput {
                return a.isWaitingForInput
            }
            return nil
        }

        return items.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            switch mode {
            case .devFocused:
                if let decided = byKindThenAttention(a, b) { return decided }
            case .mostActive:
                switch (a.lastOutputChangeAt, b.lastOutputChangeAt) {
                case let (l?, r?):
                    if l != r { return l > r }
                // A window never observed to change is not one that changed long
                // ago: it sorts behind everything that has moved.
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil):
                    // Neither has data, and that is the COMMON case, not an edge
                    // one. The signal only covers windows the mode poll reads —
                    // enabled terminals — so on launch, for anything switched
                    // off, and for every simulator there is nothing to rank by.
                    // Falling straight through to the subtitle tiebreak there
                    // dressed an alphabetical list up as a ranking; fall back to
                    // the dev-focused grouping instead, so the unranked tail is
                    // at least ordered the way the user would otherwise expect.
                    if let decided = byKindThenAttention(a, b) { return decided }
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

    /// Whether `.mostActive` has anything to rank by. The sidebar uses it to say
    /// so, because an unranked list and a ranked one are otherwise identical on
    /// screen — which is how "most active" could look like it was working while
    /// having no data at all.
    static func hasActivityData(_ items: [WandSortItem]) -> Bool {
        items.contains { $0.lastOutputChangeAt != nil }
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
    /// Which windows the wand must switch on, and which off, so that the desk
    /// ends up matching the configured kinds exactly.
    ///
    /// The wand used to only ever switch its targets ON, and `wandTargets()`
    /// filters to the configured kinds — so an UNCHECKED kind did not mean
    /// "switch this off", it meant "the wand cannot see this". Unchecking
    /// Simulators therefore left every running simulator switched on with no
    /// way to clear it: Option-click filters by the same configured kinds, so
    /// it could not reach them either.
    ///
    /// Read as an assignment instead: a tap makes the checked kinds the
    /// selection. That is idempotent, so it does NOT reintroduce the old
    /// toggle, whose second tap switched everything off and read as a broken
    /// button — tapping twice here lands on the same desk as tapping once.
    ///
    /// `other` is never touched in either direction. The setting cannot name
    /// it, so the wand has no mandate over it: a browser the user enabled by
    /// hand stays enabled.
    ///
    /// Only actual CHANGES come back, so the caller never writes a toggle for a
    /// window already in the right state.
    static func selection(for items: [WandSelectionItem],
                          kinds: WandTargetKinds) -> (enable: [String], disable: [String]) {
        var enable: [String] = []
        var disable: [String] = []
        for item in items {
            let wanted: Bool
            switch item.kind {
            case .iterm2:      wanted = kinds.contains(.iterm2)
            case .terminalApp: wanted = kinds.contains(.terminalApp)
            case .simulator:   wanted = kinds.contains(.simulator)
            case .other:       continue
            }
            if wanted && !item.isEnabled { enable.append(item.id) }
            if !wanted && item.isEnabled { disable.append(item.id) }
        }
        return (enable, disable)
    }

}
