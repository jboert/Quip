import AVFoundation
import Speech

@available(iOS 26, *)
enum AnalyzerAssets {
    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// Readiness plus, when ready, the resolved locale and the audio format
    /// the analyzer wants. The format is fetched once here so a PTT press can
    /// build its session synchronously.
    static func readiness(for locale: Locale) async -> (AnalyzerReadiness, Locale?, AVAudioFormat?) {
        guard SpeechTranscriber.isAvailable,
              let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return (.unsupported, nil, nil)
        }
        let module = transcriber(resolved)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            return (.needsDownload, resolved, nil)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        return format == nil ? (.unsupported, nil, nil) : (.ready, resolved, format)
    }

    /// Downloads the model for `locale` if needed. Best-effort: a failure
    /// leaves readiness at `.needsDownload` and the legacy path keeps working.
    static func install(for locale: Locale) async {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(resolved)]) {
                try await request.downloadAndInstall()
            }
        } catch {
            print("[Quip][PTT] analyzer asset install failed: \(error)")
        }
    }
}

/// One PTT press on the SpeechAnalyzer engine. Buffers arrive from the
/// AudioWorker tap in the mic's native format and are converted to the
/// analyzer's format before being queued.
@available(iOS 26, *)
final class AnalyzerSession: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var transcript = AnalyzerTranscript()
    private var resultsTask: Task<Void, Never>?

    init(locale: Locale, format: AVAudioFormat, vocab: [String],
         onUpdate: @escaping @Sendable (String) -> Void) {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.format = format
        self.input = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    let display: String = self.lock.withLock {
                        self.transcript.apply(text, isFinal: result.isFinal)
                        return self.transcript.display
                    }
                    onUpdate(display)
                }
            } catch {
                print("[Quip][PTT] analyzer results ended with error: \(error)")
            }
        }
        let analyzer = self.analyzer
        Task {
            if !vocab.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocab
                try? await analyzer.setContext(context)
            }
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                print("[Quip][PTT] analyzer start failed: \(error)")
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Ends input, waits for every result to finalize, then reports the full
    /// transcript. The caller keeps its own hard cap in case this never returns.
    func finish(completion: @escaping @Sendable (String) -> Void) {
        input.finish()
        let analyzer = self.analyzer
        Task { [weak self] in
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await self?.resultsTask?.value
            guard let self else { return }
            completion(self.lock.withLock { self.transcript.display })
        }
    }

    func cancel() {
        input.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return (error == nil && out.frameLength > 0) ? out : nil
    }
}
