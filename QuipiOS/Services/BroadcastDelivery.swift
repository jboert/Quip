import Foundation

/// Which windows got a broadcast (PRD broadcast-and-search, US-111).
///
/// Each target's message carries its own `messageId`, and the Mac's
/// `send_text_ack` for that id confirms the target. A target still waiting
/// at `deadline` is unconfirmed, and an error naming its id fails it; both
/// are offered for retry. A late ack still confirms, so a slow Mac is not
/// reported as a lost window for good.
///
/// The Mac does not ack `paste_prompt` until US-115 ships, so a delivery
/// that expects no ack counts every target as sent at once and its summary
/// says "sent", never "delivered".
struct BroadcastDelivery: Equatable, Sendable {
    /// Seconds a target may wait for its ack before it is unconfirmed.
    static let deadline: TimeInterval = 8

    enum Status: Equatable, Sendable {
        /// Waiting for the Mac's ack.
        case pending
        /// The Mac acked this target's message.
        case confirmed
        /// Queued on a route the Mac does not ack; nothing to wait for.
        case sent
        /// No ack by the deadline. A late ack still confirms it.
        case unconfirmed
        /// The Mac reported an error for this target's message.
        case failed
    }

    struct Target: Equatable, Sendable {
        let windowID: String
        /// The window's name, as the summary shows it.
        let name: String
        let messageID: UUID
        var status: Status
    }

    /// What was sent, kept so a retry can reopen the sheet with it.
    let text: String
    let source: BroadcastSource?
    let startedAt: Date
    /// False when the route has no ack (see the type's note).
    let expectsAck: Bool
    /// In send order, which is the order the summary names them in.
    private(set) var targets: [Target]

    init(text: String, source: BroadcastSource?, targets: [(windowID: String, name: String, messageID: UUID)],
         expectsAck: Bool, startedAt: Date) {
        self.text = text
        self.source = source
        self.startedAt = startedAt
        self.expectsAck = expectsAck
        self.targets = targets.map {
            Target(windowID: $0.windowID, name: $0.name, messageID: $0.messageID,
                   status: expectsAck ? .pending : .sent)
        }
    }

    /// The Mac acked `messageID`. False, changing nothing, when no target is
    /// waiting on it: another message's ack, a repeat, or a target that
    /// already failed.
    @discardableResult
    mutating func confirm(messageID: UUID) -> Bool {
        settle(messageID, as: .confirmed)
    }

    /// The Mac reported `messageID` failed. False, changing nothing, when no
    /// target is waiting on it.
    @discardableResult
    mutating func fail(messageID: UUID) -> Bool {
        settle(messageID, as: .failed)
    }

    /// From the deadline on, every target still pending is unconfirmed.
    /// True when that changed anything.
    @discardableResult
    mutating func expire(at now: Date) -> Bool {
        guard now >= startedAt.addingTimeInterval(Self.deadline) else { return false }
        var changed = false
        for index in targets.indices where targets[index].status == .pending {
            targets[index].status = .unconfirmed
            changed = true
        }
        return changed
    }

    /// True once no target is waiting for its ack or the deadline.
    var isSettled: Bool {
        !targets.contains { $0.status == .pending }
    }

    /// The windows a retry reselects: unconfirmed and failed, in target order.
    var retryWindowIDs: [String] {
        retryTargets.map(\.windowID)
    }

    /// The one-line result: "Broadcasting to 3…", "Broadcast sent to 3",
    /// "Broadcast delivered to 3 of 3", or "Broadcast: 1 of 3 confirmed —
    /// web, api did not answer". Past two names, the rest are counted.
    var summary: String {
        let count = targets.count
        if !isSettled { return "Broadcasting to \(count)…" }
        if !expectsAck { return "Broadcast sent to \(count)" }
        let confirmed = targets.filter { $0.status == .confirmed }.count
        if confirmed == count { return "Broadcast delivered to \(count) of \(count)" }
        let names = retryTargets.map(\.name)
        let named = names.count <= 2
            ? names.joined(separator: ", ")
            : names.prefix(2).joined(separator: ", ") + " +\(names.count - 2) more"
        return "Broadcast: \(confirmed) of \(count) confirmed — \(named) did not answer"
    }

    private var retryTargets: [Target] {
        targets.filter { $0.status == .unconfirmed || $0.status == .failed }
    }

    /// Moves the first target still waiting on `messageID`, pending or past
    /// the deadline, to `status`.
    private mutating func settle(_ messageID: UUID, as status: Status) -> Bool {
        guard let index = targets.firstIndex(where: {
            $0.messageID == messageID && ($0.status == .pending || $0.status == .unconfirmed)
        }) else { return false }
        targets[index].status = status
        return true
    }
}
