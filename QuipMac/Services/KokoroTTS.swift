import Foundation

/// Shared debug logger to /tmp/quip-kokoro.log (append-only).
/// Uses the throwing `write(contentsOf:)` API so write failures surface as
/// Swift errors instead of NSExceptions that would crash the app.
enum KokoroTTSDebug {
    static let path = "/tmp/quip-kokoro.log"
    private static let lock = NSLock()

    static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            if let handle = FileHandle(forWritingAtPath: path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: URL(fileURLWithPath: path))
            }
        } catch {
            // Swallow logging errors — never let the logger crash the app.
        }
    }
}

/// Persistent Python daemon for Kokoro TTS. Spawns one `kokoro_tts.py --daemon`
/// process per voice, keeps it alive, and streams length-prefixed requests/responses.
/// This avoids ~1.5s Python+model load time per synth.
///
/// Protocol:
///   Request:  <4-byte big-endian length><UTF-8 text>
///   Response: <4-byte big-endian length><WAV bytes>  (length 0 = filter dropped text)
///
/// Setup (user runs once):
///   /opt/homebrew/bin/python3 -m venv ~/Library/Application\ Support/Quip/venv
///   ~/Library/Application\ Support/Quip/venv/bin/pip install kokoro-onnx soundfile numpy
///   mkdir -p ~/Library/Application\ Support/Quip/kokoro
///   cd ~/Library/Application\ Support/Quip/kokoro
///   curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
///   curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
final class KokoroTTS: @unchecked Sendable {

    /// Serialized queue — only one synth at a time goes through the daemon
    private let queue = DispatchQueue(label: "quip.kokoro-tts", qos: .userInitiated)

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?

    private var venvPython: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Quip/venv/bin/python3")
    }

    private var scriptPath: String? {
        Bundle.main.path(forResource: "kokoro_tts", ofType: "py")
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: venvPython) && scriptPath != nil
    }

    /// Ensure the daemon process is running. Must be called on `queue`.
    private func ensureDaemonRunning() -> Bool {
        if let p = process, p.isRunning { return true }

        guard let script = scriptPath else {
            KokoroTTSDebug.log("daemon: no bundled script")
            return false
        }
        guard FileManager.default.fileExists(atPath: venvPython) else {
            KokoroTTSDebug.log("daemon: no venv at \(venvPython)")
            return false
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: venvPython)
        p.arguments = [script, "--daemon", "--voice", "af_heart"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        // Drain stderr in background so it doesn't block the pipe
        stderrPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                KokoroTTSDebug.log("daemon stderr: \(s.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        do {
            try p.run()
        } catch {
            KokoroTTSDebug.log("daemon: failed to launch: \(error.localizedDescription)")
            return false
        }

        self.process = p
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        KokoroTTSDebug.log("daemon: launched pid=\(p.processIdentifier)")
        return true
    }

    /// Streaming synthesis. The daemon returns one WAV chunk per sentence; `onChunk` is
    /// called for each chunk as it arrives, and `onComplete` fires when the stream ends.
    /// `shouldProceed` is checked just before running — return false to skip stale requests.
    func synthesize(_ text: String, voice: String = "af_heart",
                    shouldProceed: @escaping () -> Bool = { true },
                    onChunk: @escaping (Data) -> Void,
                    onComplete: @escaping () -> Void) {
        queue.async { [self] in
            guard shouldProceed() else {
                KokoroTTSDebug.log("synth skipped — shouldProceed returned false")
                onComplete()
                return
            }
            guard ensureDaemonRunning(),
                  let stdin = self.stdinHandle,
                  let stdout = self.stdoutHandle else {
                onComplete()
                return
            }

            guard let textData = text.data(using: .utf8) else {
                onComplete()
                return
            }

            // Write length-prefixed request
            var lenBE = UInt32(textData.count).bigEndian
            let lenData = Data(bytes: &lenBE, count: 4)
            do {
                try stdin.write(contentsOf: lenData)
                try stdin.write(contentsOf: textData)
            } catch {
                KokoroTTSDebug.log("daemon: stdin write failed: \(error.localizedDescription) — restarting")
                self.process?.terminate()
                self.process = nil
                onComplete()
                return
            }

            // Read chunks until we get a 0-length marker (end of stream)
            var chunkCount = 0
            while true {
                let hdr = stdout.readData(ofLength: 4)
                guard hdr.count == 4 else {
                    KokoroTTSDebug.log("daemon: short header read (\(hdr.count)) — restarting")
                    self.process?.terminate()
                    self.process = nil
                    onComplete()
                    return
                }
                let chunkLen = Int(
                    UInt32(hdr[0]) << 24 | UInt32(hdr[1]) << 16 | UInt32(hdr[2]) << 8 | UInt32(hdr[3])
                )
                if chunkLen == 0 {
                    // End of stream
                    KokoroTTSDebug.log("daemon: stream complete, \(chunkCount) chunks")
                    onComplete()
                    return
                }

                var wav = Data()
                wav.reserveCapacity(chunkLen)
                while wav.count < chunkLen {
                    let piece = stdout.readData(ofLength: chunkLen - wav.count)
                    if piece.isEmpty {
                        KokoroTTSDebug.log("daemon: premature EOF in chunk body (\(wav.count)/\(chunkLen)) — restarting")
                        self.process?.terminate()
                        self.process = nil
                        onComplete()
                        return
                    }
                    wav.append(piece)
                }

                chunkCount += 1
                KokoroTTSDebug.log("daemon: chunk \(chunkCount), \(wav.count) bytes")
                // Skip the onChunk callback once this session has gone stale —
                // we still read the bytes to keep the daemon's pipe protocol in
                // sync, but we avoid the wasted base64 + JSON + broadcast work
                // (and the transient memory pressure from each 300–700 KB frame).
                if shouldProceed() {
                    onChunk(wav)
                } else {
                    KokoroTTSDebug.log("daemon: chunk \(chunkCount) discarded — stale gen")
                }
            }
        }
    }

    /// Pre-warm the daemon (load model) so first real synth is fast
    func preload() {
        queue.async { [self] in
            _ = ensureDaemonRunning()
        }
    }
}
