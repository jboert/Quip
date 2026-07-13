import Foundation

/// A request the phone sent to the Mac that the UI is *waiting on* — a spinner,
/// a disabled refresh button, a "Waiting for Mac…" label.
///
/// The failure this prevents is the photo-upload one, generalized: a waiting
/// state with no terminal state. A user staring at a spinner cannot tell a slow
/// Mac from a dead socket from a Mac build that predates the handler entirely.
/// Every wait must end — in a reply, or in a failure that says what went wrong
/// and what to do next.
///
/// `PendingImageState` solved this for the one call site it owns, by hand. This
/// is the same guarantee, reusable: it owns an `InFlightAction` (the deadline
/// state machine) plus the watchdog that drives it.
///
/// `InFlightAction` is a value type with an injected clock, so it lives here as
/// a `var` on a `@MainActor` class — every mutation is confined to the main
/// actor, which is the confinement the type's contract requires.
@MainActor
final class PendingMacRequest: ObservableObject {

    /// Mirrors the underlying machine so SwiftUI re-renders on every transition.
    @Published private(set) var state: InFlightAction.State = .idle

    private var action: InFlightAction
    private let deadline: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private var watchdog: Task<Void, Never>?

    /// - Parameter now: monotonic clock, injected so tests can trip a deadline
    ///   without sleeping through it. `systemUptime` (not `Date`) so a wall-clock
    ///   adjustment mid-flight cannot retire the deadline early or late.
    init(deadline: TimeInterval,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.deadline = deadline
        self.now = now
        self.action = InFlightAction(deadline: deadline)
    }

    /// True exactly while the UI should show its waiting affordance.
    var isInFlight: Bool { state == .inFlight }

    /// Non-nil only on failure, and never empty: `InFlightAction` guarantees a
    /// `.failed` carries both a cause and a next step, so no call site can
    /// render a blank error or a spinner with nothing behind it.
    var failureMessage: String? {
        guard case .failed(let cause, let nextStep) = state else { return nil }
        return "\(cause) — \(nextStep)"
    }

    /// Arm the request and start its watchdog.
    ///
    /// Called again while already in flight, this is a no-op: the original
    /// deadline *and* its watchdog survive. A user hammering a refresh button
    /// must not be able to push the deadline out indefinitely and mask a hang.
    func start() {
        guard !isInFlight else { return }
        action.start(at: now())
        state = action.state
        watchdog?.cancel()
        // A hair past the deadline: Task.sleep guarantees *at least* its
        // duration, but the slack keeps a same-instant wake from reading as
        // "not yet expired" and leaving the request in flight with no watchdog.
        let nanos = UInt64(deadline * 1_000_000_000) + 10_000_000
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    /// Resolve from the Mac's reply. A no-op once the watchdog has already
    /// tripped — a late reply must not un-fail a request the user was already
    /// told had failed.
    func resolve(_ resolution: InFlightAction.Resolution) {
        watchdog?.cancel()
        watchdog = nil
        action.resolve(resolution)
        state = action.state
    }

    /// Drive the deadline. The watchdog calls this on expiry; tests call it
    /// directly with a fake clock already past the deadline.
    func tick() {
        guard action.tick(now: now()) else { return }
        state = action.state
    }

    /// Back to a clean slate — e.g. the sheet closed. Cancels the watchdog so a
    /// dismissed screen's deadline cannot fire into a reopened one.
    func reset() {
        watchdog?.cancel()
        watchdog = nil
        action = InFlightAction(deadline: deadline)
        state = action.state
    }
}
