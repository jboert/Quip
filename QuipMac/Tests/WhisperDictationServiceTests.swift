import XCTest
@testable import Quip

final class FakeTranscriber: WhisperTranscriber, @unchecked Sendable {
    var canned: String = "hello"
    var throwError: Error?
    var lastSampleCount: Int = 0
    func transcribe(audioArray: [Float]) async throws -> String {
        lastSampleCount = audioArray.count
        if let throwError { throw throwError }
        return canned
    }
}

final class WhisperDictationServiceTests: XCTestCase {

    func chunk(sessionId: UUID, seq: Int, samples: Int, isFinal: Bool = false) -> AudioChunkMessage {
        // fake int16 LE samples — zeros are fine
        let data = Data(count: samples * 2)
        return AudioChunkMessage(sessionId: sessionId, seq: seq,
                                 pcmBase64: data.base64EncodedString(), isFinal: isFinal)
    }

    func testBuffersPerSession() async {
        let fake = FakeTranscriber()
        var sent: [Any] = []
        let svc = WhisperDictationService(transcriber: fake) { sent.append($0) }
        let a = UUID(); let b = UUID()
        svc.ingest(chunk(sessionId: a, seq: 0, samples: 1600))
        svc.ingest(chunk(sessionId: b, seq: 0, samples: 3200))

        // nothing sent yet — no final
        XCTAssertTrue(sent.isEmpty)
    }

    func testFinalTriggersTranscribeAndSend() async {
        let fake = FakeTranscriber(); fake.canned = "transcribed"
        var sent: [Any] = []
        let svc = WhisperDictationService(transcriber: fake) { sent.append($0) }
        let sid = UUID()
        svc.ingest(chunk(sessionId: sid, seq: 0, samples: 1600))
        await svc.ingestAsync(chunk(sessionId: sid, seq: 1, samples: 0, isFinal: true))

        let results = sent.compactMap { $0 as? TranscriptResultMessage }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].sessionId, sid)
        XCTAssertEqual(results[0].text, "transcribed")
        XCTAssertNil(results[0].error)
        XCTAssertEqual(fake.lastSampleCount, 1600)
    }

    func testTranscribeFailurePropagatesAsError() async {
        struct Boom: Error {}
        let fake = FakeTranscriber(); fake.throwError = Boom()
        var sent: [Any] = []
        let svc = WhisperDictationService(transcriber: fake) { sent.append($0) }
        let sid = UUID()
        await svc.ingestAsync(chunk(sessionId: sid, seq: 0, samples: 800, isFinal: true))

        let results = sent.compactMap { $0 as? TranscriptResultMessage }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].text, "")
        XCTAssertNotNil(results[0].error)
    }

    func testSessionBufferClearsAfterFinal() async {
        let fake = FakeTranscriber()
        var sent: [Any] = []
        let svc = WhisperDictationService(transcriber: fake) { sent.append($0) }
        let sid = UUID()
        svc.ingest(chunk(sessionId: sid, seq: 0, samples: 1600))
        await svc.ingestAsync(chunk(sessionId: sid, seq: 1, samples: 0, isFinal: true))
        XCTAssertFalse(svc.hasBuffer(for: sid))
    }

    func testStaleSessionsPurged() async {
        let fake = FakeTranscriber()
        var sent: [Any] = []
        let svc = WhisperDictationService(transcriber: fake, staleWindow: 0.1) { sent.append($0) }
        let sid = UUID()
        svc.ingest(chunk(sessionId: sid, seq: 0, samples: 1600))
        try? await Task.sleep(nanoseconds: 250_000_000)
        svc.purgeStaleSessions()
        XCTAssertFalse(svc.hasBuffer(for: sid))
    }
}
