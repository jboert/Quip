import Foundation

/// Q-88 US-008 fills these: the first visible terminal line and how far it
/// was from the end, so a scrolled-up window comes back at the same text.
struct ScrollAnchor: Codable, Equatable {
    var line: String
    var fromEnd: Int
}

/// Q-88 US-005: where the user was on the phone for one Mac — the window,
/// the screen and desktop chips, and which panels were open. US-006 puts it
/// back.
///
/// Device-local on purpose: it is not in `PreferencesSnapshot`, not in the
/// iCloud copy, and never sent to the Mac. Another phone, or this one after
/// a reinstall, has its own place.
struct PhonePlace: Codable, Equatable {
    var selectedWindowId: String?
    var selectedDisplayID: String?
    var selectedSpaceID: String?
    var textInputOpen: Bool
    var terminalExpanded: Bool
    var scrollAnchorByWindow: [String: ScrollAnchor]
    var savedAt: Date

    init(selectedWindowId: String? = nil, selectedDisplayID: String? = nil, selectedSpaceID: String? = nil,
         textInputOpen: Bool = false, terminalExpanded: Bool = false,
         scrollAnchorByWindow: [String: ScrollAnchor] = [:], savedAt: Date) {
        self.selectedWindowId = selectedWindowId
        self.selectedDisplayID = selectedDisplayID
        self.selectedSpaceID = selectedSpaceID
        self.textInputOpen = textInputOpen
        self.terminalExpanded = terminalExpanded
        self.scrollAnchorByWindow = scrollAnchorByWindow
        self.savedAt = savedAt
    }

    /// Only `savedAt` is required, so a place written by an older or newer
    /// build still reads: a missing panel flag is closed, missing anchors
    /// are none. Unknown keys are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedWindowId = try c.decodeIfPresent(String.self, forKey: .selectedWindowId)
        selectedDisplayID = try c.decodeIfPresent(String.self, forKey: .selectedDisplayID)
        selectedSpaceID = try c.decodeIfPresent(String.self, forKey: .selectedSpaceID)
        textInputOpen = try c.decodeIfPresent(Bool.self, forKey: .textInputOpen) ?? false
        terminalExpanded = try c.decodeIfPresent(Bool.self, forKey: .terminalExpanded) ?? false
        scrollAnchorByWindow = try c.decodeIfPresent([String: ScrollAnchor].self, forKey: .scrollAnchorByWindow) ?? [:]
        savedAt = try c.decode(Date.self, forKey: .savedAt)
    }
}

/// Reads and writes `PhonePlace` in `UserDefaults`, one per Mac. These keys
/// are not tracked preferences, so writing them never syncs anything.
enum PhonePlaceStore {
    static func key(forBackendId backendId: String) -> String { "phonePlace.v1.\(backendId)" }
    /// When the app last went to the background, for `awayFor`. One for the
    /// app, not per Mac: the user was away from the phone, not from a Mac.
    static let backgroundedAtKey = "phonePlace.v1.backgroundedAt"

    static func load(forBackendId backendId: String, defaults: UserDefaults = .standard,
                     log: (String) -> Void = { PhoneLog.log($0) }) -> PhonePlace? {
        guard let data = defaults.data(forKey: key(forBackendId: backendId)) else { return nil }
        do {
            return try JSONDecoder().decode(PhonePlace.self, from: data)
        } catch {
            log("phonePlace decode FAILED bytes=\(data.count) — place not restored")
            return nil
        }
    }

    static func save(_ place: PhonePlace, forBackendId backendId: String, defaults: UserDefaults = .standard,
                     log: (String) -> Void = { PhoneLog.log($0) }) {
        do {
            defaults.set(try JSONEncoder().encode(place), forKey: key(forBackendId: backendId))
        } catch {
            log("phonePlace encode FAILED — place not saved")
        }
    }

    static func markBackgrounded(at date: Date, defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: backgroundedAtKey)
    }

    /// Seconds since the app went to the background, or nil when it never
    /// has (or the clock went backwards).
    static func awayFor(now: Date, defaults: UserDefaults = .standard) -> TimeInterval? {
        guard let at = defaults.object(forKey: backgroundedAtKey) as? Double else { return nil }
        let away = now.timeIntervalSince1970 - at
        return away >= 0 ? away : nil
    }
}

/// Saves the place at most once a second per Mac while the user moves
/// around, and at once when the app goes to the background (`flushAll`).
@MainActor
final class PhonePlaceRecorder {
    static let interval: TimeInterval = 1

    private let persist: (PhonePlace, String) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var pending: [String: PhonePlace] = [:]

    init(persist: @escaping (PhonePlace, String) -> Void = { PhonePlaceStore.save($0, forBackendId: $1) },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, fire in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(fire) }
         }) {
        self.persist = persist
        self.schedule = schedule
    }

    func record(_ place: PhonePlace, forBackendId backendId: String) {
        guard !backendId.isEmpty else { return }
        let first = pending.updateValue(place, forKey: backendId) == nil
        guard first else { return }
        schedule(Self.interval) { [weak self] in self?.flush(backendId) }
    }

    func flushAll() {
        pending.keys.sorted().forEach(flush)
    }

    private func flush(_ backendId: String) {
        guard let place = pending.removeValue(forKey: backendId) else { return }
        persist(place, backendId)
    }
}
