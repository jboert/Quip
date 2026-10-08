import AVFoundation
import Speech

/// Which check `AnalyzerAssets.readiness(for:)` stopped at, and the readiness
/// that follows from it. Every launch used to log only
/// `analyzer readiness=unsupported locale=none`, which could not say which
/// check failed. Pure, so it is unit-tested without the Speech framework:
/// the simulator reports `SpeechTranscriber.isAvailable == false` and never
/// reaches the later checks.
enum AnalyzerProbeStop: Equatable {
    /// `SpeechTranscriber.isAvailable` is false, or no supported locale is
    /// equivalent to the device's. Apple documents both as device capability
    /// (supportedLocales is empty on a device without the transcriber).
    case unsupported
    /// The model asset for the resolved locale is not installed.
    case assetNotInstalled
    /// The asset reports installed but `bestAvailableAudioFormat` returned
    /// nil, which Apple documents as happening "if the specified modules
    /// require you to install additional assets". That is a download to do,
    /// not an unsupported device; it used to be reported as unsupported, so
    /// the install was never attempted.
    case formatMissing
    case ready

    var readiness: AnalyzerReadiness {
        switch self {
        case .unsupported: return .unsupported
        case .assetNotInstalled, .formatMissing: return .needsDownload
        case .ready: return .ready
        }
    }
}

/// The phone-log lines for `AnalyzerAssets.readiness(for:)`. No transcript
/// text, only device and model facts. Pure / unit-testable.
enum AnalyzerDiagnostics {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// `ProcessInfo.operatingSystemVersionString` holds spaces ("Version
    /// 27.0.1 (Build …)"), so it is quoted to keep the line's fields apart.
    static func unsupportedLine(simulator: Bool, os: String, deviceLocale: String, isAvailable: Bool,
                                speechSupported: Int, speechInstalled: Int, dictationSupported: Int) -> String {
        "analyzer unsupported: sim=\(simulator ? 1 : 0) os=\"\(os)\" device_locale=\(deviceLocale) "
            + "isAvailable=\(isAvailable) speech_supported=\(speechSupported) "
            + "speech_installed=\(speechInstalled) dictation_supported=\(dictationSupported)"
    }

    static func assetLine(status: String, locale: String) -> String {
        "analyzer asset status=\(status) locale=\(locale)"
    }

    static func formatMissingLine(locale: String, simulator: Bool, os: String) -> String {
        "analyzer format=nil with status=installed locale=\(locale) sim=\(simulator ? 1 : 0) os=\"\(os)\""
    }
}

@available(iOS 26, *)
enum AnalyzerAssets {
    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    /// Every PTT press re-probes while the analyzer is not ready, so each
    /// diagnostic line is latched: the unsupported facts once per launch (its
    /// counts are only gathered then), the other two once per distinct line.
    private static let unsupportedLatch = LogLatch()
    private static let assetLatch = LogLatch()
    private static let formatLatch = LogLatch()

    /// Readiness plus, when ready, the resolved locale and the audio format
    /// the analyzer wants. The format is fetched once here so a PTT press can
    /// build its session synchronously. The checks run one at a time, and
    /// the one that stops the probe says so in the phone log.
    static func readiness(for locale: Locale) async -> (AnalyzerReadiness, Locale?, AVAudioFormat?) {
        let available = SpeechTranscriber.isAvailable
        let resolved = available ? await SpeechTranscriber.supportedLocale(equivalentTo: locale) : nil
        guard let resolved else {
            if unsupportedLatch.verdict(for: "unsupported").shouldLog {
                let speechSupported = await SpeechTranscriber.supportedLocales.count
                let speechInstalled = await SpeechTranscriber.installedLocales.count
                let dictationSupported = await DictationTranscriber.supportedLocales.count
                PhoneLog.log(AnalyzerDiagnostics.unsupportedLine(
                    simulator: AnalyzerDiagnostics.isSimulator,
                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                    deviceLocale: locale.identifier, isAvailable: available,
                    speechSupported: speechSupported, speechInstalled: speechInstalled,
                    dictationSupported: dictationSupported))
            }
            return (AnalyzerProbeStop.unsupported.readiness, nil, nil)
        }
        let module = transcriber(resolved)
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else {
            let line = AnalyzerDiagnostics.assetLine(status: String(describing: status),
                                                     locale: resolved.identifier)
            if assetLatch.verdict(for: line).shouldLog { PhoneLog.log(line) }
            return (AnalyzerProbeStop.assetNotInstalled.readiness, resolved, nil)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            let line = AnalyzerDiagnostics.formatMissingLine(
                locale: resolved.identifier, simulator: AnalyzerDiagnostics.isSimulator,
                os: ProcessInfo.processInfo.operatingSystemVersionString)
            if formatLatch.verdict(for: line).shouldLog { PhoneLog.log(line) }
            return (AnalyzerProbeStop.formatMissing.readiness, resolved, nil)
        }
        return (AnalyzerProbeStop.ready.readiness, resolved, format)
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
            PhoneLog.log("analyzer model download failed: \(error)")
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
                PhoneLog.log("analyzer results ended with error: \(error)")
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
                PhoneLog.log("analyzer start failed: \(error)")
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
