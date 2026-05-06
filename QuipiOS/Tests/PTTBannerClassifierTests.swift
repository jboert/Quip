import XCTest
@testable import Quip

/// Locks `MainiOSView.classifyPTTBanner(...)`'s mapping. The banner exists
/// to surface path-degraded PTT states that were previously NSLog-only or
/// buried in Settings → Diagnostics. (GH H.)
final class PTTBannerClassifierTests: XCTestCase {

    func test_idle_connected_whisperReady_showsNoBanner() {
        XCTAssertNil(MainiOSView.classifyPTTBanner(isConnected: true,
                                                    isRecording: false,
                                                    whisperStatus: .ready),
                     "All systems healthy → no banner")
    }

    func test_recording_disconnected_showsMidPressBanner() {
        let info = MainiOSView.classifyPTTBanner(isConnected: false,
                                                  isRecording: true,
                                                  whisperStatus: .ready)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.icon, "wifi.exclamationmark")
        XCTAssertTrue(info?.message.contains("disconnected") == true)
    }

    func test_whisperFailed_showsOfflineBanner_withReason() {
        let info = MainiOSView.classifyPTTBanner(isConnected: true,
                                                  isRecording: false,
                                                  whisperStatus: .failed(message: "model load failed"))
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.icon, "waveform.slash")
        XCTAssertTrue(info?.message.contains("Whisper offline") == true)
        XCTAssertTrue(info?.message.contains("model load failed") == true,
                      "Reason from .failed payload must reach the banner so the user can self-diagnose")
    }

    func test_whisperFailed_takesPriority_overConnectedIdle() {
        // Even when isConnected=true and not recording, a Whisper failure
        // is the most actionable signal — surface it.
        let info = MainiOSView.classifyPTTBanner(isConnected: true,
                                                  isRecording: false,
                                                  whisperStatus: .failed(message: "x"))
        XCTAssertNotNil(info)
    }

    func test_recording_disconnected_outranks_whisperFailed() {
        // Both are red flags; mid-press disconnect is the loudest.
        let info = MainiOSView.classifyPTTBanner(isConnected: false,
                                                  isRecording: true,
                                                  whisperStatus: .failed(message: "x"))
        XCTAssertEqual(info?.icon, "wifi.exclamationmark",
                       "Mid-press disconnect must outrank whisperStatus.failed in priority")
    }

    func test_recording_preparing_showsWarmupBanner() {
        let info = MainiOSView.classifyPTTBanner(isConnected: true,
                                                  isRecording: true,
                                                  whisperStatus: .preparing)
        XCTAssertEqual(info?.icon, "hourglass")
        XCTAssertTrue(info?.message.contains("warming up") == true)
    }

    func test_recording_downloading_showsProgressBanner() {
        let info = MainiOSView.classifyPTTBanner(isConnected: true,
                                                  isRecording: true,
                                                  whisperStatus: .downloading(progress: 0.42))
        XCTAssertEqual(info?.icon, "arrow.down.circle")
        XCTAssertTrue(info?.message.contains("42%") == true,
                      "Progress percentage must reach the banner")
    }

    func test_idle_preparing_showsNoBanner() {
        // Routine startup chatter — only surface during a press.
        XCTAssertNil(MainiOSView.classifyPTTBanner(isConnected: true,
                                                    isRecording: false,
                                                    whisperStatus: .preparing))
    }

    func test_idle_downloading_showsNoBanner() {
        XCTAssertNil(MainiOSView.classifyPTTBanner(isConnected: true,
                                                    isRecording: false,
                                                    whisperStatus: .downloading(progress: 0.5)))
    }
}
