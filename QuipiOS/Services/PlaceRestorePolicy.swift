import Foundation

/// Q-88 US-006: what to put back from a saved `PhonePlace`, in order.
enum PlaceRestorePolicy {
    /// A place older than this is stale: only its window can come back (and
    /// only through recency), never its panels.
    static let freshness: TimeInterval = 30 * 60

    enum Step: Equatable {
        case display(String?)
        case space(String?)
        case window(String)
        case terminalExpanded(Bool)
        case textInputOpen(Bool)
    }

    /// The clock the place is judged by. DEBUG builds take a launch
    /// argument to pretend time has passed (`-QuipNowOffset 1860`, sim S6b).
    static var now: Date {
        #if DEBUG
        Date().addingTimeInterval(UserDefaults.standard.double(forKey: "QuipNowOffset"))
        #else
        Date()
        #endif
    }

    static func isFresh(_ place: PhonePlace, now: Date) -> Bool {
        now.timeIntervalSince(place.savedAt) <= freshness
    }

    /// The steps for landing on `window` (LandingPolicy's choice): screen
    /// and desktop chips, the window, the full-height terminal, the text
    /// input. A chip whose screen or desktop is gone stays as it is. The
    /// panels come back only on the saved window: open panels on a different
    /// window would be a place the user never was.
    static func steps(place: PhonePlace?, now: Date, window: String?,
                      displays: [String], spaces: [String]) -> [Step] {
        guard let place, isFresh(place, now: now) else { return window.map { [.window($0)] } ?? [] }
        var out: [Step] = []
        if place.selectedDisplayID.map(displays.contains) ?? true { out.append(.display(place.selectedDisplayID)) }
        if place.selectedSpaceID.map(spaces.contains) ?? true { out.append(.space(place.selectedSpaceID)) }
        guard let window else { return out }
        out.append(.window(window))
        if window == place.selectedWindowId {
            out.append(.terminalExpanded(place.terminalExpanded))
            out.append(.textInputOpen(place.textInputOpen))
        }
        return out
    }
}

extension PlaceRestorePolicy.Step {
    /// For `phone.log`: which steps ran, never the ids.
    var name: String {
        switch self {
        case .display: "display"
        case .space: "space"
        case .window: "window"
        case .terminalExpanded(let on): on ? "terminal" : "terminal-off"
        case .textInputOpen(let on): on ? "input" : "input-off"
        }
    }
}
