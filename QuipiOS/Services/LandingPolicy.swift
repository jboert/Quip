import Foundation

/// Q-88 §3: the one rule that decides which window the phone lands on when
/// nothing the user did picks it — the first layout after a connect, or the
/// selected window vanishing from the layout. First match wins:
///
/// 1. explicit intent (a push tap, a `quip://window/<id>` link, a fresh tap);
/// 2. follow the Mac, when `followFrontmost` is on and its frontmost window is
///    in the layout;
/// 3. smart landing on a waiting window — US-009, not built yet;
/// 4. the saved place, ≤ 30 min old (`PlaceRestorePolicy.freshness`);
/// 5. the most recent window still open (`WindowSelectionMemory.recent`);
/// 6. the Mac's first window; nothing when the layout is empty.
enum LandingPolicy {
    enum Reason: String {
        case explicit, follow, waiting, restored, recent, first, none
    }

    struct Decision: Equatable {
        let windowId: String?
        let reason: Reason
    }

    struct Input {
        var explicit: String? = nil
        var followFrontmost = false
        var macFrontmost: String? = nil
        /// This Mac's saved place (Q-88 US-006) and the time to judge it by.
        var place: PhonePlace? = nil
        var now = Date()
        /// Most recent first.
        var recency: [String] = []
        /// The layout's window ids, in the Mac's order.
        var windows: [String]
        /// A window that must not be chosen (the one that just vanished).
        var excluding: String? = nil
    }

    static func decide(_ input: Input) -> Decision {
        let open = Set(input.windows)
        func usable(_ id: String?) -> String? {
            guard let id, open.contains(id), id != input.excluding else { return nil }
            return id
        }
        if let id = usable(input.explicit) { return Decision(windowId: id, reason: .explicit) }
        if input.followFrontmost, let id = usable(input.macFrontmost) {
            return Decision(windowId: id, reason: .follow)
        }
        if let place = input.place, PlaceRestorePolicy.isFresh(place, now: input.now),
           let id = usable(place.selectedWindowId) {
            return Decision(windowId: id, reason: .restored)
        }
        if let id = WindowSelectionMemory.best(recent: input.recency, available: input.windows,
                                               excluding: input.excluding) {
            return Decision(windowId: id, reason: .recent)
        }
        if let id = input.windows.first(where: { $0 != input.excluding }) {
            return Decision(windowId: id, reason: .first)
        }
        return Decision(windowId: nil, reason: .none)
    }

    /// What a `layout_update` does to the selection.
    struct LayoutOutcome: Equatable {
        let selected: String?
        /// The one `select_window` to send, if any.
        let send: String?
        /// Set when the policy chose the window; nil when the selection stood.
        let reason: Reason?
    }

    /// Lands when nothing is selected or the selected window has gone;
    /// otherwise keeps the selection, and re-sends it to the Mac only when the
    /// grid was empty before (the Mac forgot it across a reconnect). At most
    /// one `select_window` either way.
    static func afterLayout(selected: String?, wasEmpty: Bool, _ input: Input) -> LayoutOutcome {
        if let selected, input.windows.contains(selected) {
            return LayoutOutcome(selected: selected, send: wasEmpty ? selected : nil, reason: nil)
        }
        // A vanished window is not in `input.windows`, so no step can pick it.
        let decision = decide(input)
        return LayoutOutcome(selected: decision.windowId, send: decision.windowId, reason: decision.reason)
    }
}
