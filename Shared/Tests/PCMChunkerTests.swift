import XCTest
@testable import Quip

final class PCMChunkerTests: XCTestCase {

    func testEmptyInputYieldsNoFrames() {
        var chunker = PCMChunker(frameSamples: 1600)
        let frames = chunker.append([])
        XCTAssertEqual(frames.count, 0)
    }

    func testPartialFrameIsBuffered() {
        var chunker = PCMChunker(frameSamples: 1600)
        let frames = chunker.append(Array(repeating: Float(0.5), count: 800))
        XCTAssertEqual(frames.count, 0)
    }

    func testExactlyOneFrameEmits() {
        var chunker = PCMChunker(frameSamples: 1600)
        let frames = chunker.append(Array(repeating: Float(1.0), count: 1600))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 3200) // 1600 samples × 2 bytes

        // All samples should be int16 max (32767) since input was 1.0
        let bytes = [UInt8](frames[0])
        // first sample: low byte 0xFF, high byte 0x7F (little endian)
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1], 0x7F)
    }

    func testMultipleFramesAcrossCalls() {
        var chunker = PCMChunker(frameSamples: 1600)
        _ = chunker.append(Array(repeating: Float(0.0), count: 1000))
        let frames = chunker.append(Array(repeating: Float(0.0), count: 2500))
        XCTAssertEqual(frames.count, 2) // 1000+2500 = 3500 → two 1600-sample frames, 300 leftover

        // Next call picks up leftover
        let more = chunker.append(Array(repeating: Float(0.0), count: 1300))
        XCTAssertEqual(more.count, 1) // 300 + 1300 = 1600
    }

    func testFlushEmitsTail() {
        var chunker = PCMChunker(frameSamples: 1600)
        _ = chunker.append(Array(repeating: Float(0.0), count: 800))
        let tail = chunker.flush()
        XCTAssertNotNil(tail)
        XCTAssertEqual(tail?.count, 1600) // 800 samples × 2 bytes
    }

    func testFlushEmptyWhenNoResidual() {
        var chunker = PCMChunker(frameSamples: 1600)
        _ = chunker.append(Array(repeating: Float(0.0), count: 1600))
        XCTAssertNil(chunker.flush())
    }

    func testClippingAtExtremes() {
        var chunker = PCMChunker(frameSamples: 2)
        let frames = chunker.append([2.0, -2.0]) // out of [-1, 1] range
        XCTAssertEqual(frames.count, 1)
        let b = [UInt8](frames[0])
        // +32767 LE = FF 7F ; -32768 LE = 00 80
        XCTAssertEqual(b[0], 0xFF); XCTAssertEqual(b[1], 0x7F)
        XCTAssertEqual(b[2], 0x00); XCTAssertEqual(b[3], 0x80)
    }
}
