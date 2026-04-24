import XCTest
import AVFoundation
@testable import Quip

final class WhisperAudioSenderTests: XCTestCase {

    func makeBuffer(sampleRate: Double, frames: Int, value: Float = 0.0) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buf.floatChannelData![0][i] = value
        }
        return buf
    }

    func testChunksEmitAtCorrectRate() async throws {
        nonisolated(unsafe) var sent: [AudioChunkMessage] = []
        let sender = WhisperAudioSender(sessionId: UUID()) { sent.append($0) }

        // 1 second of 48 kHz audio = 48000 frames → resampled to 16000 samples → 10 frames of 100ms
        let buf = makeBuffer(sampleRate: 48000, frames: 48000, value: 0.1)
        sender.appendBuffer(buf)

        // Allow the serial queue to drain
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThanOrEqual(sent.count, 9) // allow resampler slop
        XCTAssertLessThanOrEqual(sent.count, 11)
        for m in sent {
            XCTAssertFalse(m.isFinal)
            XCTAssertEqual(Data(base64Encoded: m.pcmBase64)?.count, 3200)
        }
    }

    func testSeqMonotonic() async throws {
        nonisolated(unsafe) var sent: [AudioChunkMessage] = []
        let sender = WhisperAudioSender(sessionId: UUID()) { sent.append($0) }
        sender.appendBuffer(makeBuffer(sampleRate: 16000, frames: 3200)) // 2 frames
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sent.map(\.seq), Array(0..<sent.count))
    }

    func testFinishSendsFinalMarker() async throws {
        nonisolated(unsafe) var sent: [AudioChunkMessage] = []
        let sender = WhisperAudioSender(sessionId: UUID()) { sent.append($0) }
        sender.appendBuffer(makeBuffer(sampleRate: 16000, frames: 800)) // sub-frame
        await sender.finish()

        XCTAssertGreaterThanOrEqual(sent.count, 1)
        XCTAssertTrue(sent.last!.isFinal)
    }

    func testSessionIdStable() async throws {
        nonisolated(unsafe) var sent: [AudioChunkMessage] = []
        let sid = UUID()
        let sender = WhisperAudioSender(sessionId: sid) { sent.append($0) }
        sender.appendBuffer(makeBuffer(sampleRate: 16000, frames: 3200))
        await sender.finish()

        for m in sent {
            XCTAssertEqual(m.sessionId, sid)
        }
    }
}
