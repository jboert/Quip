import XCTest
@testable import Quip

final class PromptVariablesTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    // 2027-01-15 23:30 UTC — still the 15th in UTC, already the 16th in Tokyo.
    private let now = Date(timeIntervalSince1970: 1_800_055_800)

    private func values(_ body: String, folder: String = "Quip", cwd: String? = "/Users/x/Quip",
                        tz: TimeZone? = nil, clipboard: @escaping () -> String? = { "clip" }) -> [String: String] {
        PromptVariables.values(for: body, folder: folder, windowName: "zsh — Quip", agent: "claude",
                               cwd: cwd, now: now, timeZone: tz ?? utc, clipboard: clipboard)
    }

    func testFillsEverySupportedName() {
        let body = PromptVariables.supported.map { "{{\($0)}}" }.joined(separator: " ")
        XCTAssertEqual(values(body), [
            "folder": "Quip", "window": "zsh — Quip", "agent": "claude",
            "cwd": "/Users/x/Quip", "date": "2027-01-15", "clipboard": "clip",
        ])
    }

    func testDateUsesTheGivenTimeZone() {
        XCTAssertEqual(values("{{date}}", tz: TimeZone(identifier: "Asia/Tokyo")!)["date"], "2027-01-16")
    }

    // The pasteboard is private; a prompt that does not ask for it must not read it.
    func testClipboardIsReadOnlyWhenTheBodyAsksForIt() {
        var reads = 0
        _ = values("Review {{folder}}", clipboard: { reads += 1; return "secret" })
        XCTAssertEqual(reads, 0)
        _ = values("Explain {{clipboard}} and {{CLIPBOARD}}", clipboard: { reads += 1; return "x" })
        XCTAssertEqual(reads, 1)
    }

    func testEmptyOrMissingValuesAreLeftOutSoThePlaceholderStays() {
        let v = values("{{folder}} {{cwd}} {{clipboard}} {{ticket}}", folder: "", cwd: nil, clipboard: { nil })
        XCTAssertEqual(v, [:])
        let r = PromptTemplate.expand("in {{folder}}", values: v)
        XCTAssertEqual(r.text, "in {{folder}}")
        XCTAssertEqual(r.unresolved, ["folder"])
    }

    func testEndToEndExpansion() {
        let body = "In {{folder}} ({{agent}}): fix {{clipboard}}"
        let r = PromptTemplate.expand(body, values: values(body, clipboard: { "TypeError at {{x}}" }))
        XCTAssertEqual(r.text, "In Quip (claude): fix TypeError at {{x}}")
        XCTAssertEqual(r.unresolved, [])
    }
}
