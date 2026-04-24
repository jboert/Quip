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
