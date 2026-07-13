import XCTest
@testable import Quip

/// Swallowed-error sweep (QuipiOS). Locks the loud-drop contract on the
/// persisted-state stores, which previously used `try?` and turned any
/// schema drift / corruption into a SILENT reset:
///
/// - a corrupt-but-non-empty blob used to decode to `[]`, so the user's
///   saved quick-button row / custom buttons just vanished and were
///   replaced by defaults with nothing in the log to say why;
/// - an encode failure used to persist `"[]"` over live data — a
///   destructive wipe, also silent.
///
/// The fix keeps the fallback values (callers assign straight into
/// @AppStorage and cannot tolerate a throw) but makes every drop audible.
/// These asserts pin BOTH halves: the fresh-install path must stay quiet,
/// and the corruption path must log.
final class PersistenceLoudDropTests: XCTestCase {

    // MARK: - QuickSlotStore

    func testQuickSlotDecodeEmptyIsFreshInstallAndStaysQuiet() {
        var logs: [String] = []
        let out = QuickSlotStore.decode("") { logs.append($0) }
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(logs.isEmpty, "Fresh install is not an error — must not log. Got \(logs)")
    }

    /// A fresh latch per case: the production latch is a shared static, and a
    /// test that leaned on it would depend on execution order. Cadence itself is
    /// pinned in `LogLatchCadenceTests`.
    func testQuickSlotDecodeCorruptBlobLogsLoudly() {
        var logs: [String] = []
        let out = QuickSlotStore.decode("{ this is not json", log: { logs.append($0) }, latch: LogLatch())
        XCTAssertTrue(out.isEmpty, "Fallback value is preserved")
        XCTAssertEqual(logs.count, 1, "Corrupt non-empty blob must emit exactly one line")
        XCTAssertTrue(logs[0].contains("quickSlots decode FAILED"),
                      "Log must carry a greppable token. Got: \(logs[0])")
    }

    func testQuickSlotDecodeValidBlobRoundTripsWithoutLogging() {
        let slots = QuickSlotStore.defaultSlots(demoCustomID: CustomButtonStore.defaultDemo().id)
        var encodeLogs: [String] = []
        let json = QuickSlotStore.encode(slots) { encodeLogs.append($0) }
        XCTAssertTrue(encodeLogs.isEmpty, "Encoding a valid row must not log. Got \(encodeLogs)")

        var decodeLogs: [String] = []
        let out = QuickSlotStore.decode(json) { decodeLogs.append($0) }
        XCTAssertEqual(out.count, slots.count)
        XCTAssertTrue(decodeLogs.isEmpty, "Round-trip must not log. Got \(decodeLogs)")
    }

    // MARK: - CustomButtonStore

    func testCustomButtonDecodeEmptyIsFreshInstallAndStaysQuiet() {
        var logs: [String] = []
        let out = CustomButtonStore.decode("") { logs.append($0) }
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(logs.isEmpty, "Fresh install must not log. Got \(logs)")
    }

    func testCustomButtonDecodeCorruptBlobLogsLoudly() {
        var logs: [String] = []
        let out = CustomButtonStore.decode(#"[{"label":"oops"}]"#, log: { logs.append($0) }, latch: LogLatch())
        XCTAssertTrue(out.isEmpty, "Fallback value is preserved")
        XCTAssertEqual(logs.count, 1, "Schema drift must emit exactly one line")
        XCTAssertTrue(logs[0].contains("customButtons decode FAILED"),
                      "Log must carry a greppable token. Got: \(logs[0])")
    }

    func testCustomButtonRoundTripDoesNotLog() {
        let buttons = [CustomButtonStore.defaultDemo()]
        var encodeLogs: [String] = []
        let json = CustomButtonStore.encode(buttons) { encodeLogs.append($0) }
        XCTAssertTrue(encodeLogs.isEmpty, "Encoding valid buttons must not log. Got \(encodeLogs)")

        var decodeLogs: [String] = []
        let out = CustomButtonStore.decode(json) { decodeLogs.append($0) }
        XCTAssertEqual(out.map(\.id), buttons.map(\.id))
        XCTAssertTrue(decodeLogs.isEmpty, "Round-trip must not log. Got \(decodeLogs)")
    }

    // MARK: - DictationVocab

    /// `loadBundled()` already reported a MISSING file. The swallow was the
    /// other branch: a file that exists but can't be read left dictation
    /// running with an empty vocabulary, mis-transcribing every custom term
    /// with zero evidence.
    func testDictationVocabUnreadableFileLogsLoudly() {
        let missing = URL(fileURLWithPath: "/nonexistent/quip-vocab-\(UUID().uuidString).txt")
        var logs: [String] = []
        let terms = DictationVocab.load(from: missing) { logs.append($0) }
        XCTAssertTrue(terms.isEmpty, "Fallback value is preserved")
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("dictation vocab UNREADABLE"),
                      "Log must carry a greppable token. Got: \(logs[0])")
    }

    func testDictationVocabReadableFileParsesWithoutLogging() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quip-vocab-\(UUID().uuidString).txt")
        try "Codex\n  Opus  \n\nSonnet\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        var logs: [String] = []
        let terms = DictationVocab.load(from: url) { logs.append($0) }
        XCTAssertEqual(terms, ["Codex", "Opus", "Sonnet"],
                       "Blank lines dropped and terms trimmed")
        XCTAssertTrue(logs.isEmpty, "Happy path must not log. Got \(logs)")
    }
}
