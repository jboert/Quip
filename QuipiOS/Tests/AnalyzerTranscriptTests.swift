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
