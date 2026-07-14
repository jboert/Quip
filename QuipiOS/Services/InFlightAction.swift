import Foundation

/// The clock a deadline and the sleep that enforces it must BOTH be read from.
///
/// Two properties, and a watchdog needs both:
///
///   * MONOTONIC — an NTP correction or a user changing the date mid-flight
///     cannot retire a deadline early or late. (`Date` fails this.)
///   * CONTINUOUS — it keeps counting while the device is asleep, which is what
///     `Task.sleep` does. (`ProcessInfo.systemUptime` fails this: it counts only
///     time the system has been AWAKE, by definition.)
///
/// Mixing the two is what stranded a request: sleep on the continuous clock,
/// measure elapsed on the awake-only one, and a phone locked one second into a
/// 10s wait comes back with the sleep long over but only ~1.5s of "elapsed" —
/// the wake ticks, declines to trip, and nothing re-arms. The socket died during
/// the sleep, so the reply never comes and the spinner runs forever. Both halves
/// read this, so an early wake is impossible by construction.
///
/// `CLOCK_MONOTONIC` on Darwin is the continuous one (it advances across sleep);
/// `CLOCK_UPTIME_RAW` — what `systemUptime` reports — is the one that stops.
enum MonotonicClock {
    static var now: TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }
}

/// An action awaiting a reply from the Mac, with a deadline it cannot outlive.
///
/// The failure this prevents: a thumbnail spinner that never clears. Every
/// in-flight action must end somewhere — success, or a failure that says what
/// went wrong and what to do next. "Still spinning" is not a terminal state,
/// and a user staring at one has no way to tell a slow Mac from a dead socket.
///
/// Time is injected (`at:` / `now:`) rather than read from the clock so the
/// state machine is testable without waiting real seconds.
///
/// This is a value type: callers must confine all mutation to a single
/// isolation context (e.g. hold it as a `var` on a `@MainActor` type, the
/// way `PendingImageState` does today) — Swift 6 will not catch races on a
/// bare struct the way it catches races on a class.
struct InFlightAction: Equatable {

    /// Substituted for a caller-supplied `cause` or `nextStep` that is empty
    /// or whitespace-only, so a hollow `.failed` can never be constructed.
    private static let fallbackCause = "Something went wrong"
    private static let fallbackNextStep = "Try again"

    enum State: Equatable {
        case idle
        case inFlight
        case succeeded
        /// Always carries BOTH: what went wrong, and the one thing to do next.
        case failed(cause: String, nextStep: String)
    }

    enum Resolution: Equatable {
        case succeeded
        case failed(cause: String, nextStep: String)
    }

    private(set) var state: State = .idle
    private let deadline: TimeInterval
    private var startedAt: TimeInterval?

    init(deadline: TimeInterval) {
        self.deadline = deadline
    }

    /// Arm a fresh attempt. From `.idle`, `.succeeded`, or `.failed` this is a
    /// legitimate retry and resets the deadline clock to `now`.
    ///
    /// Called while already `.inFlight`, this is a no-op that preserves the
    /// ORIGINAL deadline — re-arming a live action must never be able to mask
    /// a hang by resetting its clock out from under it.
    mutating func start(at now: TimeInterval) {
        guard state != .inFlight else { return }
        state = .inFlight
        startedAt = now
    }

    /// Resolve from a reply. A no-op once the action already reached a terminal
    /// state — a late ack must not resurrect an action the user was already
    /// told had failed.
    ///
    /// A `.failed` resolution with an empty or whitespace-only `cause` or
    /// `nextStep` is coerced to a non-empty default rather than rejected —
    /// rejecting would leave the action stuck in `.inFlight`, spinning
    /// forever, which is worse than a generic message. The machine must never
    /// come to rest in a state that is both terminal and inactionable.
    mutating func resolve(_ resolution: Resolution) {
        guard state == .inFlight else { return }
        switch resolution {
        case .succeeded:
            state = .succeeded
        case .failed(let cause, let nextStep):
            state = .failed(cause: Self.nonEmpty(cause, fallback: Self.fallbackCause),
                            nextStep: Self.nonEmpty(nextStep, fallback: Self.fallbackNextStep))
        }
        startedAt = nil
    }

    private static func nonEmpty(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }

    /// Seconds still owed before `tick(now:)` would trip, or nil when there is
    /// no live deadline to owe them against.
    ///
    /// The watchdog sleeps for exactly this, so the sleep and the deadline can
    /// never disagree about how much time is left — see `MonotonicClock`.
    func remaining(now: TimeInterval) -> TimeInterval? {
        guard state == .inFlight, let startedAt else { return nil }
        return deadline - (now - startedAt)
    }

    /// Drive the watchdog. Returns true on the tick that trips it.
    mutating func tick(now: TimeInterval) -> Bool {
        guard state == .inFlight, let startedAt else { return false }
        guard now - startedAt >= deadline else { return false }
        state = .failed(cause: "Mac didn't respond in \(Int(deadline))s",
                        nextStep: "Check the connection and try again")
        self.startedAt = nil
        return true
    }
}
