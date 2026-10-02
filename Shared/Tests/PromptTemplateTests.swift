import XCTest
@testable import Quip

final class PromptTemplateTests: XCTestCase {

    func testExpandsKnownVariables() {
        let r = PromptTemplate.expand("Review {{folder}} on {{agent}}", values: ["folder": "Quip", "agent": "claude"])
        XCTAssertEqual(r.text, "Review Quip on claude")
        XCTAssertEqual(r.unresolved, [])
    }

    func testUnknownVariableStaysLiteralAndIsReported() {
        let r = PromptTemplate.expand("Fix {{ticket}} in {{folder}} ({{ticket}})", values: ["folder": "Quip"])
        XCTAssertEqual(r.text, "Fix {{ticket}} in Quip ({{ticket}})")
        XCTAssertEqual(r.unresolved, ["ticket"])
    }

    func testNamesAreCaseInsensitiveAndAllowInnerSpaces() {
        let r = PromptTemplate.expand("{{ Folder }}/{{FOLDER}}", values: ["folder": "Quip"])
        XCTAssertEqual(r.text, "Quip/Quip")
    }

    // A clipboard holding a template must not be expanded a second time.
    func testExpansionIsSinglePass() {
        let r = PromptTemplate.expand("Paste: {{clipboard}}", values: ["clipboard": "{{folder}}", "folder": "X"])
        XCTAssertEqual(r.text, "Paste: {{folder}}")
    }

    func testMalformedBracesPassThrough() {
        let body = "func f() { return {x} } {{ }} {{1abc}} {{a b}} {single}"
        let r = PromptTemplate.expand(body, values: ["a": "A", "x": "X"])
        XCTAssertEqual(r.text, body)
        XCTAssertEqual(PromptTemplate.variables(in: body), [])
    }

    func testVariablesInOrderOfFirstAppearanceDeduplicated() {
        XCTAssertEqual(PromptTemplate.variables(in: "{{b}} {{A}} {{b}} {{a.c-d_e}}"), ["b", "a", "a.c-d_e"])
    }

    func testBodyWithoutVariablesIsUnchanged() {
        let body = "Plain prompt — émoji 🚀 and no braces"
        XCTAssertEqual(PromptTemplate.expand(body, values: ["folder": "Q"]).text, body)
    }

    func testValueWithRegexMetacharactersIsInsertedVerbatim() {
        let r = PromptTemplate.expand("{{clipboard}}", values: ["clipboard": #"$1 \0 ^.*$"#])
        XCTAssertEqual(r.text, #"$1 \0 ^.*$"#)
    }
}
