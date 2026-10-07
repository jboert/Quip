# Better Dictation Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make push-to-talk dictation accurate on both paths: Apple's SpeechAnalyzer on the iPhone when the Mac is not reachable, and Whisper large-v3 turbo on the Mac when it is.

**Architecture:** Dictation has two paths, chosen per press by `selectPTTPath` (`QuipiOS/Services/SpeechService.swift`). The *local* path runs `SFSpeechRecognizer` on the phone. It silently resets on pauses and drops the words before them, which is the "jumbled" symptom. The *remote* path streams PCM to the Mac, which runs WhisperKit `openai_whisper-small.en`. This plan swaps the engine behind each path and leaves the path selection, the audio engine lifecycle (arm/disarm, ring pre-roll) and the wire protocol unchanged.

- iPhone: a new `AnalyzerSession` wraps `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26). `AudioWorker` uses it in place of `SFSpeechAudioBufferRecognitionRequest` when it is ready. Otherwise (iOS < 26, locale unsupported, model not downloaded yet, or Labs escape hatch on) it uses the old code path, untouched.
- Mac: `setupWhisper` tries `openai_whisper-large-v3-v20240930_626MB` first and falls back to `openai_whisper-small.en`, which is already on disk, so a failed 626 MB download never leaves dictation dead. English is forced explicitly, because large-v3 is multilingual.

**Tech Stack:** Swift, Speech framework (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`, `AnalysisContext`), AVFoundation (`AVAudioConverter`), WhisperKit 0.18.0, XCTest.

**Spec:** Owner request, 2026-10-07 ("currently things get too jumbled and things get disconnected"). Options 1 + 2 of the in-session proposal, done together ("3"). No separate spec doc.

## Global Constraints

- iOS deployment target stays `17.0`. All new Speech API use is behind `@available(iOS 26, *)` / `#available(iOS 26, *)`.
- QuipiOS builds Swift 5 with `SWIFT_STRICT_CONCURRENCY: minimal`. QuipMac builds Swift 6 (the only reliable actor-isolation oracle is `xcodebuild`, not SourceKit).
- Never touch `arm()` / `disarm()` audio-session control flow except to cancel the new session alongside the old task. Every teardown path must leave no live recognizer, or iOS keeps the orange mic dot on.
- The new engine is on by default. Escape hatch: Labs flag `labs.legacySpeechRecognizer` ("Older iPhone speech recognizer"), off by default.
- Mac model files live under `~/Library/Application Support/Quip/` (never `~/Documents`, iCloud evicts it).
- Mac rebuild wipes TCC grants. Batch the Mac install with Q-34d.
- `Shared/` is not touched, so only the QuipiOS and QuipMac suites run.

## Review Focus

1. **First press after install, model not downloaded yet.** Expect the old recognizer for that press (never silence) while the asset downloads in the background. Pinned by `SpeechEnginePolicyTests.test_needsDownload_usesLegacy`.
2. **Non-English or unsupported locale.** Expect the old recognizer. Pinned by `test_unsupportedLocale_usesLegacy`.
3. **Release PTT within ~300 ms.** Expect the final text or nil delivered within `finishHardCap`, never a hang. The worker keeps its existing hard cap around the analyzer finish (Task 3, step 4).
4. **Disarm mid-session (app backgrounded).** Expect the analyzer cancelled and the mic dot cleared. Task 3 cancels it in `disarm()` and `stopForwarding()`. Hardware check in Task 5.
5. **Turbo download fails or Mac offline.** Expect the Mac to load `small.en` and report `ready`, not `failed`. Pinned by `WhisperModelLadderTests.test_ladderEndsOnTheModelAlreadyOnDisk`.

---

### Task 1: Pure transcript and engine-choice logic (iPhone)

**Files:**
- Create: `QuipiOS/Services/AnalyzerTranscript.swift`
- Test: `QuipiOS/Tests/AnalyzerTranscriptTests.swift`

**Interfaces:**
- Produces:
  - `struct AnalyzerTranscript { mutating func apply(_ text: String, isFinal: Bool); var display: String { get } }`
  - `enum AnalyzerReadiness: Equatable { case ready, needsDownload, unsupported }`
  - `enum SpeechEngine: Equatable { case analyzer, legacy }`
  - `enum SpeechEnginePolicy { static func choose(osSupportsAnalyzer: Bool, readiness: AnalyzerReadiness, legacyForced: Bool) -> SpeechEngine }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Quip

final class AnalyzerTranscriptTests: XCTestCase {
    func test_volatileIsReplacedNotAppended() {
        var t = AnalyzerTranscript()
        t.apply("hel", isFinal: false)
        t.apply("hello wor", isFinal: false)
        XCTAssertEqual(t.display, "hello wor")
    }

    func test_finalSegmentsAccumulateAcrossPauses() {
        var t = AnalyzerTranscript()
        t.apply("First sentence.", isFinal: true)
        t.apply("Second", isFinal: false)
        XCTAssertEqual(t.display, "First sentence. Second")
        t.apply(" Second sentence.", isFinal: true)
        XCTAssertEqual(t.display, "First sentence. Second sentence.")
    }

    func test_finalClearsVolatile() {
        var t = AnalyzerTranscript()
        t.apply("draft words", isFinal: false)
        t.apply("Final words.", isFinal: true)
        XCTAssertEqual(t.display, "Final words.")
    }

    func test_blankResultsAreIgnored() {
        var t = AnalyzerTranscript()
        t.apply("Kept.", isFinal: true)
        t.apply("   ", isFinal: true)
        t.apply("", isFinal: false)
        XCTAssertEqual(t.display, "Kept.")
    }
}

final class SpeechEnginePolicyTests: XCTestCase {
    func test_readyOnNewOS_usesAnalyzer() {
        XCTAssertEqual(SpeechEnginePolicy.choose(osSupportsAnalyzer: true, readiness: .ready, legacyForced: false), .analyzer)
    }
    func test_oldOS_usesLegacy() {
        XCTAssertEqual(SpeechEnginePolicy.choose(osSupportsAnalyzer: false, readiness: .ready, legacyForced: false), .legacy)
    }
    func test_needsDownload_usesLegacy() {
        XCTAssertEqual(SpeechEnginePolicy.choose(osSupportsAnalyzer: true, readiness: .needsDownload, legacyForced: false), .legacy)
    }
    func test_unsupportedLocale_usesLegacy() {
        XCTAssertEqual(SpeechEnginePolicy.choose(osSupportsAnalyzer: true, readiness: .unsupported, legacyForced: false), .legacy)
    }
    func test_labsEscapeHatch_wins() {
        XCTAssertEqual(SpeechEnginePolicy.choose(osSupportsAnalyzer: true, readiness: .ready, legacyForced: true), .legacy)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd QuipiOS && xcodegen generate --quiet && xcodebuild -project QuipiOS.xcodeproj -scheme QuipiOS -destination "id=9A204976-5E83-4909-B88C-7C06D3FD69B2" -only-testing:QuipiOSTests/AnalyzerTranscriptTests -only-testing:QuipiOSTests/SpeechEnginePolicyTests test`
Expected: build FAIL, "cannot find 'AnalyzerTranscript' in scope". Restore the pbxproj afterwards: `git checkout QuipiOS/QuipiOS.xcodeproj/project.pbxproj`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The running text of one SpeechAnalyzer session. Finalized results are
/// permanent and accumulate; the volatile result is the analyzer's current
/// guess for audio not yet finalized, and each new one replaces the last.
/// Unlike SFSpeech partials, nothing finalized is ever dropped on a pause.
struct AnalyzerTranscript {
    private var finalized: [String] = []
    private var volatile = ""

    mutating func apply(_ text: String, isFinal: Bool) {
        let piece = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            if !piece.isEmpty { finalized.append(piece) }
            volatile = ""
        } else if !piece.isEmpty {
            volatile = piece
        }
    }

    var display: String {
        (finalized + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ")
    }
}

/// Whether the on-device SpeechTranscriber model can run right now.
enum AnalyzerReadiness: Equatable {
    case ready
    /// Locale is supported but the model asset is not installed yet.
    case needsDownload
    case unsupported
}

enum SpeechEngine: Equatable { case analyzer, legacy }

/// Picks the local-path recognizer for one PTT press. Anything short of a
/// ready analyzer uses the legacy recognizer, so a press is never silent.
enum SpeechEnginePolicy {
    static func choose(osSupportsAnalyzer: Bool, readiness: AnalyzerReadiness,
                       legacyForced: Bool) -> SpeechEngine {
        guard osSupportsAnalyzer, !legacyForced, readiness == .ready else { return .legacy }
        return .analyzer
    }
}
```

- [ ] **Step 4: Run tests to verify they pass** (same command as step 2). Expected: 9 tests pass.

- [ ] **Step 5: Commit** — `feat(dictation): transcript accumulator and engine policy for SpeechAnalyzer`

### Task 2: `AnalyzerSession` and asset readiness (iPhone)

**Files:**
- Create: `QuipiOS/Services/AnalyzerSession.swift`

**Interfaces:**
- Consumes: `AnalyzerTranscript`, `AnalyzerReadiness` (Task 1).
- Produces:
  - `@available(iOS 26, *) enum AnalyzerAssets { static func readiness(for locale: Locale) async -> (AnalyzerReadiness, Locale?, AVAudioFormat?); static func install(for locale: Locale) async }`
  - `@available(iOS 26, *) final class AnalyzerSession { init(locale: Locale, format: AVAudioFormat, vocab: [String], onUpdate: @escaping @Sendable (String) -> Void); func append(_ buffer: AVAudioPCMBuffer); func finish(completion: @escaping @Sendable (String) -> Void); func cancel() }`

This needs the on-device model, so it is not unit-tested. It is covered by the compile gate and the hardware check in Task 5.

- [ ] **Step 1: Implement**

```swift
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
```

- [ ] **Step 2: Build for device** — `cd QuipiOS && xcodegen generate --quiet && xcodebuild -project QuipiOS.xcodeproj -scheme QuipiOS -destination generic/platform=iOS -derivedDataPath build build`. Expected: `BUILD SUCCEEDED`. If an API name differs from the iOS 27 SDK interface, fix it against `Speech.swiftmodule/arm64e-apple-ios.swiftinterface`. Restore the pbxproj.

- [ ] **Step 3: Commit** — `feat(dictation): AnalyzerSession wraps SpeechAnalyzer for the local PTT path`

### Task 3: Wire the analyzer into `AudioWorker` (iPhone)

**Files:**
- Modify: `QuipiOS/Services/SpeechService.swift` (`AudioWorker`, lines ~533-887; `SpeechService.arm()`)
- Modify: `QuipiOS/Services/LabsFlags.swift`

**Interfaces:**
- Consumes: `SpeechEnginePolicy.choose`, `AnalyzerAssets`, `AnalyzerSession` (Tasks 1-2).
- Produces: `LabsFlags.legacySpeechRecognizer = "labs.legacySpeechRecognizer"`.

- [ ] **Step 1: Labs escape hatch.** Add `static let legacySpeechRecognizer = "labs.legacySpeechRecognizer"` and a `visible` row: `(legacySpeechRecognizer, "Older iPhone speech recognizer", "Use the pre-iOS 26 recognizer when the Mac is not reachable. Turn on only if the new one misbehaves.")`.

- [ ] **Step 2: Readiness cache in `AudioWorker`.** Add `private var analyzerLocale: Locale?`, `private var analyzerFormat: AVAudioFormat?`, `private var analyzerReadiness: AnalyzerReadiness = .unsupported`, `private var analyzerSession: AnyObject?` and `private var readinessProbeStarted = false`. Add `func refreshAnalyzerReadiness()`: on iOS 26+, run a `Task` that awaits `AnalyzerAssets.readiness(for: Locale.current)` and stores the results on `queue`. If the result is `.needsDownload`, run `AnalyzerAssets.install` and probe again once it finishes. Call it from `arm()` once (`readinessProbeStarted` guard) and again whenever the readiness is not `.ready`.

- [ ] **Step 3: Feed buffers.** In every tap closure that does `self.recognitionRequest?.append(buffer)`, also call `self.appendToAnalyzer(buffer)`, where:

```swift
private func appendToAnalyzer(_ buffer: AVAudioPCMBuffer) {
    guard #available(iOS 26, *), let session = analyzerSession as? AnalyzerSession else { return }
    session.append(buffer)
}
```

- [ ] **Step 4: Local path.** In `start(onUpdate:)`, after the engine is up, choose the engine:

```swift
let legacyForced = UserDefaults.standard.bool(forKey: LabsFlags.legacySpeechRecognizer)
var engine = SpeechEngine.legacy
if #available(iOS 26, *) {
    engine = SpeechEnginePolicy.choose(osSupportsAnalyzer: true, readiness: analyzerReadiness, legacyForced: legacyForced)
}
NSLog("[Quip][PTT] local engine=%@", engine == .analyzer ? "analyzer" : "legacy")
if #available(iOS 26, *), engine == .analyzer, let locale = analyzerLocale, let format = analyzerFormat {
    let session = AnalyzerSession(locale: locale, format: format, vocab: cachedVocab) { [weak self] text in
        self?.queue.async { self?.onUpdateCallback?(text, false) }
    }
    analyzerSession = session
    for entry in ring.entries(relativeTo: Date()) { session.append(entry.buffer) }
    return
}
// existing SFSpeech code continues unchanged
```

Move the `recognizer.isAvailable` guard below this block, so a missing SFSpeech recognizer does not block the analyzer. In `stop()`, if `analyzerSession` is set: mark `isStopping`/`isFlushing`, wait `policy.trailingWindow`, then call `finish`. Its completion runs on `queue` and does `onUpdateCallback?(text.isEmpty ? nil : text, true)`, clears the session and sets `isFlushing = false`. Arm a `policy.finishHardCap` timer that, if the same session is still set, calls `cancel()` and delivers the last `display` (kept in `private var lastAnalyzerText`, updated in the onUpdate closure) as final. Return before the SFSpeech branch.

- [ ] **Step 5: Captions path.** In `beginCaptionTask`, use the same policy. If it chooses the analyzer, build an `AnalyzerSession` whose `onUpdate` calls `onCaption(text)`, replay the pre-roll, and return. No restart is needed: the analyzer has no one-minute ceiling.

- [ ] **Step 6: Teardown.** In `disarm()` and `stopForwarding()`, next to `recognitionTask?.cancel()`, add:

```swift
if #available(iOS 26, *), let session = analyzerSession as? AnalyzerSession { session.cancel() }
analyzerSession = nil
```

- [ ] **Step 7: Run the iOS suite** — `tools/check.sh`. Expected: all green, including the 9 Task 1 tests.

- [ ] **Step 8: Commit** — `feat(dictation): the phone dictates with SpeechAnalyzer when the Mac is away`

### Task 4: Whisper large-v3 turbo with a small.en fallback (Mac)

**Files:**
- Modify: `QuipMac/Services/WhisperDictationService.swift` (add `WhisperModelLadder`; set the language in the decode options)
- Modify: `QuipMac/QuipMacApp.swift:2430-2440` (`setupWhisper`)
- Test: `QuipMac/Tests/WhisperDictationServiceTests.swift`

**Interfaces:**
- Produces: `enum WhisperModelLadder { static let models: [String] }`

- [ ] **Step 1: Write the failing test**

```swift
func test_ladderPrefersTurboThenTheModelAlreadyOnDisk() {
    XCTAssertEqual(WhisperModelLadder.models.first, "openai_whisper-large-v3-v20240930_626MB")
}

func test_ladderEndsOnTheModelAlreadyOnDisk() {
    // small.en is what every existing install already downloaded, so a failed
    // turbo download still leaves dictation working.
    XCTAssertEqual(WhisperModelLadder.models.last, "openai_whisper-small.en")
}
```

- [ ] **Step 2: Run, expect a FAIL** (`cannot find 'WhisperModelLadder'`). Quit the live Quip app first; the test host binds 8765. Run: `tools/check.sh`.

- [ ] **Step 3: Implement.** In `WhisperDictationService.swift`:

```swift
/// Whisper models to try, best first. large-v3 turbo (v20240930, 626 MB
/// quantized) is far stronger on jargon than small.en. small.en is last
/// because it is already on disk for every existing install, so a failed or
/// offline turbo download still ends in a working model.
enum WhisperModelLadder {
    static let models = [
        "openai_whisper-large-v3-v20240930_626MB",
        "openai_whisper-small.en",
    ]
}
```

Change `DecodingOptions(promptTokens: prompt)` to `DecodingOptions(language: "en", detectLanguage: false, promptTokens: prompt)`, and the `nil` branch to `DecodingOptions(language: "en", detectLanguage: false)`. large-v3 is multilingual; without this, a short or noisy clip can be decoded as another language. In `setupWhisper`, replace the single `WhisperKitConfig` with a loop over `WhisperModelLadder.models` that `try await WhisperKit(WhisperKitConfig(model: name, downloadBase: modelBase))`, logs `appendWhisperDiagnostic("model=\(name) loaded")` or `model=\(name) failed error=…`, and keeps the first that loads. Throw the last error only if all fail.

- [ ] **Step 4: Run `tools/check.sh`.** Expected: Mac suite green.

- [ ] **Step 5: Commit** — `feat(whisper): the Mac transcribes with large-v3 turbo, small.en as fallback`

### Task 5: Install and hardware checks

- [ ] iOS: build for device and `devicectl device install app`. Force-quit and relaunch.
- [ ] Mac (batched with Q-34d): Release build, ditto into `/Applications`, delete stale builds, relaunch, verify a fresh pid. Watch `whisper` diagnostics for `model=openai_whisper-large-v3-v20240930_626MB loaded`. The first load downloads 626 MB and compiles CoreML, which can take several minutes. The phone uses its own engine until then.
- [ ] Phone, Mac unreachable (Wi-Fi off, Tailscale off): dictate two sentences with a 3-second pause. Expect both sentences, in order. Console shows `local engine=analyzer`. After release the orange mic dot clears.
- [ ] Phone, Mac reachable: dictate jargon ("Codex, Claude, WebSocket, xcodegen"). Expect a clean transcript from Whisper turbo.
- [ ] Labs → "Older iPhone speech recognizer" on: local dictation logs `engine=legacy`.
- [ ] Update `docs/superpowers/board.md` and `wishlist.md`.
