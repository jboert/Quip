import XCTest
import UIKit
@testable import Quip

/// Q-50: every keyboard-row button gets an icon and a color from what it
/// says and does. Purple stays for prompts only, a color or symbol the user
/// picked always wins, and the switch off gives the plain row from before.
final class KeyStyleTests: XCTestCase {

    // MARK: US-201 built-in styles

    func test_builtinsMatchTheTable() {
        let expected: [QuickButton: (String, KeyHue, Bool)] = [
            .slash: ("slash.circle", .gray, false),
            .plan: ("list.bullet.clipboard", .blue, true),
            .btw: ("text.bubble", .indigo, true),
            .compact: ("arrow.down.right.and.arrow.up.left", .orange, true),
            .clearContext: ("eraser", .red, true),
            .prd: ("doc.richtext", .blue, true),
            .commitPushPr: ("paperplane.fill", .green, true),
            .caveman: ("flame.fill", .orange, true),
            .ultraReview: ("sparkle.magnifyingglass", .teal, true),
            .brainstorm: ("lightbulb", .orange, true),
            .writePlan: ("square.and.pencil", .blue, true),
            .executePlan: ("play.fill", .green, true),
            .resume: ("clock.arrow.circlepath", .indigo, true),
            .model: ("cpu", .indigo, true),
            .context: ("gauge.with.dots.needle.33percent", .teal, true),
            .yes: ("checkmark", .green, false),
            .no: ("xmark", .red, false),
            .one: ("1.circle", .blue, false),
            .two: ("2.circle", .blue, false),
            .three: ("3.circle", .blue, false),
            .esc: ("escape", .orange, false),
            .ctrlC: ("xmark.octagon", .red, false),
            .ctrlD: ("eject", .red, false),
            .tab: ("arrow.right.to.line", .gray, false),
            .backspace: ("delete.left", .gray, false),
            .clearInput: ("delete.left.fill", .gray, false),
            .shiftTab: ("arrow.left.to.line", .indigo, false),
            .acceptAutocomplete: ("text.append", .teal, false),
            .broadcast: ("dot.radiowaves.left.and.right", .blue, false),
        ]
        XCTAssertEqual(Set(expected.keys), Set(QuickButton.allCases), "a new built-in needs a row in the table")
        for (button, (symbol, hue, showsLabel)) in expected {
            XCTAssertEqual(KeyStyles.builtin(button), KeyStyle(symbol: symbol, hue: hue, showsLabel: showsLabel),
                           button.rawValue)
        }
    }

    func test_onlyPromptsArePurple() {
        for button in QuickButton.allCases {
            XCTAssertNotEqual(KeyStyles.builtin(button).hue, .purple, button.rawValue)
        }
        for entry in KeyStyles.table {
            XCTAssertNotEqual(entry.hue, .purple, entry.keywords.joined(separator: ","))
        }
    }

    func test_answersAndKeystrokesAreIconOnly() {
        for button in QuickButton.allCases where button.category == .answer || button.category == .keystroke {
            XCTAssertFalse(KeyStyles.builtin(button).showsLabel, button.rawValue)
        }
    }

    func test_whiteTextReadsOnEveryFill() {
        for hue in KeyHue.allCases where hue != .purple {
            for hex in [hue.lightHex, hue.darkHex] {
                guard let hex else { return XCTFail("\(hue) has no fill") }
                XCTAssertFalse(KeyColors.prefersDarkText(on: hex), "\(hue) \(hex)")
                XCTAssertGreaterThanOrEqual(contrastAgainstWhite(hex), 4.5, "\(hue) \(hex)")
            }
        }
        XCTAssertNil(KeyHue.purple.lightHex, "prompt pills keep their own fill")
    }

    func test_everySymbolExistsOnThisIOS() {
        var symbols = Set(QuickButton.allCases.map { KeyStyles.builtin($0).symbol })
        symbols.formUnion(KeyStyles.table.map(\.symbol))
        symbols.formUnion(["slash.circle", "text.cursor", "keyboard", "return", "doc.text",
                           KeyStyles.promptsPicker.symbol, KeyStyles.slashGroup.symbol])
        for symbol in symbols {
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
        }
    }

    // MARK: US-202 styles from words

    func test_labelWordsPickTheStyle() {
        assertCustom("Deploy", .rawText(text: "x", autoSubmit: true), "paperplane.fill", .green)
        assertCustom("Deploying now", .rawText(text: "x", autoSubmit: true), "paperplane.fill", .green)
        assertCustom("Code review", .rawText(text: "x", autoSubmit: true), "magnifyingglass", .teal)
        assertCustom("Cleanup", .rawText(text: "x", autoSubmit: true), "wand.and.stars", .pink)
        assertCustom("Café design", .rawText(text: "x", autoSubmit: true), "paintbrush", .pink)
    }

    func test_payloadWordsWhenTheLabelSaysNothing() {
        assertCustom("Thing", .rawText(text: "make deploy", autoSubmit: true), "hammer", .orange)
        assertCustom("Thing", .slash(text: "/zzz", autoSubmit: false), "slash.circle", .gray)
        assertCustom("Thing", .rawText(text: "hello", autoSubmit: false), "text.cursor", .gray)
    }

    func test_customSlashAndTextShowTheirLabel() {
        XCTAssertTrue(KeyStyles.custom(label: "Deploy", payload: .slash(text: "/deploy", autoSubmit: true)).showsLabel)
        XCTAssertTrue(KeyStyles.custom(label: "Thing", payload: .rawText(text: "x", autoSubmit: true)).showsLabel)
    }

    func test_keystrokesLookLikeTheBuiltInWithTheSameKey() {
        XCTAssertEqual(KeyStyles.custom(label: "Thing", payload: .keystroke(action: "press_escape")),
                       KeyStyles.builtin(.esc))
        XCTAssertEqual(KeyStyles.custom(label: "Thing", payload: .keystroke(action: "press_2")),
                       KeyStyles.builtin(.two))
        XCTAssertEqual(KeyStyles.custom(label: "Thing", payload: .keystroke(action: "press_unknown")),
                       KeyStyle(symbol: "keyboard", hue: .gray, showsLabel: false))
        XCTAssertEqual(KeyStyles.custom(label: "Stop it", payload: .keystroke(action: "press_unknown")),
                       KeyStyle(symbol: "stop.fill", hue: .red, showsLabel: false))
    }

    func test_anEditedCopyOfABuiltInKeepsItsLook() {
        // Edit… on a built-in opens it as a custom copy (Q-67); saving it
        // unchanged must not turn the blue ② into a gray text pill.
        for button in QuickButton.allCases {
            guard let copy = QuickButtonEdit.customCopy(of: button) else { continue }
            XCTAssertEqual(KeyStyles.custom(label: copy.label, payload: copy.payload), KeyStyles.builtin(button),
                           button.rawValue)
        }
        XCTAssertEqual(KeyStyles.custom(label: "Renamed", payload: .slash(text: "/plan ", autoSubmit: false)),
                       KeyStyles.builtin(.plan))
    }

    func test_promptsStayPurpleAndTakeOnlyTheirIcon() {
        XCTAssertEqual(KeyStyles.prompt(label: "Ship it"), KeyStyle(symbol: "paperplane.fill", hue: .purple, showsLabel: true))
        XCTAssertEqual(KeyStyles.prompt(label: "Morning thing"), KeyStyle(symbol: "doc.text", hue: .purple, showsLabel: true))
        for entry in KeyStyles.table {
            XCTAssertEqual(KeyStyles.prompt(label: entry.keywords[0]).hue, .purple)
        }
    }

    func test_noKeywordIsInTwoRows() {
        var seen: [String: String] = [:]
        for entry in KeyStyles.table {
            for word in entry.keywords {
                XCTAssertNil(seen[word], "\(word) is in \(seen[word] ?? "") and \(entry.symbol)")
                seen[word] = entry.symbol
            }
        }
    }

    func test_shortKeywordsMatchOnlyWholeWords() {
        // "go" and "no" are too short to be prefixes: "good" and "notes" are
        // not run and refuse.
        XCTAssertNil(KeyStyles.match("good morning"))
        XCTAssertEqual(KeyStyles.match("notes")?.symbol, "doc.text")
    }

    // MARK: US-203 / US-206 what the pill draws

    func test_switchOffIsThePlainRow() {
        XCTAssertEqual(KeyPillSpec.builtin(.plan, auto: false, userColor: nil),
                       KeyPillSpec(content: .text("/plan"), fill: .neutral, isPrompt: false))
        XCTAssertEqual(KeyPillSpec.builtin(.esc, auto: false, userColor: nil),
                       KeyPillSpec(content: .icon("escape"), fill: .neutral, isPrompt: false))
        XCTAssertEqual(KeyPillSpec.prompt(label: "Ship it", auto: false, userColor: nil),
                       KeyPillSpec(content: .iconAndLabel(symbol: "doc.text", label: "Ship it"), fill: .prompt, isPrompt: true))
        XCTAssertEqual(KeyPillSpec.slashGroup(letter: "c", auto: false),
                       KeyPillSpec(content: .text("/c…"), fill: .neutral, isPrompt: false))
    }

    func test_switchOnDrawsTheStyle() {
        XCTAssertEqual(KeyPillSpec.builtin(.plan, auto: true, userColor: nil),
                       KeyPillSpec(content: .iconAndLabel(symbol: "list.bullet.clipboard", label: "/plan"),
                                   fill: .hue(.blue), isPrompt: false))
        XCTAssertEqual(KeyPillSpec.builtin(.yes, auto: true, userColor: nil),
                       KeyPillSpec(content: .icon("checkmark"), fill: .hue(.green), isPrompt: false))
        XCTAssertEqual(KeyPillSpec.prompt(label: "Ship it", auto: true, userColor: nil),
                       KeyPillSpec(content: .iconAndLabel(symbol: "paperplane.fill", label: "Ship it"), fill: .prompt, isPrompt: true))
        XCTAssertEqual(KeyPillSpec.slashGroup(letter: "c", auto: true).fill, .hue(.gray))
    }

    func test_aUserColorWinsEitherWay() {
        for auto in [true, false] {
            XCTAssertEqual(KeyPillSpec.builtin(.plan, auto: auto, userColor: "#ff0000").fill, .user("#FF0000"))
            XCTAssertEqual(KeyPillSpec.prompt(label: "x", auto: auto, userColor: "#00ff00").fill, .user("#00FF00"))
            XCTAssertEqual(KeyPillSpec.promptsPicker(userColor: "#0000ff").fill, .user("#0000FF"))
        }
        XCTAssertEqual(KeyPillSpec.builtin(.plan, auto: true, userColor: "not a color").fill, .hue(.blue))
    }

    func test_aUserSymbolWinsAndShowsAlone() {
        let button = CustomButton(id: UUID(), label: "Deploy", systemImage: "bolt.fill",
                                  payload: .rawText(text: "x", autoSubmit: true))
        let on = KeyPillSpec.custom(button, auto: true, userColor: nil, symbolExists: { _ in true })
        XCTAssertEqual(on, KeyPillSpec(content: .icon("bolt.fill"), fill: .hue(.green), isPrompt: false))
        let off = KeyPillSpec.custom(button, auto: false, userColor: nil, symbolExists: { _ in true })
        XCTAssertEqual(off, KeyPillSpec(content: .icon("bolt.fill"), fill: .neutral, isPrompt: false))
    }

    func test_aMisspelledSymbolNeverDrawsAnEmptyPill() {
        let button = CustomButton(id: UUID(), label: "Deploy", systemImage: "boltt",
                                  payload: .rawText(text: "x", autoSubmit: true))
        XCTAssertEqual(KeyPillSpec.custom(button, auto: true, userColor: nil, symbolExists: KeySymbol.exists).content,
                       .iconAndLabel(symbol: "paperplane.fill", label: "Deploy"))
        XCTAssertEqual(KeyPillSpec.custom(button, auto: false, userColor: nil, symbolExists: KeySymbol.exists).content,
                       .text("Deploy"))
    }

    // MARK: US-204 color sheet

    func test_resetNamesTheAutomaticColor() {
        let plan = KeyPillSpec.builtin(.plan, auto: true, userColor: nil)
        XCTAssertEqual(KeyPillSpec.colorResetLabel(automatic: plan, auto: true), "Use automatic color (blue)")
        let prompt = KeyPillSpec.prompt(label: "x", auto: true, userColor: nil)
        XCTAssertEqual(KeyPillSpec.colorResetLabel(automatic: prompt, auto: true), "Use automatic color (purple)")
        XCTAssertEqual(KeyPillSpec.colorResetLabel(automatic: plan, auto: false), "Reset to default")
        XCTAssertEqual(KeyPillSpec.colorResetLabel(automatic: nil, auto: true), "Reset to default")
    }

    func test_slotLookupCoversEveryKind() {
        let custom = CustomButton(id: UUID(), label: "Run tests", systemImage: nil,
                                  payload: .rawText(text: "x", autoSubmit: true))
        func spec(_ slot: QuickSlot) -> KeyPillSpec? {
            KeyPillSpec.slot(slot, auto: true, userColor: nil, customs: [custom.id: custom],
                             promptLabel: { _ in "Fix the bug" }, symbolExists: { _ in true })
        }
        XCTAssertEqual(spec(.builtin(.esc))?.fill, .hue(.orange))
        XCTAssertEqual(spec(.custom(custom.id))?.fill, .hue(.green))
        XCTAssertNil(spec(.custom(UUID())))
        XCTAssertEqual(spec(.prompt(promptID: "p1"))?.content, .iconAndLabel(symbol: "ladybug", label: "Fix the bug"))
        XCTAssertEqual(spec(.promptsPicker)?.fill, .prompt)
        XCTAssertNil(spec(.spacer(UUID())))
    }

    // MARK: helpers

    private func assertCustom(_ label: String, _ payload: CustomPayload, _ symbol: String, _ hue: KeyHue,
                              file: StaticString = #filePath, line: UInt = #line) {
        let style = KeyStyles.custom(label: label, payload: payload)
        XCTAssertEqual(style.symbol, symbol, label, file: file, line: line)
        XCTAssertEqual(style.hue, hue, label, file: file, line: line)
    }

    private func contrastAgainstWhite(_ hex: String) -> Double {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        func linear(_ byte: Int) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 0xFF) + 0.7152 * linear((value >> 8) & 0xFF)
            + 0.0722 * linear(value & 0xFF)
        return 1.05 / (luminance + 0.05)
    }
}
