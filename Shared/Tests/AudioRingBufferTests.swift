import XCTest
import AVFoundation
@testable import Quip

final class AudioRingBufferTests: XCTestCase {
    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    }

    func testAppendDropsBuffersOlderThanWindow() {
        let ring = AudioRingBuffer(window: 0.5)  // 500ms
        let now = Date()
        ring.append(buffer: makeBuffer(), at: now.addingTimeInterval(-1.0))  // 1s ago
        ring.append(buffer: makeBuffer(), at: now.addingTimeInterval(-0.3))  // 300ms ago
        ring.append(buffer: makeBuffer(), at: now)
        let kept = ring.entries(relativeTo: now)
        XCTAssertEqual(kept.count, 2, "Entries older than window should drop")
    }

    func testReplayIsOrderPreserving() {
        let ring = AudioRingBuffer(window: 1.0)
        let base = Date()
        let b1 = makeBuffer()
        let b2 = makeBuffer()
        let b3 = makeBuffer()
        ring.append(buffer: b1, at: base.addingTimeInterval(-0.4))
        ring.append(buffer: b2, at: base.addingTimeInterval(-0.2))
        ring.append(buffer: b3, at: base)
        let kept = ring.entries(relativeTo: base)
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept[0].buffer === b1)
        XCTAssertTrue(kept[1].buffer === b2)
        XCTAssertTrue(kept[2].buffer === b3)
    }

    func testClearRemovesAll() {
        let ring = AudioRingBuffer(window: 1.0)
        ring.append(buffer: makeBuffer(), at: Date())
        ring.clear()
        XCTAssertTrue(ring.entries(relativeTo: Date()).isEmpty)
    }
}
