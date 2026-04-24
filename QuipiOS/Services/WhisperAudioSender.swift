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
