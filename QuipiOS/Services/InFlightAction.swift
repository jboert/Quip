import Foundation

/// An action awaiting a reply from the Mac, with a deadline it cannot outlive.
///
/// The failure this prevents: a thumbnail spinner that never clears. Every
/// in-flight action must end somewhere — success, or a failure that says what
/// went wrong and what to do next. "Still spinning" is not a terminal state,
/// and a user staring at one has no way to tell a slow Mac from a dead socket.
///
/// Time is injected (`at:` / `now:`) rather than read from the clock so the
/// state machine is testable without waiting real seconds.
struct InFlightAction: Equatable {

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

    mutating func start(at now: TimeInterval) {
        state = .inFlight
        startedAt = now
    }

    /// Resolve from a reply. A no-op once the action already reached a terminal
    /// state — a late ack must not resurrect an action the user was already
    /// told had failed.
    mutating func resolve(_ resolution: Resolution) {
        guard state == .inFlight else { return }
        switch resolution {
        case .succeeded:
            state = .succeeded
        case .failed(let cause, let nextStep):
            state = .failed(cause: cause, nextStep: nextStep)
        }
        startedAt = nil
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
