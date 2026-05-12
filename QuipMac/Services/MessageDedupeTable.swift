import Foundation
import OSLog

/// Mac-side dedupe table for idempotent phone-originated messages
/// (wishlist §27). Phone tags side-effecting messages (`send_text`,
/// `quick_action`, `duplicate_window`, etc.) with a `messageId: UUID`;
/// the Mac stamps each fresh ID into this table and rejects re-arrivals
/// for the next 30 seconds, so a double-tap or a future
/// retry-on-reconnect can't accidentally execute the action twice.
///
/// In-memory only — lost on QuipMac restart, which is fine because by
/// then the phone's plausible retry window has long since passed.
///
/// Ring-buffer bounded to `capacity` entries (oldest evicted first).
/// 100 entries with 30-second TTL covers any plausible network blip
/// without bloating memory.
final class MessageDedupeTable: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.quip.mac", category: "MessageDedupeTable")

    private let capacity: Int
    private let ttl: TimeInterval
    private let lock = NSLock()
    /// Insertion-ordered ring buffer. `entries[0]` is the oldest.
    private var entries: [(id: UUID, recordedAt: Date)] = []
    /// Quick membership check that doesn't walk `entries` on every send.
    private var index: [UUID: Date] = [:]

    init(capacity: Int = 100, ttl: TimeInterval = 30, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = capacity
        self.ttl = ttl
        self.now = clock
    }

    /// Pluggable clock so unit tests can advance time without sleeping.
    private let now: @Sendable () -> Date

    /// Check if `id` has already been seen recently. If yes, returns
    /// true (caller should skip the side effect). If no, records the
    /// id and returns false (caller should process the message).
    ///
    /// `nil` ids (older clients without `messageId`) always return
    /// false — backwards compat: process every time, never dedupe.
    func checkAndRecord(_ id: UUID?) -> Bool {
        guard let id else { return false }
        lock.lock()
        defer { lock.unlock() }

        purgeExpired()

        if index[id] != nil {
            return true
        }

        let stamp = now()
        entries.append((id: id, recordedAt: stamp))
        index[id] = stamp

        if entries.count > capacity {
            let evicted = entries.removeFirst()
            // Only drop from the index if the evicted record IS the
            // current entry — covers a future case where the same UUID
            // is re-stamped after rolling out of the buffer.
            if let recorded = index[evicted.id], recorded == evicted.recordedAt {
                index.removeValue(forKey: evicted.id)
            }
            // Hitting capacity means the phone is sending >100 messages within
            // the 30s TTL window — almost always a sign of a runaway loop or
            // a misbehaving retry. Log it so the operator can spot it instead
            // of seeing duplicates leak through silently.
            let age = stamp.timeIntervalSince(evicted.recordedAt)
            Self.logger.warning("MessageDedupeTable cap=\(self.capacity) reached; evicted oldest entry aged \(String(format: "%.1f", age))s — phone may be flooding")
        }
        return false
    }

    /// Internals — no lock; caller must hold `lock`.
    private func purgeExpired() {
        let cutoff = now().addingTimeInterval(-ttl)
        var dropped = 0
        for entry in entries {
            if entry.recordedAt < cutoff {
                dropped += 1
                if let recorded = index[entry.id], recorded == entry.recordedAt {
                    index.removeValue(forKey: entry.id)
                }
            } else {
                break  // Insertion-ordered — once we hit a fresh one, the rest are fresh.
            }
        }
        if dropped > 0 {
            entries.removeFirst(dropped)
        }
    }

    /// Test-only — current size of the ring buffer.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
