// InputLineSendTests.swift
// Shared tests — send semantics while the Mac's input line already holds text

import XCTest
@testable import Quip

final class InputLineSendTests: XCTestCase {

    // MARK: - plan

    func testEmptyFieldWithNoEchoHasNothingToSend() {
        XCTAssertNil(InputLineSend.plan(fieldText: "   ", lineEcho: nil))
    }

    func testOrdinaryTextIsTypedAndSubmitted() {
        XCTAssertEqual(InputLineSend.plan(fieldText: "  git status  ", lineEcho: nil),
                       .typeAndReturn("git status"))
    }

    /// The reported shape: the phone accepted a suggestion, so the Mac already
    /// has that text on its line. Sending it again would produce
    /// `git statusgit status`.
    func testAnUntouchedEchoSubmitsInsteadOfTyping() {
        XCTAssertEqual(InputLineSend.plan(fieldText: "git status", lineEcho: "git status"),
                       .returnOnly)
    }

    /// Edited text is the user's own draft again — but the Mac's line is wiped
    /// at edit time (`shouldClearMacLine`), so by the time this fires the whole
    /// line is what gets typed.
    func testAnEditedEchoIsTypedNormally() {
        XCTAssertEqual(InputLineSend.plan(fieldText: "git status --short", lineEcho: "git status"),
                       .typeAndReturn("git status --short"))
    }

    /// A trailing space is an edit. The echo is a verbatim copy of the Mac's
    /// line; anything else is not that line.
    func testATrailingSpaceCountsAsAnEdit() {
        XCTAssertEqual(InputLineSend.plan(fieldText: "git status ", lineEcho: "git status"),
                       .typeAndReturn("git status"))
    }

    func testAnEmptiedEchoHasNothingToSend() {
        XCTAssertNil(InputLineSend.plan(fieldText: "", lineEcho: "git status"))
    }

    // MARK: - shouldClearMacLine

    func testNoEchoMeansNothingToClear() {
        XCTAssertFalse(InputLineSend.shouldClearMacLine(fieldText: "anything", lineEcho: nil))
    }

    func testAnUntouchedEchoDoesNotClearTheLine() {
        XCTAssertFalse(InputLineSend.shouldClearMacLine(fieldText: "git status",
                                                        lineEcho: "git status"))
    }

    func testEditingTheEchoClearsTheMacLine() {
        XCTAssertTrue(InputLineSend.shouldClearMacLine(fieldText: "git statu",
                                                       lineEcho: "git status"))
    }

    /// Deleting every character still has to wipe the Mac: the line the user
    /// just cleared on the phone is still typed over there.
    func testEmptyingTheFieldClearsTheMacLine() {
        XCTAssertTrue(InputLineSend.shouldClearMacLine(fieldText: "", lineEcho: "git status"))
    }
}
