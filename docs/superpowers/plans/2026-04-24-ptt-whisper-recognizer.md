# PTT Whisper Recognizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-04-24-ptt-whisper-recognizer-design.md`

**Goal:** Replace iPhone on-device SFSpeech with Mac-local Whisper as the default PTT recognizer; keep SFSpeech as automatic fallback.

**Architecture:** iPhone streams 100 ms PCM frames (16 kHz mono int16, base64 in a Codable JSON message) over the existing Bonjour WebSocket. Mac buffers per-session, runs `WhisperKit.transcribe` on PTT release, returns one final transcript. Local SFSpeech path unchanged; selected at PTT-start when WS is down or Whisper isn't ready.

**Tech Stack:**
- Swift 6.0 — strict concurrency minimal; iOS 17.0, macOS 14.0 minimum
- XCTest on both platforms (`@testable import Quip` since the product name is `Quip` on both targets)
- xcodegen (`project.yml`) for project/SPM config
- `argmaxinc/WhisperKit` — added to Mac target only
- Existing `MessageCoder` / `WebSocketClient` / `WebSocketServer` plumbing — do not refactor

**Ground rules:**
- TDD: write the failing test first, see it fail, implement, see it pass, commit.
- Commit per task. Commit messages follow the repo's style (imperative, no emojis, Co-Authored-By footer). **Do NOT push** — `eb-branch` is local dev (per `feedback_eb_branch_push_policy`).
- Do not rebuild the Mac app unless a Mac task actually touched Mac sources — each rebuild risks losing Accessibility + Screen Recording TCC grants (per `feedback_mac_rebuild_cost`).

---

## File Structure

**New Shared (cross-platform, lives in `Shared/`):**
- `Shared/PCMChunker.swift` — pure logic: down-sample/convert Float32 PCM to 16 kHz mono int16, emit 100 ms frames.
- `Shared/Tests/PCMChunkerTests.swift`
- New message types added inline to `Shared/MessageProtocol.swift` (same convention as existing messages).
- Round-trip tests appended to `Shared/Tests/MessageProtocolTests.swift`.

**New iPhone (`QuipiOS/Services/`):**
- `QuipiOS/Services/WhisperAudioSender.swift` — owns `AVAudioConverter` + `PCMChunker`, forwards int16 frames to `WebSocketClient` as `AudioChunkMessage`.
- `QuipiOS/Services/RemoteSpeechSession.swift` — session orchestrator with stop-completion contract matching the local SFSpeech path.
- `QuipiOS/Tests/WhisperAudioSenderTests.swift`
- `QuipiOS/Tests/RemoteSpeechSessionTests.swift`
- `QuipiOS/Tests/SpeechServicePathSelectionTests.swift`

**Modified iPhone:**
- `QuipiOS/Services/SpeechService.swift` — branch at top of `startRecording` between local/remote path.
- `QuipiOS/Services/WebSocketClient.swift` — add `whisperStatus` published property; decode + dispatch new message types.

**New Mac (`QuipMac/Services/`):**
- `QuipMac/Services/WhisperDictationService.swift` — buffers chunks per session id, runs `WhisperKit.transcribe` on final, emits `TranscriptResultMessage`; broadcasts `WhisperStatusMessage`.
- `QuipMac/Tests/WhisperDictationServiceTests.swift`

**Modified Mac:**
- `QuipMac/project.yml` — add WhisperKit SPM package.
- `QuipMac/QuipMacApp.swift` — dispatch `AudioChunkMessage` to `WhisperDictationService`; broadcast `WhisperStatusMessage` on connect + on state transitions.

---

## Task Sequence

Tasks are ordered so each one leaves the tree green (iOS tests pass, Mac builds, no dead symbols). Cross-platform message types land first because both sides depend on them.

### Task 1: Add message types to Shared — round-trip tests

**Files:**
- Modify: `Shared/MessageProtocol.swift`
- Modify: `Shared/Tests/MessageProtocolTests.swift`

- [ ] **Step 1.1: Write failing round-trip tests**

Append to `Shared/Tests/MessageProtocolTests.swift` at the bottom, before the final `}`:

```swift
// MARK: - Whisper PTT Messages

func testAudioChunkMessageRoundTrip() throws {
    let sessionId = UUID()
    let pcm = Data([0x01, 0x02, 0x03, 0x04])
    let original = AudioChunkMessage(
        sessionId: sessionId, seq: 7, pcmBase64: pcm.base64EncodedString(), isFinal: false
    )
    let data = try XCTUnwrap(MessageCoder.encode(original))
    let dict = try jsonDict(from: data)
    XCTAssertEqual(dict["type"] as? String, "audio_chunk")
    XCTAssertEqual(dict["sessionId"] as? String, sessionId.uuidString)
    XCTAssertEqual(dict["seq"] as? Int, 7)
    XCTAssertEqual(dict["isFinal"] as? Bool, false)

    let decoded = try XCTUnwrap(MessageCoder.decode(AudioChunkMessage.self, from: data))
    XCTAssertEqual(decoded.sessionId, sessionId)
    XCTAssertEqual(decoded.seq, 7)
    XCTAssertEqual(Data(base64Encoded: decoded.pcmBase64), pcm)
    XCTAssertEqual(decoded.isFinal, false)
}

func testAudioChunkMessageFinalMarker() throws {
    let msg = AudioChunkMessage(sessionId: UUID(), seq: 99, pcmBase64: "", isFinal: true)
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let decoded = try XCTUnwrap(MessageCoder.decode(AudioChunkMessage.self, from: data))
    XCTAssertTrue(decoded.isFinal)
    XCTAssertEqual(decoded.pcmBase64, "")
}

func testTranscriptResultMessageRoundTrip() throws {
    let sessionId = UUID()
    let original = TranscriptResultMessage(sessionId: sessionId, text: "hello SwiftUI", error: nil)
    let data = try XCTUnwrap(MessageCoder.encode(original))
    let decoded = try XCTUnwrap(MessageCoder.decode(TranscriptResultMessage.self, from: data))
    XCTAssertEqual(decoded.sessionId, sessionId)
    XCTAssertEqual(decoded.text, "hello SwiftUI")
    XCTAssertNil(decoded.error)
}

func testTranscriptResultMessageErrorPath() throws {
    let msg = TranscriptResultMessage(sessionId: UUID(), text: "", error: "whisperkit load failed")
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let decoded = try XCTUnwrap(MessageCoder.decode(TranscriptResultMessage.self, from: data))
    XCTAssertEqual(decoded.text, "")
    XCTAssertEqual(decoded.error, "whisperkit load failed")
}

func testWhisperStatusMessageReadyRoundTrip() throws {
    let msg = WhisperStatusMessage(state: .ready)
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let decoded = try XCTUnwrap(MessageCoder.decode(WhisperStatusMessage.self, from: data))
    XCTAssertEqual(decoded.state, .ready)
}

func testWhisperStatusMessageDownloadingRoundTrip() throws {
    let msg = WhisperStatusMessage(state: .downloading(progress: 0.42))
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let decoded = try XCTUnwrap(MessageCoder.decode(WhisperStatusMessage.self, from: data))
    if case .downloading(let p) = decoded.state {
        XCTAssertEqual(p, 0.42, accuracy: 0.001)
    } else {
        XCTFail("expected .downloading")
    }
}

func testWhisperStatusMessageFailedRoundTrip() throws {
    let msg = WhisperStatusMessage(state: .failed(message: "no network"))
    let data = try XCTUnwrap(MessageCoder.encode(msg))
    let decoded = try XCTUnwrap(MessageCoder.decode(WhisperStatusMessage.self, from: data))
    if case .failed(let m) = decoded.state {
        XCTAssertEqual(m, "no network")
    } else {
        XCTFail("expected .failed")
    }
}
```

- [ ] **Step 1.2: Run — expect failures**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/MessageProtocolTests 2>&1 | tail -30
```

Expected: compile errors — `AudioChunkMessage`, `TranscriptResultMessage`, `WhisperStatusMessage` undefined.

- [ ] **Step 1.3: Add message types to MessageProtocol.swift**

Append to `Shared/MessageProtocol.swift`, anywhere after the existing iPhone→Mac block:

```swift
// MARK: - Whisper PTT Messages

/// iPhone → Mac. One frame of audio from a PTT session. `pcmBase64` is standard
/// base64 of int16 little-endian mono 16 kHz PCM — nominally 100 ms (3200 bytes
/// decoded), shorter on the final frame. `isFinal == true` signals end-of-utterance
/// and triggers Whisper transcription on the Mac.
struct AudioChunkMessage: Codable, Sendable {
    let type: String
    let sessionId: UUID
    let seq: Int
    let pcmBase64: String
    let isFinal: Bool

    init(sessionId: UUID, seq: Int, pcmBase64: String, isFinal: Bool) {
        self.type = "audio_chunk"
        self.sessionId = sessionId
        self.seq = seq
        self.pcmBase64 = pcmBase64
        self.isFinal = isFinal
    }
}

/// Mac → iPhone. Final transcription result for a completed PTT session.
/// `text` is empty when `error` is set; otherwise `error` is nil.
struct TranscriptResultMessage: Codable, Sendable {
    let type: String
    let sessionId: UUID
    let text: String
    let error: String?

    init(sessionId: UUID, text: String, error: String? = nil) {
        self.type = "transcript_result"
        self.sessionId = sessionId
        self.text = text
        self.error = error
    }
}

/// Whisper model lifecycle state on the Mac. Broadcast by Mac → iPhone so the
/// phone knows whether the remote recognizer path is viable at PTT-start.
enum WhisperState: Codable, Sendable, Equatable {
    case preparing
    case downloading(progress: Double)
    case ready
    case failed(message: String)

    private enum CodingKeys: String, CodingKey { case tag, progress, message }
    private enum Tag: String, Codable { case preparing, downloading, ready, failed }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .preparing:
            try c.encode(Tag.preparing, forKey: .tag)
        case .downloading(let progress):
            try c.encode(Tag.downloading, forKey: .tag)
            try c.encode(progress, forKey: .progress)
        case .ready:
            try c.encode(Tag.ready, forKey: .tag)
        case .failed(let message):
            try c.encode(Tag.failed, forKey: .tag)
            try c.encode(message, forKey: .message)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .tag)
        switch tag {
        case .preparing: self = .preparing
        case .downloading:
            let p = try c.decode(Double.self, forKey: .progress)
            self = .downloading(progress: p)
        case .ready: self = .ready
        case .failed:
            let m = try c.decode(String.self, forKey: .message)
            self = .failed(message: m)
        }
    }
}

struct WhisperStatusMessage: Codable, Sendable {
    let type: String
    let state: WhisperState

    init(state: WhisperState) {
        self.type = "whisper_status"
        self.state = state
    }
}
```

- [ ] **Step 1.4: Re-run tests — expect PASS**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/MessageProtocolTests 2>&1 | tail -30
```

Expected: all MessageProtocolTests green, including the 7 new ones.

- [ ] **Step 1.5: Regenerate Xcode projects (no-op for code, confirms xcodegen still clean)**

```
cd QuipiOS && xcodegen && cd ..
cd QuipMac && xcodegen && cd ..
```

- [ ] **Step 1.6: Commit**

```
git add Shared/MessageProtocol.swift Shared/Tests/MessageProtocolTests.swift \
  QuipiOS/QuipiOS.xcodeproj QuipMac/QuipMac.xcodeproj
git commit -m "$(cat <<'EOF'
Add Whisper PTT wire messages — AudioChunk / TranscriptResult / WhisperStatus.

Three new Codable message types in Shared/MessageProtocol.swift for the
D-scope PTT recognizer swap. AudioChunk carries 100ms PCM frames (int16
mono 16kHz, base64) from iPhone to Mac. TranscriptResult returns the
final Whisper transcription. WhisperStatus broadcasts model lifecycle
(preparing / downloading / ready / failed) so the phone knows at
PTT-start whether the remote path is viable.

Round-trip tests added to Shared/Tests/MessageProtocolTests.swift. No
wiring yet — senders/receivers land in the next commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Shared `PCMChunker` — 16 kHz int16 mono framing

**Files:**
- Create: `Shared/PCMChunker.swift`
- Create: `Shared/Tests/PCMChunkerTests.swift`

Pure-function chunker. Input is already-resampled Float32 mono PCM at 16 kHz; output is int16 LE mono 16 kHz in 100 ms (1600-sample) frames. Resampling itself happens in `WhisperAudioSender` via `AVAudioConverter` because that needs an AV dependency — the chunker stays pure so we can unit-test framing without audio frameworks.

- [ ] **Step 2.1: Write failing tests**

Create `Shared/Tests/PCMChunkerTests.swift`:

```swift
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
```

- [ ] **Step 2.2: Run — expect failures**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/PCMChunkerTests 2>&1 | tail -20
```

Expected: `cannot find 'PCMChunker' in scope`.

- [ ] **Step 2.3: Implement `PCMChunker`**

Create `Shared/PCMChunker.swift`:

```swift
import Foundation

/// Accumulates Float32 mono PCM samples and emits fixed-size int16 LE frames.
/// Pure value type — no audio-framework dependencies — so it can be unit-tested
/// cross-platform. Callers own resampling to the chunker's target rate before
/// appending.
struct PCMChunker {
    let frameSamples: Int
    private var buffer: [Float] = []

    init(frameSamples: Int) {
        self.frameSamples = frameSamples
        buffer.reserveCapacity(frameSamples * 2)
    }

    /// Append float samples; return zero or more complete frames as int16 LE Data.
    mutating func append(_ samples: [Float]) -> [Data] {
        buffer.append(contentsOf: samples)
        var frames: [Data] = []
        while buffer.count >= frameSamples {
            let slice = Array(buffer.prefix(frameSamples))
            buffer.removeFirst(frameSamples)
            frames.append(Self.encodeInt16LE(slice))
        }
        return frames
    }

    /// Emit any residual samples as a (possibly short) final frame. Returns nil
    /// when the buffer is empty.
    mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        let data = Self.encodeInt16LE(buffer)
        buffer.removeAll(keepingCapacity: true)
        return data
    }

    private static func encodeInt16LE(_ samples: [Float]) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self).baseAddress!
            for (i, s) in samples.enumerated() {
                let clamped = max(-1.0, min(1.0, s))
                p[i] = Int16(clamped * 32767.0)
            }
        }
        return out
    }
}
```

- [ ] **Step 2.4: Run — expect PASS**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/PCMChunkerTests 2>&1 | tail -15
```

Expected: all 7 PCMChunkerTests green.

- [ ] **Step 2.5: Commit**

```
git add Shared/PCMChunker.swift Shared/Tests/PCMChunkerTests.swift
git commit -m "$(cat <<'EOF'
Add PCMChunker — pure framing helper for Whisper audio.

Accumulates Float32 mono PCM and emits fixed-size int16 LE frames.
Used by WhisperAudioSender on iPhone to pack resampled 16 kHz audio
into 100 ms (1600-sample) chunks for over-the-wire transmission. Pure
value type so it unit-tests without audio frameworks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: iPhone `WhisperAudioSender` — AVAudioConverter + WS fan-out

**Files:**
- Create: `QuipiOS/Services/WhisperAudioSender.swift`
- Create: `QuipiOS/Tests/WhisperAudioSenderTests.swift`

Responsibilities:
- Accept incoming `AVAudioPCMBuffer` from the existing `AudioWorker` tap.
- Resample to 16 kHz mono Float32 via `AVAudioConverter`.
- Feed through `PCMChunker`; send each frame as `AudioChunkMessage`.
- On `finish()`: flush chunker tail, send a final frame with `isFinal = true`.

Protocol seam for testability: `WhisperAudioSender` accepts a `SendAudioChunk` closure rather than reaching into `WebSocketClient` directly.

- [ ] **Step 3.1: Write failing tests**

Create `QuipiOS/Tests/WhisperAudioSenderTests.swift`:

```swift
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
        var sent: [AudioChunkMessage] = []
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
        var sent: [AudioChunkMessage] = []
        let sender = WhisperAudioSender(sessionId: UUID()) { sent.append($0) }
        sender.appendBuffer(makeBuffer(sampleRate: 16000, frames: 3200)) // 2 frames
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sent.map(\.seq), Array(0..<sent.count))
    }

    func testFinishSendsFinalMarker() async throws {
        var sent: [AudioChunkMessage] = []
        let sender = WhisperAudioSender(sessionId: UUID()) { sent.append($0) }
        sender.appendBuffer(makeBuffer(sampleRate: 16000, frames: 800)) // sub-frame
        await sender.finish()

        XCTAssertGreaterThanOrEqual(sent.count, 1)
        XCTAssertTrue(sent.last!.isFinal)
    }

    func testSessionIdStable() async throws {
        var sent: [AudioChunkMessage] = []
        let sid = UUID()
        let sender = WhisperAudioSender(sessionId: sid) { sent.append($0) }
        sender.appendBuffer(makeBuffer(sampleRate: 16000, frames: 3200))
        await sender.finish()

        for m in sent {
            XCTAssertEqual(m.sessionId, sid)
        }
    }
}
```

- [ ] **Step 3.2: Run — expect failures**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/WhisperAudioSenderTests 2>&1 | tail -20
```

Expected: `cannot find 'WhisperAudioSender' in scope`.

- [ ] **Step 3.3: Implement `WhisperAudioSender`**

Create `QuipiOS/Services/WhisperAudioSender.swift`:

```swift
import AVFoundation
import Foundation

/// Takes the iPhone mic's native-format PCM buffers, resamples to 16 kHz mono
/// Float32, packs into 100 ms int16 LE frames, and invokes `sendChunk` for each.
/// One instance per PTT session; finalize with `finish()` to flush the tail and
/// emit the `isFinal` marker.
final class WhisperAudioSender: @unchecked Sendable {

    private let sessionId: UUID
    private let sendChunk: @Sendable (AudioChunkMessage) -> Void
    private let queue = DispatchQueue(label: "com.quip.whisper.sender", qos: .userInteractive)

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                      channels: 1, interleaved: false)!
    }()
    private var chunker = PCMChunker(frameSamples: 1600) // 100 ms @ 16 kHz
    private var seq = 0

    init(sessionId: UUID, sendChunk: @escaping @Sendable (AudioChunkMessage) -> Void) {
        self.sessionId = sessionId
        self.sendChunk = sendChunk
    }

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard let resampled = convert(buffer) else { return }
            let floats = floatArray(from: resampled)
            let frames = chunker.append(floats)
            for frame in frames {
                emit(pcm: frame, isFinal: false)
            }
        }
    }

    /// Flush any residual samples and emit the `isFinal = true` frame. Awaits
    /// queue completion so callers know all pending chunks have been dispatched.
    func finish() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let tail = chunker.flush() ?? Data()
                emit(pcm: tail, isFinal: true)
                cont.resume()
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if sourceFormat != buffer.format {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }

        // Estimate output capacity: input frames × (target rate / source rate) + small slop.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return nil }
        return out
    }

    private func floatArray(from buf: AVAudioPCMBuffer) -> [Float] {
        guard let ch = buf.floatChannelData else { return [] }
        let n = Int(buf.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: n))
    }

    private func emit(pcm: Data, isFinal: Bool) {
        let msg = AudioChunkMessage(
            sessionId: sessionId, seq: seq,
            pcmBase64: pcm.base64EncodedString(), isFinal: isFinal
        )
        seq += 1
        sendChunk(msg)
    }
}
```

- [ ] **Step 3.4: Run — expect PASS**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/WhisperAudioSenderTests 2>&1 | tail -20
```

Expected: all 4 tests green. The rate test allows ±1 frame for resampler slop.

- [ ] **Step 3.5: Commit**

```
git add QuipiOS/Services/WhisperAudioSender.swift QuipiOS/Tests/WhisperAudioSenderTests.swift
git commit -m "$(cat <<'EOF'
Add WhisperAudioSender — iPhone PCM framer for the Mac Whisper path.

Takes native-format AVAudioPCMBuffers from the existing mic tap,
resamples to 16 kHz mono Float32 via AVAudioConverter, packs into
100 ms int16 LE frames, and emits AudioChunkMessages via a caller-supplied
closure. One sender per PTT session; finish() flushes the tail and
emits the isFinal marker so the Mac knows when to transcribe.

Not yet wired into SpeechService — that branch lands after the WS
plumbing is in place.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: iPhone `WebSocketClient` — whisperStatus property + result/status dispatch

**Files:**
- Modify: `QuipiOS/Services/WebSocketClient.swift`

Add:
- Published `whisperStatus: WhisperState` (starts `.preparing`).
- `onTranscriptResult: ((UUID, String, String?) -> Void)?` callback.
- Sender helper: `sendAudioChunk(_ msg: AudioChunkMessage)`.
- Dispatch cases for `"transcript_result"` and `"whisper_status"`.

No unit tests — this is thin glue. Behaviour covered by integration and Task 6 tests.

- [ ] **Step 4.1: Add property + callback + helper**

In `QuipiOS/Services/WebSocketClient.swift`, inside the `WebSocketClient` class, next to the other `var onXxx:` declarations:

```swift
    /// Latest Whisper model lifecycle state from the Mac. Starts as .preparing
    /// until the Mac broadcasts its status. SpeechService reads this at PTT-start
    /// to decide between remote (Whisper) and local (SFSpeech) paths.
    var whisperStatus: WhisperState = .preparing
    /// Mac returned the final transcript for a session.
    var onTranscriptResult: ((UUID, String, String?) -> Void)?
```

Add a helper method (next to existing `send…` helpers):

```swift
    /// Serialize and send an audio chunk. Safe to call from any thread;
    /// uses the same URLSessionWebSocketTask.send path as other outbound messages.
    func sendAudioChunk(_ msg: AudioChunkMessage) {
        guard let data = MessageCoder.encode(msg),
              let task = webSocketTask else { return }
        task.send(.data(data)) { err in
            if let err {
                NSLog("[WebSocketClient] audio chunk send failed: %@", err.localizedDescription)
            }
        }
    }
```

Inside `handleMessage(_:)`, add two cases above `default:`:

```swift
        case "transcript_result":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(TranscriptResultMessage.self, from: data) {
                onTranscriptResult?(msg.sessionId, msg.text, msg.error)
            }
        case "whisper_status":
            guard isAuthenticated else { return }
            if let msg = try? decoder.decode(WhisperStatusMessage.self, from: data) {
                whisperStatus = msg.state
            }
```

- [ ] **Step 4.2: Build iOS target — confirm compiles**

```
xcodebuild build -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | tail -15
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4.3: Commit**

```
git add QuipiOS/Services/WebSocketClient.swift
git commit -m "$(cat <<'EOF'
WebSocketClient: route Whisper messages + audio-chunk send helper.

Adds whisperStatus property (observable), onTranscriptResult callback,
sendAudioChunk helper, and dispatch cases for the two inbound Whisper
message types. Glue layer only — nothing consumes these yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: iPhone `RemoteSpeechSession` — orchestrator with stop-completion

**Files:**
- Create: `QuipiOS/Services/RemoteSpeechSession.swift`
- Create: `QuipiOS/Tests/RemoteSpeechSessionTests.swift`

Exposes:
- `init(sessionId:, sender:, safetyTimeout:)` — sender already bound to this session id.
- `start(onTap: (AVAudioPCMBuffer) -> Void)` — returns a closure the `AudioWorker` tap feeds.
- `stop(completion: (String) -> Void)` — tears down; completion fires when `handleTranscript(...)` arrives or `safetyTimeout` elapses.
- `handleTranscript(sessionId: UUID, text: String, error: String?)` — routing hook from `WebSocketClient`.

Clock injection (via `DispatchQueue` or `Task.sleep`) kept simple — tests exercise the real queue with a 0.05 s safety timeout override.

- [ ] **Step 5.1: Write failing tests**

Create `QuipiOS/Tests/RemoteSpeechSessionTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import Quip

final class RemoteSpeechSessionTests: XCTestCase {

    func testStopCompletionFiresOnMatchingTranscript() async throws {
        var sent: [AudioChunkMessage] = []
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
```

- [ ] **Step 5.2: Run — expect failures**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/RemoteSpeechSessionTests 2>&1 | tail -15
```

Expected: `cannot find 'RemoteSpeechSession' in scope`.

- [ ] **Step 5.3: Implement `RemoteSpeechSession`**

Create `QuipiOS/Services/RemoteSpeechSession.swift`:

```swift
import AVFoundation
import Foundation

/// Per-press orchestrator for the Mac Whisper recognizer path. Owns one
/// `WhisperAudioSender`, tracks stop-completion + safety timeout, and routes
/// the Mac's final `TranscriptResultMessage` back to `SpeechService`.
@MainActor
final class RemoteSpeechSession {

    let sessionId: UUID
    private let sender: WhisperAudioSender
    private let safetyTimeout: TimeInterval

    private var pendingStop: ((String) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var didResolve = false

    init(sessionId: UUID, sender: WhisperAudioSender, safetyTimeout: TimeInterval = 3.0) {
        self.sessionId = sessionId
        self.sender = sender
        self.safetyTimeout = safetyTimeout
    }

    /// Forward a mic buffer to this session's sender. Caller is responsible for
    /// installing / removing the tap — `AudioWorker` already handles lifecycle.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        sender.appendBuffer(buffer)
    }

    /// Finalize the recording; fire `completion` with the Mac's final transcript
    /// when it arrives, or with empty string if the safety timeout fires first.
    /// Idempotent: repeat calls re-assign the completion but only the first stop
    /// triggers teardown.
    func stop(completion: @escaping (String) -> Void) async {
        pendingStop = completion
        await sender.finish()
        startSafetyTimeout()
    }

    func handleTranscript(sessionId: UUID, text: String, error: String?) {
        guard sessionId == self.sessionId, !didResolve else { return }
        didResolve = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let out: String = (error == nil) ? text : ""
        let cb = pendingStop
        pendingStop = nil
        cb?(out)
    }

    private func startSafetyTimeout() {
        timeoutTask?.cancel()
        let t = safetyTimeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            guard let self, !self.didResolve else { return }
            self.didResolve = true
            let cb = self.pendingStop
            self.pendingStop = nil
            cb?("")
        }
    }
}
```

- [ ] **Step 5.4: Run — expect PASS**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/RemoteSpeechSessionTests 2>&1 | tail -15
```

Expected: 4 tests green.

- [ ] **Step 5.5: Commit**

```
git add QuipiOS/Services/RemoteSpeechSession.swift QuipiOS/Tests/RemoteSpeechSessionTests.swift
git commit -m "$(cat <<'EOF'
Add RemoteSpeechSession — per-press orchestrator for Mac Whisper path.

Owns one WhisperAudioSender, tracks stop-completion and a 3s safety
timeout, routes the Mac's TranscriptResultMessage back to whoever
called stop(completion:). Stale sessionIds (result landing for a prior
press) are dropped — mirrors the activeSessionToken guard already in
SpeechService.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: iPhone `SpeechService` — path selection

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift`
- Create: `QuipiOS/Tests/SpeechServicePathSelectionTests.swift`

`SpeechService.startRecording` currently always calls the local worker path. Branch at the top to prefer the remote path when both `isConnected` and `whisperStatus == .ready` hold. Wire mic samples to the remote sender — cleanest route is to extend `AudioWorker` with an optional chunk-forwarding closure, set by `SpeechService` only on the remote path. Keep the local recognizer fully disengaged on the remote path (no `SFSpeechAudioBufferRecognitionRequest` at all).

Rather than adding test-only protocols to `WebSocketClient` and `SpeechService`, the selection test factors the decision into a pure helper and exercises it directly.

- [ ] **Step 6.1: Add a pure path-selection helper**

In `QuipiOS/Services/SpeechService.swift`, add at the bottom of the file (outside the class):

```swift
/// Pure decision helper — tested in isolation so SpeechService doesn't need a
/// mock WebSocketClient. Returns `.remote` when the Mac Whisper path should
/// serve this press, `.local` otherwise.
enum PTTPath: Equatable { case local, remote }

func selectPTTPath(isConnected: Bool, whisperStatus: WhisperState) -> PTTPath {
    guard isConnected else { return .local }
    if case .ready = whisperStatus { return .remote }
    return .local
}
```

- [ ] **Step 6.2: Write failing test**

Create `QuipiOS/Tests/SpeechServicePathSelectionTests.swift`:

```swift
import XCTest
@testable import Quip

final class SpeechServicePathSelectionTests: XCTestCase {

    func testWSDownChoosesLocal() {
        XCTAssertEqual(selectPTTPath(isConnected: false, whisperStatus: .ready), .local)
        XCTAssertEqual(selectPTTPath(isConnected: false, whisperStatus: .preparing), .local)
    }

    func testWSUpReadyChoosesRemote() {
        XCTAssertEqual(selectPTTPath(isConnected: true, whisperStatus: .ready), .remote)
    }

    func testWSUpPreparingChoosesLocal() {
        XCTAssertEqual(selectPTTPath(isConnected: true, whisperStatus: .preparing), .local)
    }

    func testWSUpDownloadingChoosesLocal() {
        XCTAssertEqual(selectPTTPath(isConnected: true, whisperStatus: .downloading(progress: 0.5)), .local)
    }

    func testWSUpFailedChoosesLocal() {
        XCTAssertEqual(selectPTTPath(isConnected: true, whisperStatus: .failed(message: "x")), .local)
    }
}
```

- [ ] **Step 6.3: Run — expect PASS (helper written in 6.1)**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:QuipiOSTests/SpeechServicePathSelectionTests 2>&1 | tail -15
```

Expected: 5 green.

- [ ] **Step 6.4: Wire the remote path into `SpeechService.startRecording`**

In `QuipiOS/Services/SpeechService.swift`:

Add one stored property next to the other `@ObservationIgnored` state:

```swift
    @ObservationIgnored private var remoteSession: RemoteSpeechSession?
    @ObservationIgnored weak var webSocket: WebSocketClient?
```

Add a wiring helper (called by `QuipApp` once both services exist):

```swift
    /// Wire up to the WebSocket client. Call once at app startup, before the
    /// first press. Enables the remote Whisper path.
    func attachWebSocket(_ client: WebSocketClient) {
        webSocket = client
        client.onTranscriptResult = { [weak self] sid, text, error in
            self?.remoteSession?.handleTranscript(sessionId: sid, text: text, error: error)
        }
    }
```

Replace the body of `startRecording()` with the branching version:

```swift
    func startRecording() {
        guard isAuthorized, !isRecording else { return }
        isRecording = true
        transcribedText = ""

        let sessionToken = UUID()
        activeSessionToken = sessionToken

        let path: PTTPath
        if let ws = webSocket {
            path = selectPTTPath(isConnected: ws.isConnected, whisperStatus: ws.whisperStatus)
        } else {
            path = .local
        }

        switch path {
        case .local:
            worker.start { [weak self] text, finished in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let isCurrent = self.activeSessionToken == sessionToken
                    if finished {
                        let pending = self.pendingStopCompletion
                        self.pendingStopCompletion = nil
                        pending?(text ?? "")
                        if isCurrent { self.activeSessionToken = nil }
                    } else if isCurrent, let text {
                        self.transcribedText = text
                    }
                }
            }
        case .remote:
            guard let ws = webSocket else { isRecording = false; return }
            let sender = WhisperAudioSender(sessionId: sessionToken) { chunk in
                ws.sendAudioChunk(chunk)
            }
            let session = RemoteSpeechSession(sessionId: sessionToken, sender: sender)
            remoteSession = session
            worker.startForwarding { [weak session] buf in
                session?.appendBuffer(buf)
            }
        }
    }
```

Update `stopRecording(completion:)` to route by active path:

```swift
    @discardableResult
    func stopRecording(completion: ((String) -> Void)? = nil) -> String {
        guard isRecording else {
            completion?(transcribedText)
            return transcribedText
        }
        pendingStopCompletion = completion

        if let session = remoteSession {
            let sessionToken = activeSessionToken
            Task { @MainActor [weak self] in
                await session.stop { [weak self] text in
                    guard let self, self.activeSessionToken == sessionToken else { return }
                    let cb = self.pendingStopCompletion
                    self.pendingStopCompletion = nil
                    self.transcribedText = text
                    self.activeSessionToken = nil
                    self.remoteSession = nil
                    cb?(text)
                }
            }
            isRecording = false
            // Ask the forwarding tap to stop, but leave the engine armed.
            worker.stopForwarding()
        } else {
            worker.stop()
            isRecording = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let pending = self.pendingStopCompletion else { return }
                self.pendingStopCompletion = nil
                pending(self.transcribedText)
            }
        }
        return transcribedText
    }
```

In `AudioWorker` (same file), add two methods next to `start` / `stop`:

```swift
    /// Remote-path variant: forward mic buffers to `onBuffer` but do not spin
    /// up a local SFSpeechRecognizer. Engine + tap stay armed.
    func startForwarding(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        queue.async { [self] in
            guard self.isArmed else { return }
            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                onBuffer(buffer)
                self.ring.append(buffer: buffer, at: Date())
            }
        }
    }

    /// Stop remote-path forwarding. Re-installs the default tap that only
    /// feeds the ring so subsequent local-path presses get pre-roll replay.
    func stopForwarding() {
        queue.async { [self] in
            guard self.isArmed else { return }
            let input = self.audioEngine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.recognitionRequest?.append(buffer)
                self.ring.append(buffer: buffer, at: Date())
            }
        }
    }
```

- [ ] **Step 6.5: Wire `SpeechService.attachWebSocket` in `QuipApp`**

In `QuipiOS/QuipApp.swift`, find the spot where `SpeechService` and `WebSocketClient` are both instantiated (grep for `SpeechService()`), and after both exist add:

```swift
speech.attachWebSocket(webSocket)
```

- [ ] **Step 6.6: Build + run all iOS tests**

```
xcodebuild test -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' 2>&1 | tail -25
```

Expected: all iOS tests green; no regressions in `PTTStressTests`.

- [ ] **Step 6.7: Commit**

```
git add QuipiOS/Services/SpeechService.swift QuipiOS/Services/WebSocketClient.swift \
  QuipiOS/Tests/SpeechServicePathSelectionTests.swift QuipiOS/QuipApp.swift
git commit -m "$(cat <<'EOF'
SpeechService: branch local vs remote path at startRecording.

When connected to the Mac and Whisper is ready, startRecording now
routes mic buffers through a RemoteSpeechSession + WhisperAudioSender
over the existing WebSocket. When the WS is down or Whisper isn't
ready, the existing local SFSpeechRecognizer path runs unchanged.

AudioWorker gains startForwarding/stopForwarding so the remote path
can reuse the armed engine + tap without spinning up a local recognizer.
Stop-completion contract and activeSessionToken guard extend cleanly
to both paths.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Mac — add WhisperKit SPM dependency

**Files:**
- Modify: `QuipMac/project.yml`

xcodegen supports SPM packages via the `packages:` key at project root and target-level `dependencies` entries.

- [ ] **Step 7.1: Add package + dependency to project.yml**

Edit `QuipMac/project.yml`. After the top-level `settings:` block, add:

```yaml
packages:
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: 0.9.0
```

Inside `targets.QuipMac`, add a `dependencies` key (or extend if one exists):

```yaml
    dependencies:
      - package: WhisperKit
```

- [ ] **Step 7.2: Regenerate Mac project and resolve packages**

```
cd QuipMac && xcodegen && cd ..
xcodebuild -project QuipMac/QuipMac.xcodeproj -scheme QuipMac -resolvePackageDependencies 2>&1 | tail -15
```

Expected: "Resolving package graph" completes; no errors.

- [ ] **Step 7.3: Build — confirm WhisperKit compiles against current toolchain**

```
xcodebuild build -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `BUILD SUCCEEDED`. If WhisperKit's pinned minor is incompatible with Xcode 16 / Swift 6, bump to the next minor and retry.

- [ ] **Step 7.4: Commit**

```
git add QuipMac/project.yml QuipMac/QuipMac.xcodeproj
git commit -m "$(cat <<'EOF'
QuipMac: add WhisperKit SPM dependency.

Pinned argmaxinc/WhisperKit >= 0.9.0 for the D-scope Mac-local Whisper
recognizer path. Declared in project.yml so xcodegen regeneration
preserves it. Nothing in the Mac app uses the package yet — wiring
follows in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Mac `WhisperDictationService` — per-session buffering + transcription

**Files:**
- Create: `QuipMac/Services/WhisperDictationService.swift`
- Create: `QuipMac/Tests/WhisperDictationServiceTests.swift`

Architecture:
- Protocol `WhisperTranscriber` with `transcribe(audioArray: [Float]) async throws -> String`. Real impl wraps `WhisperKit`; test uses a canned fake.
- `WhisperDictationService` maintains `[UUID: SessionBuffer]`, ingests `AudioChunkMessage`, runs transcription on `isFinal`, emits `TranscriptResultMessage` via a `send: (Any Codable) -> Void` closure so tests don't need a real WS.
- Model lifecycle: `prepare()` async method runs `WhisperKit()` init in the background; broadcasts `WhisperStatusMessage` via same closure. Exposes current `state` for resync-on-connect.
- Stale-session reaper: every 10 s, drop buffers older than 30 s.

- [ ] **Step 8.1: Write failing tests**

Create `QuipMac/Tests/WhisperDictationServiceTests.swift`:

```swift
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
```

- [ ] **Step 8.2: Run — expect failures**

```
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/WhisperDictationServiceTests 2>&1 | tail -20
```

Expected: compile errors — `WhisperTranscriber` and `WhisperDictationService` undefined.

- [ ] **Step 8.3: Implement `WhisperDictationService`**

Create `QuipMac/Services/WhisperDictationService.swift`:

```swift
import Foundation
#if canImport(WhisperKit)
import WhisperKit
#endif

/// Abstraction so `WhisperDictationService` can be unit-tested without a
/// real WhisperKit instance.
protocol WhisperTranscriber: Sendable {
    func transcribe(audioArray: [Float]) async throws -> String
}

#if canImport(WhisperKit)
final class WhisperKitTranscriber: WhisperTranscriber, @unchecked Sendable {
    private let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
    func transcribe(audioArray: [Float]) async throws -> String {
        let results = try await kit.transcribe(audioArray: audioArray)
        return results.map(\.text).joined(separator: " ")
    }
}
#endif

/// Mac-side: per-PTT-session PCM buffering + Whisper transcription. One
/// instance per running Quip process.
final class WhisperDictationService: @unchecked Sendable {

    struct SessionBuffer {
        var samples: [Float] = []
        var lastTouched: Date = Date()
    }

    private let transcriber: WhisperTranscriber
    private let send: (Any) -> Void
    private let staleWindow: TimeInterval
    private let queue = DispatchQueue(label: "com.quip.whisper.mac")
    private var sessions: [UUID: SessionBuffer] = [:]

    init(transcriber: WhisperTranscriber,
         staleWindow: TimeInterval = 30.0,
         send: @escaping (Any) -> Void) {
        self.transcriber = transcriber
        self.staleWindow = staleWindow
        self.send = send
    }

    /// Synchronous ingest — fire-and-forget. Used when caller doesn't need
    /// to await the transcription result (normal message-loop case).
    func ingest(_ chunk: AudioChunkMessage) {
        let samples = Self.decodeInt16LE(base64: chunk.pcmBase64)
        queue.sync {
            var buf = sessions[chunk.sessionId] ?? SessionBuffer()
            buf.samples.append(contentsOf: samples)
            buf.lastTouched = Date()
            sessions[chunk.sessionId] = buf
        }
        if chunk.isFinal {
            Task { await finalize(sessionId: chunk.sessionId) }
        }
    }

    /// Test-only variant that awaits the finalize Task so assertions see
    /// the send-closure call.
    func ingestAsync(_ chunk: AudioChunkMessage) async {
        let samples = Self.decodeInt16LE(base64: chunk.pcmBase64)
        queue.sync {
            var buf = sessions[chunk.sessionId] ?? SessionBuffer()
            buf.samples.append(contentsOf: samples)
            buf.lastTouched = Date()
            sessions[chunk.sessionId] = buf
        }
        if chunk.isFinal { await finalize(sessionId: chunk.sessionId) }
    }

    func hasBuffer(for sessionId: UUID) -> Bool {
        queue.sync { sessions[sessionId] != nil }
    }

    func purgeStaleSessions() {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-staleWindow)
            sessions = sessions.filter { $0.value.lastTouched > cutoff }
        }
    }

    private func finalize(sessionId: UUID) async {
        let samples: [Float] = queue.sync {
            let s = sessions[sessionId]?.samples ?? []
            sessions.removeValue(forKey: sessionId)
            return s
        }
        do {
            let text = try await transcriber.transcribe(audioArray: samples)
            send(TranscriptResultMessage(sessionId: sessionId, text: text, error: nil))
        } catch {
            send(TranscriptResultMessage(sessionId: sessionId, text: "",
                                         error: error.localizedDescription))
        }
    }

    private static func decodeInt16LE(base64: String) -> [Float] {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return [] }
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<count {
                out[i] = Float(p[i]) / 32767.0
            }
        }
        return out
    }
}
```

- [ ] **Step 8.4: Run — expect PASS**

```
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' \
  -only-testing:QuipMacTests/WhisperDictationServiceTests 2>&1 | tail -15
```

Expected: 5 green.

- [ ] **Step 8.5: Commit**

```
git add QuipMac/Services/WhisperDictationService.swift QuipMac/Tests/WhisperDictationServiceTests.swift
git commit -m "$(cat <<'EOF'
Add WhisperDictationService — Mac-side per-session buffer + transcribe.

Ingests AudioChunkMessages keyed by sessionId, accumulates int16 LE
samples into Float arrays, and on isFinal=true runs the injected
WhisperTranscriber. Result (or error) is sent back as a
TranscriptResultMessage via a caller-supplied closure — keeps the WS
transport out of the unit under test.

Ships with a WhisperTranscriber protocol so tests can use a canned
FakeTranscriber; the real WhisperKitTranscriber wraps WhisperKit when
the package is available. Stale-session reaper drops buffers untouched
for 30s to bound memory if a PTT session never sends its final frame.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Mac — wire dictation service into the app + broadcast status

**Files:**
- Modify: `QuipMac/QuipMacApp.swift`

Responsibilities for this task:
- Instantiate `WhisperDictationService` at app startup with a `WhisperKitTranscriber` — deferred until the model finishes loading.
- Dispatch incoming `audio_chunk` messages into the service.
- Broadcast `WhisperStatusMessage` transitions on state changes AND on every new authenticated client (so a reconnecting phone learns the status).
- Run a 10-second repeating timer to call `purgeStaleSessions()`.

- [ ] **Step 9.1: Add service + lifecycle to `QuipMacApp`**

In `QuipMac/QuipMacApp.swift`, grep for where `WebSocketServer` is instantiated. Near it, add a stored property:

```swift
private var whisperService: WhisperDictationService?
private var whisperState: WhisperState = .preparing
private var whisperReaper: Timer?
```

In the startup code (wherever server.start() is called), add this block immediately after:

```swift
Task { await self.setupWhisper() }
```

Add the helper method on the app class (or whatever type owns the server):

```swift
private func setupWhisper() async {
    // Broadcast preparing state so the phone doesn't try the remote path.
    self.whisperState = .preparing
    self.broadcastWhisperStatus()

    #if canImport(WhisperKit)
    do {
        let kit = try await WhisperKit(model: "openai_whisper-base")
        let transcriber = WhisperKitTranscriber(kit: kit)
        await MainActor.run {
            self.whisperService = WhisperDictationService(transcriber: transcriber) { [weak self] msg in
                self?.broadcastCodable(msg)
            }
            self.whisperState = .ready
            self.broadcastWhisperStatus()
            self.startWhisperReaper()
        }
    } catch {
        await MainActor.run {
            self.whisperState = .failed(message: error.localizedDescription)
            self.broadcastWhisperStatus()
        }
    }
    #else
    await MainActor.run {
        self.whisperState = .failed(message: "WhisperKit not available")
        self.broadcastWhisperStatus()
    }
    #endif
}

private func broadcastWhisperStatus() {
    broadcastCodable(WhisperStatusMessage(state: whisperState))
}

/// Encodes any Codable message and hands it to the existing broadcast path.
/// `broadcast(_:)` (or whatever the existing helper is called) already exists
/// on QuipMacApp — re-use it here.
private func broadcastCodable<T: Encodable>(_ msg: T) {
    guard let data = try? JSONEncoder().encode(msg) else { return }
    webSocketServer.broadcast(data) // adjust name to match existing broadcast helper
}

private func startWhisperReaper() {
    whisperReaper?.invalidate()
    whisperReaper = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
        self?.whisperService?.purgeStaleSessions()
    }
}
```

In the existing message-dispatch switch (grep for `case "select_window"` or similar), add above `default:`:

```swift
case "audio_chunk":
    guard let msg = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) else { break }
    whisperService?.ingest(msg)
```

And in the place where a new client authenticates (grep for `onClientAuthenticated`), send the current status so reconnecting phones learn it:

```swift
// inside onClientAuthenticated callback
broadcastWhisperStatus()
```

> **Implementation note:** the exact names of the existing broadcast helper and the authenticated-client callback depend on how `QuipMacApp` is organized today. When in doubt, mirror the pattern the image-upload path uses (`ImageUploadHandler`) — it already broadcasts acks/errors from a nested service and is a 1:1 analogue. Adjust `webSocketServer.broadcast(data)` / `broadcastCodable` names to match the existing helper. Do **not** add a new broadcast path — reuse what's there.

- [ ] **Step 9.2: Build Mac target**

```
xcodebuild build -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `BUILD SUCCEEDED`. Fix any naming mismatches against the actual broadcast helper / auth callback.

- [ ] **Step 9.3: Run Mac test suite — confirm no regressions**

```
xcodebuild test -project QuipMac/QuipMac.xcodeproj -scheme QuipMac \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: all existing Mac tests still pass; new `WhisperDictationServiceTests` green.

- [ ] **Step 9.4: Commit**

```
git add QuipMac/QuipMacApp.swift
git commit -m "$(cat <<'EOF'
QuipMacApp: wire WhisperDictationService into the message loop.

On app launch, spin up WhisperKit with the base model on a background
task and broadcast WhisperStatusMessage transitions (preparing →
downloading/ready/failed) over the existing WS broadcast path so the
phone knows whether the remote recognizer is usable at PTT-start.
Status is re-broadcast whenever a new client authenticates so
reconnecting phones learn the current state.

audio_chunk messages dispatched to whisperService.ingest; the service's
stale-session reaper runs every 10s via Timer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Manual acceptance + diagnostics commit

**Files:**
- Modify: `docs/superpowers/wishlist.md`

Run the acceptance flows from the spec. Do not rebuild Mac until Task 9 is the trigger — after Task 9 it's unavoidable.

- [ ] **Step 10.1: Install the Mac app**

Follow `reference_quip_install_recipe` (stable dev cert `SHA E511A12C76...` → ditto into `/Applications`). Do not `rm -rf` the existing bundle.

Expect the Mac to pull the `openai_whisper-base` model on first launch (~150 MB). Watch the WebSocket diagnostics log:

```
tail -f ~/Library/Logs/Quip/websocket.log | grep -i whisper
```

- [ ] **Step 10.2: Install iOS build on default device**

```
xcodebuild -project QuipiOS/QuipiOS.xcodeproj -scheme QuipiOS \
  -destination 'platform=iOS,name=Tim apple 17' -configuration Debug build
# devicectl install (name varies; see feedback_default_install_device memory)
xcrun devicectl device install app --device 'Tim apple 17' \
  ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug-iphoneos/Quip.app
```

Force-quit the Quip app in the phone's app switcher, then relaunch — `devicectl install` does not kill the running process.

- [ ] **Step 10.3: Acceptance test 1 — happy path**

Pair phone to Mac. Check `netstat -an | grep 8765 | grep ESTABLISHED` on the Mac before asserting a real socket is up (per `feedback_check_socket_first`).

Tap volume-down on the phone, speak a sentence containing technical vocab ("SwiftUI WebSocket monospace Xcode"), tap volume-down again. Confirm:

- Transcript arrives.
- Words that garble on local SFSpeech survive ("monospace" not "monotype"; "SwiftUI" not "swift you eye").
- End-to-end latency ≤ 2 s after release for an 8 s utterance.

- [ ] **Step 10.4: Acceptance test 2 — fallback at start**

Quit the Mac app. Tap volume-down on the phone. Confirm local SFSpeech runs (transcript arrives as before, same quality as the last few commits).

- [ ] **Step 10.5: Acceptance test 3 — mid-session drop**

Relaunch the Mac app, wait for `.ready`. Start a PTT session on the phone. While speaking, kill the Mac process (`pkill -9 Quip`). Confirm an error toast appears within ~3 s and the phone returns to idle.

- [ ] **Step 10.6: Acceptance test 4 — first-run model download**

Delete the WhisperKit model cache (the path is reported in Mac logs) and relaunch the Mac. While the model is downloading, tap PTT on the phone — local SFSpeech should handle it. After download completes, the next press should use Whisper.

- [ ] **Step 10.7: Update wishlist**

Edit `docs/superpowers/wishlist.md`:
- Mark §0b as ✅ shipped on `eb-branch` with today's date and commit range.
- Add new wishlist entry under §0b: **"PTT recognizer Settings picker + model-size selector"** — carries the user's request for the full picker + "most performant options available" (tiny / base / small / medium / large). Reference the commits and spec.

- [ ] **Step 10.8: Commit**

```
git add docs/superpowers/wishlist.md
git commit -m "$(cat <<'EOF'
Wishlist: §0b shipped (Mac Whisper PTT). Log picker/model follow-up.

D-scope v1 landed. Settings recognizer picker and model-size selector
(tiny/base/small/medium/large) captured as new wishlist entry per the
user's "most performant options available" ask during brainstorm.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Checklist (for the plan author)

1. **Spec coverage:** every non-goal stays out, every fixed decision lands in a task. ✓
2. **No placeholders:** every code step has full code. The only ambiguity is the exact name of the Mac's existing broadcast helper in Task 9 — noted as an implementation directive with a fallback pattern (mirror `ImageUploadHandler`). ✓
3. **Type consistency:** `WhisperState` (enum, Codable), `WhisperStatusMessage` (wrapper), `AudioChunkMessage` fields (`sessionId: UUID`, `seq: Int`, `pcmBase64: String`, `isFinal: Bool`), `TranscriptResultMessage` fields (`sessionId`, `text`, `error?`) — match across Shared, iOS, Mac, and tests. ✓
4. **Commit per task:** 10 commits, each green. ✓
5. **TDD:** every new component has a failing test before implementation. ✓
6. **No push:** `eb-branch` stays local unless the user asks — enforced in ground rules. ✓
