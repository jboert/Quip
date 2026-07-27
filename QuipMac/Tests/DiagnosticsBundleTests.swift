import XCTest
import Foundation
@testable import Quip

final class DiagnosticsBundleTests: XCTestCase {

    /// Small fixture logs, NOT the real LogPaths: on a dev machine the live
    /// logs are months of appends, and zipping them made each makeZip test
    /// take 5+ minutes (312s observed). The zip pipeline (redact → stage →
    /// zip → cap) is identical either way; only the input bytes shrink.
    private func fixtureSources() throws -> [String] {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("diag-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try ["ws.log", "push.log"].map { name in
            let f = dir.appendingPathComponent(name)
            try String(repeating: "2026-07-27 quip log line 192.168.1.20\n", count: 200)
                .write(to: f, atomically: true, encoding: .utf8)
            return f.path
        }
    }

    /// makeZip writes a non-empty zip to NSTemporaryDirectory, named
    /// `Quip-diagnostics-YYYYMMDD-HHMMSS.zip`. The zip contains at
    /// minimum the system-info.txt entry (logs may or may not exist
    /// depending on whether the app has run before this test).
    func test_makeZip_writesValidZipToTmp() throws {
        let url = try DiagnosticsBundle.makeZip(sources: fixtureSources())
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

    /// systemInfoText() must NOT ship the raw machine name — that lives
    /// behind a stable hash so two bundles from the same host can be
    /// correlated without disclosing the host.
    func test_systemInfoText_redactsHostName() {
        let text = DiagnosticsBundle.systemInfoText()
        let actualHost = Host.current().localizedName ?? ""
        if actualHost.count >= 3 {
            XCTAssertFalse(text.contains(actualHost),
                           "system-info.txt must not contain raw host name '\(actualHost)'")
        }
        XCTAssertTrue(text.contains("Host:        <redacted> (id="),
                      "Host line must use the redacted-with-id format")
    }

    /// stableHostHash must be deterministic per-input + handle empty input.
    func test_stableHostHash_deterministic() {
        XCTAssertEqual(DiagnosticsBundle.stableHostHash("erick-mbp"),
                       DiagnosticsBundle.stableHostHash("erick-mbp"))
        XCTAssertNotEqual(DiagnosticsBundle.stableHostHash("erick-mbp"),
                          DiagnosticsBundle.stableHostHash("other-mac"))
        XCTAssertEqual(DiagnosticsBundle.stableHostHash(""), "anon")
    }

    /// makeZip respects an absurdly small cap — should throw .overSizeCap
    /// rather than ship a partial zip.
    func test_makeZip_respectsSizeCap() throws {
        let sources = try fixtureSources()
        XCTAssertThrowsError(try DiagnosticsBundle.makeZip(maxBytes: 1, sources: sources)) { error in
            guard case DiagnosticsBundleError.overSizeCap = error else {
                return XCTFail("expected .overSizeCap, got \(error)")
            }
        }
    }
}
