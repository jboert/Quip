import UIKit
import XCTest
@testable import Quip

/// US-002: the prompt body editor saves exactly what was typed.
@MainActor
final class PlainTextEditorTests: XCTestCase {

    func test_configure_turnsOffEverythingThatRewritesTypedText() {
        let view = UITextView()

        PlainTextEditor.configure(view, font: .monospacedSystemFont(ofSize: 13, weight: .regular))

        XCTAssertEqual(view.smartQuotesType, .no, "echo 'x' must not become echo ‘x’")
        XCTAssertEqual(view.smartDashesType, .no, "-- must not become an en dash")
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.autocapitalizationType, .none)
        XCTAssertEqual(view.spellCheckingType, .no)
    }

    func test_configure_keepsTheEditorLook() {
        let view = UITextView()

        PlainTextEditor.configure(view, font: .monospacedSystemFont(ofSize: 13, weight: .regular))

        XCTAssertEqual(view.font?.pointSize, 13)
        XCTAssertEqual(view.backgroundColor, .clear)
        XCTAssertTrue(view.isScrollEnabled)
    }
}
