import XCTest
import Foundation
@testable import Quip

final class DiagnosticsBundleTests: XCTestCase {

    /// makeZip writes a non-empty zip to NSTemporaryDirectory, named
    /// `Quip-diagnostics-YYYYMMDD-HHMMSS.zip`. The zip contains at
    /// minimum the system-info.txt entry (logs may or may not exist
    /// depending on whether the app has run before this test).
    func test_makeZip_writesValidZipToTmp() throws {
        let url = try DiagnosticsBundle.makeZip()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "zip should exist at \(url.path)")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Quip-diagnostics-"),
                      "filename should be Quip-diagnostics-* (got \(url.lastPathComponent))")
        XCTAssertTrue(url.pathExtension == "zip", "extension should be .zip")

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100, "zip should be non-trivial")
        // Zip files start with "PK" (0x50 0x4B).
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "PK magic bytes")
    }

    /// systemInfoText() is pure — pin its contract here so refactors
    /// don't drop fields that recipients of the bundle depend on.
    func test_systemInfoText_includesExpectedFields() {
        let text = DiagnosticsBundle.systemInfoText()
        XCTAssertTrue(text.contains("Quip Diagnostics"))
        XCTAssertTrue(text.contains("App version:"))
        XCTAssertTrue(text.contains("macOS:"))
        XCTAssertTrue(text.contains("Architecture:"))
    }

    /// makeZip respects an absurdly small cap — should throw .overSizeCap
    /// rather than ship a partial zip.
    func test_makeZip_respectsSizeCap() {
        XCTAssertThrowsError(try DiagnosticsBundle.makeZip(maxBytes: 1)) { error in
            guard case DiagnosticsBundleError.overSizeCap = error else {
                return XCTFail("expected .overSizeCap, got \(error)")
            }
        }
    }
}
