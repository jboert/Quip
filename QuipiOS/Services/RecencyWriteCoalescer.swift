import Foundation

/// Q-88 US-003: the in-memory front of `WindowSelectionMemory`'s per-Mac
/// recency stacks. The Mac sends `frontmost_changed` on every activation and
/// every 400 ms poll, so `touch` (the Mac's frontmost) is coalesced to at most
/// one persisted write per backend per `interval`; `remember` (a phone
/// selection) is written at once, on top of anything still pending, so the
/// timer can never put an older order back. `recent` reads the pending order,
/// so a landing decision inside the interval already sees it.
@MainActor
final class RecencyWriteCoalescer {
    static let interval: TimeInterval = 1

    private let load: (String) -> [String]
    private let persist: ([String], String) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var pending: [String: [String]] = [:]
    private var flushScheduled: Set<String> = []

    /// `schedule` is the clock: it runs the flush after the delay. Tests pass
    /// one that collects the flushes and fires them on demand.
    init(load: @escaping (String) -> [String],
         persist: @escaping ([String], String) -> Void,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.load = load
        self.persist = persist
        self.schedule = schedule
    }

    convenience init(defaults: UserDefaults = .standard,
                     schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, fire in
                         DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(fire) }
                     }) {
        self.init(load: { WindowSelectionMemory.recent(forBackendId: $0, defaults: defaults) },
                  persist: { recent, backendId in
                      defaults.set(recent, forKey: WindowSelectionMemory.key(forBackendId: backendId))
                  },
                  schedule: schedule)
    }

    func recent(forBackendId backendId: String) -> [String] {
        pending[backendId] ?? load(backendId)
    }

    /// The Mac's frontmost window: reorders the stack, written within `interval`.
    func touch(_ windowId: String, forBackendId backendId: String) {
        let base = recent(forBackendId: backendId)
        let next = WindowSelectionMemory.touched(base, with: windowId)
        guard next != base else { return }
        pending[backendId] = next
        guard flushScheduled.insert(backendId).inserted else { return }
        schedule(Self.interval) { [weak self] in self?.flush(backendId) }
    }

    /// A window the phone selected: written now.
    func remember(_ windowId: String, forBackendId backendId: String) {
        let next = WindowSelectionMemory.touched(recent(forBackendId: backendId), with: windowId)
        pending[backendId] = nil
        persist(next, backendId)
    }

    /// Writes every pending order, e.g. before the app leaves the foreground.
    func flushAll() {
        pending.keys.sorted().forEach(flush)
    }

    private func flush(_ backendId: String) {
        flushScheduled.remove(backendId)
        guard let recent = pending.removeValue(forKey: backendId) else { return }
        persist(recent, backendId)
    }
}
