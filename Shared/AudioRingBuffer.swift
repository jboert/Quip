import AVFoundation
import Foundation

/// Fixed-time-window ring buffer of PCM audio buffers.
/// Thread-safety: caller-provided. Intended to be used from a single serial queue.
final class AudioRingBuffer {
    struct Entry {
        let buffer: AVAudioPCMBuffer
        let timestamp: Date
    }

    private let window: TimeInterval
    private var storage: [Entry] = []

    init(window: TimeInterval) {
        self.window = window
    }

    func append(buffer: AVAudioPCMBuffer, at timestamp: Date) {
        storage.append(Entry(buffer: buffer, timestamp: timestamp))
        prune(relativeTo: timestamp)
    }

    func entries(relativeTo now: Date) -> [Entry] {
        prune(relativeTo: now)
        return storage
    }

    func clear() {
        storage.removeAll(keepingCapacity: true)
    }

    private func prune(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        storage.removeAll { $0.timestamp < cutoff }
    }
}
