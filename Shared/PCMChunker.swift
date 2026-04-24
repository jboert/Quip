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
                p[i] = clamped >= 0 ? Int16(clamped * 32767.0) : Int16(clamped * 32768.0)
            }
        }
        return out
    }
}
