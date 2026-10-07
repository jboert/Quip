import Foundation

/// Bounded FIFO of phone log lines waiting to reach the Mac. When the phone
/// is offline longer than `capacity` lines, the oldest go first and the next
/// drain says how many were lost, so a gap in phone.log is never silent.
struct PhoneLogBuffer {
    let capacity: Int
    private var lines: [String] = []
    private var dropped = 0

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    mutating func append(_ line: String) {
        lines.append(line)
        trim()
    }

    /// Puts back lines whose send failed, ahead of anything logged since.
    mutating func requeue(_ failed: [String]) {
        lines = failed + lines
        trim()
    }

    /// Everything waiting, oldest first, led by a note if lines were dropped.
    mutating func drain() -> [String] {
        var out = lines
        if dropped > 0 {
            out.insert("[phone-log] dropped \(dropped) older lines while offline", at: 0)
        }
        lines = []
        dropped = 0
        return out
    }

    private mutating func trim() {
        let excess = lines.count - capacity
        guard excess > 0 else { return }
        lines.removeFirst(excess)
        dropped += excess
    }
}

/// Phone diagnostics that reach the Mac's `phone.log` over the WebSocket, so
/// what the phone decided on its own (which speech engine ran, whether its
/// model was ready) can be read on the Mac without a cable. Lines are sent as
/// soon as an authenticated connection exists and buffered until then.
@MainActor
final class PhoneLog {
    static let shared = PhoneLog()

    private var buffer = PhoneLogBuffer()
    private weak var client: WebSocketClient?

    /// Logs `message` from any thread. Also printed, so a cabled console still
    /// sees it.
    nonisolated static func log(_ message: String) {
        print("[Quip][phone-log] \(message)")
        let line = "\(Date().ISO8601Format()) \(message)"
        Task { @MainActor in shared.enqueue(line) }
    }

    /// Called when `client` authenticates: it becomes the route to the Mac,
    /// and anything buffered goes out.
    func attach(_ client: WebSocketClient) {
        self.client = client
        flush()
    }

    private func enqueue(_ line: String) {
        buffer.append(line)
        flush()
    }

    private func flush() {
        guard let client, client.isAuthenticated else { return }
        let lines = buffer.drain()
        guard !lines.isEmpty else { return }
        if !client.send(PhoneLogMessage(lines: lines)) {
            buffer.requeue(lines)
        }
    }
}
