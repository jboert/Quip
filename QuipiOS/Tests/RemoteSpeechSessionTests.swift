import XCTest
import AVFoundation
@testable import Quip

final class RemoteSpeechSessionTests: XCTestCase {

    func testStopCompletionFiresOnMatchingTranscript() async throws {
        nonisolated(unsafe) var sent: [AudioChunkMessage] = []
        let sid = UUID()
        let sender = WhisperAudioSender(sessionId: sid) { sent.append($0) }
        let session = await RemoteSpeechSession(sessionId: sid, sender: sender, safetyTimeout: 2.0)

        let exp = expectation(description: "stop completion")
        Task { @MainActor in
            await session.stop { text in
                XCTAssertEqual(text, "hello world")
                exp.fulfill()
            }
        }

        // Simulate arrival of result for this session
        try await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            session.handleTranscript(sessionId: sid, text: "hello world", error: nil)
        }

        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testStaleSessionResultIgnored() async throws {
        let sid = UUID()
        let sender = WhisperAudioSender(sessionId: sid) { _ in }
        let session = await RemoteSpeechSession(sessionId: sid, sender: sender, safetyTimeout: 0.2)

        let exp = expectation(description: "safety timeout fires, not stale match")
        exp.expectedFulfillmentCount = 1
        Task { @MainActor in
            await session.stop { text in
                XCTAssertEqual(text, "") // safety timeout path: empty
                exp.fulfill()
            }
        }
        // Send a result for a different session — should be ignored
        try await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            session.handleTranscript(sessionId: UUID(), text: "not mine", error: nil)
        }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testSafetyTimeoutFiresWithEmpty() async throws {
        let sid = UUID()
        let sender = WhisperAudioSender(sessionId: sid) { _ in }
        let session = await RemoteSpeechSession(sessionId: sid, sender: sender, safetyTimeout: 0.1)

        let exp = expectation(description: "timeout")
        Task { @MainActor in
            await session.stop { text in
                XCTAssertEqual(text, "")
                exp.fulfill()
            }
        }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testErrorResultStillFiresCompletion() async throws {
        let sid = UUID()
        let sender = WhisperAudioSender(sessionId: sid) { _ in }
        let session = await RemoteSpeechSession(sessionId: sid, sender: sender, safetyTimeout: 2.0)

        let exp = expectation(description: "completion")
        Task { @MainActor in
            await session.stop { text in
                XCTAssertEqual(text, "") // error path yields empty text
                exp.fulfill()
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            session.handleTranscript(sessionId: sid, text: "", error: "whisper threw")
        }
        await fulfillment(of: [exp], timeout: 2.0)
    }
}
