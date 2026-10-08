import XCTest
@testable import Quip

/// The SpeechAnalyzer readiness diagnostic (2026-10-07). The simulator
/// reports `SpeechTranscriber.isAvailable == false`, so it never reaches the
/// asset and format checks: only the pure parts are tested here, and the
/// device's answer is read from phone.log.
final class AnalyzerDiagnosticsTests: XCTestCase {

    func test_eachStopMapsToItsReadiness() {
        XCTAssertEqual(AnalyzerProbeStop.unsupported.readiness, .unsupported)
        XCTAssertEqual(AnalyzerProbeStop.assetNotInstalled.readiness, .needsDownload)
        XCTAssertEqual(AnalyzerProbeStop.formatMissing.readiness, .needsDownload,
                       "a nil format with the asset installed means assets to install, not an unsupported device")
        XCTAssertEqual(AnalyzerProbeStop.ready.readiness, .ready)
    }

    func test_aMissingFormatStillUsesTheLegacyEngine() {
        XCTAssertEqual(SpeechEnginePolicy.choose(osSupportsAnalyzer: true,
                                                 readiness: AnalyzerProbeStop.formatMissing.readiness,
                                                 legacyForced: false), .legacy,
                       "engine selection is unchanged: anything short of ready is legacy")
    }

    func test_unsupportedLine() {
        let line = AnalyzerDiagnostics.unsupportedLine(
            simulator: true, os: "Version 27.0 (Build 24A1)", deviceLocale: "en_US",
            isAvailable: false, speechSupported: 0, speechInstalled: 0, dictationSupported: 12)
        XCTAssertEqual(line, #"analyzer unsupported: sim=1 os="Version 27.0 (Build 24A1)" device_locale=en_US "#
                       + "isAvailable=false speech_supported=0 speech_installed=0 dictation_supported=12")
    }

    func test_assetLine() {
        XCTAssertEqual(AnalyzerDiagnostics.assetLine(status: "supported", locale: "en_US"),
                       "analyzer asset status=supported locale=en_US")
    }

    func test_formatMissingLine() {
        XCTAssertEqual(AnalyzerDiagnostics.formatMissingLine(locale: "en_US", simulator: false,
                                                             os: "Version 27.0.1 (Build 24A2)"),
                       #"analyzer format=nil with status=installed locale=en_US sim=0 os="Version 27.0.1 (Build 24A2)""#)
    }

    func test_theTestHostKnowsItIsASimulator() {
        XCTAssertTrue(AnalyzerDiagnostics.isSimulator)
    }
}
