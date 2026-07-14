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

    /// - Parameter now: the deadline clock, injected so tests can trip a deadline
    ///   without sleeping through it. It has to be the clock `Task.sleep` runs
    ///   on or the watchdog's two halves disagree — see `MonotonicClock`.
    init(deadline: TimeInterval,
         now: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now }) {
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
        // Sleep → tick → sleep again until the tick actually trips. ONE sleep and
        // ONE tick is what stranded requests: a wake that finds the deadline not
        // yet reached returned false and left nothing armed behind it, and the
        // wake that finds that is not exotic — it is every backgrounded phone
        // (see `MonotonicClock` for why the two halves used to disagree). Now an
        // early wake costs one more sleep, and the only way out of `.inFlight` is
        // a reply, a reset, or the deadline.
        //
        // `self` is re-acquired weakly on each pass and never held across the
        // sleep, so a dismissed sheet's request deallocates on schedule and its
        // watchdog exits on the next wake instead of resurrecting it.
        watchdog = Task { [weak self] in
            while let nanos = self?.nanosUntilDeadline() {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    /// How long the watchdog should sleep before its next tick, or nil once the
    /// request is no longer in flight (which is the watchdog's exit condition).
    ///
    /// The slack is because `Task.sleep` guarantees *at least* its duration:
    /// without it a same-instant wake reads as "not yet expired" and buys another
    /// whole pass for nothing.
    private func nanosUntilDeadline() -> UInt64? {
        guard let remaining = action.remaining(now: now()) else { return nil }
        return UInt64(max(remaining, 0) * 1_000_000_000) + 10_000_000
    }

    /// Arm a request and hand the frame to the transport, resolving to a stated
    /// failure if either the link or the send is unavailable. Returns whether
    /// the request is now genuinely in flight.
    ///
    /// This exists because the obvious spelling — `guard isConnected else
    /// { return }` at the top of the call site — trades "spins forever" for
    /// "does nothing", which is not an improvement. The phone displays
    /// "Connected" over a socket that has been one-sidedly dead since the Mac
    /// last restarted; on that socket a bare early return makes the button a
    /// no-op with no spinner, no status and no error, and it never reaches the
    /// deadline machinery that would otherwise have said so. Every tap must end
    /// somewhere the user can act on.
    @discardableResult
    func attempt(isConnected: Bool, nextStep: String, send: () -> Bool) -> Bool {
        start()
        guard isConnected else {
            resolve(.failed(cause: "Not connected to the Mac", nextStep: nextStep))
            return false
        }
        guard send() else {
            resolve(.failed(cause: "Couldn't reach the Mac", nextStep: nextStep))
            return false
        }
        return true
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
