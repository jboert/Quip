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

    /// `ingest` is called from the MainActor message loop once per audio chunk
    /// of every PTT stream. Decoding there blocks main for the length of the
    /// decode, every chunk — so the count has to stay at zero for both entry
    /// points, including the one the other tests in this file drive.
    /// `@MainActor` is load-bearing, not decoration: a plain `async` XCTest
    /// method runs on a cooperative thread, so without it the call below is not
    /// coming from main and a zero count would prove nothing. The first
    /// assertion exists to keep that true if anyone drops the attribute.
    @MainActor
    func testChunkDecodeNeverRunsOnTheMainThread() async {
        WhisperDictationService.resetMainThreadChunkDecodeCount()
        let fake = FakeTranscriber()
        let svc = WhisperDictationService(transcriber: fake) { _ in }
        let sid = UUID()

        XCTAssertTrue(Thread.isMainThread, "the counter only proves anything if the caller IS main")
        svc.ingest(chunk(sessionId: sid, seq: 0, samples: 1600))
        await svc.ingestAsync(chunk(sessionId: sid, seq: 1, samples: 1600))
        // Ordered behind both appends on the same serial queue, so by the time
        // this returns the decodes have happened.
        XCTAssertTrue(svc.hasBuffer(for: sid))

        XCTAssertEqual(
            WhisperDictationService.mainThreadChunkDecodes, 0,
            "a PCM chunk was base64-decoded on the main thread")
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
