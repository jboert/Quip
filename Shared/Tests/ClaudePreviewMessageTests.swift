import XCTest
@testable import Quip

final class ClaudePreviewMessageTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    func test_messagesRoundTripWithTheirTypes() throws {
        let item = ClaudePreviewItem(id: "A", name: "shot.png", terminalWindowId: "com.googlecode.iterm2-1",
                                     openedAt: 1793170000.2, hasDesktopWindow: true, thumb: "abc", isPDF: false)
        let list = ClaudePreviewsMessage(state: "on", items: [item])
        XCTAssertEqual(list.type, "claude_previews")
        try roundTrip(list)
        let request = ClaudePreviewRequestMessage(id: "A")
        XCTAssertEqual(request.type, "claude_preview_request")
        try roundTrip(request)
        let image = ClaudePreviewImageMessage(id: "A", format: "png", data: "xyz", pixelWidth: 1290, pixelHeight: 2796)
        XCTAssertEqual(image.type, "claude_preview_image")
        try roundTrip(image)
        let dismiss = ClaudePreviewDismissMessage(id: "A", closeOnDesktop: true)
        XCTAssertEqual(dismiss.type, "claude_preview_dismiss")
        try roundTrip(dismiss)
        let set = SetClaudePreviewsMessage(enabled: true)
        XCTAssertEqual(set.type, "set_claude_previews")
        try roundTrip(set)
    }

    func test_itemWithoutThumbOrTerminalDecodes() throws {
        let json = #"{"id":"A","name":"a.pdf","openedAt":1,"hasDesktopWindow":false,"isPDF":true}"#
        let item = try JSONDecoder().decode(ClaudePreviewItem.self, from: Data(json.utf8))
        XCTAssertNil(item.thumb)
        XCTAssertNil(item.terminalWindowId)
    }

    func test_imageErrorDecodesWithoutPageCount() throws {
        let json = #"{"type":"claude_preview_image","id":"A","format":"jpeg","data":"","pixelWidth":0,"pixelHeight":0,"error":"gone"}"#
        let msg = try JSONDecoder().decode(ClaudePreviewImageMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.error, "gone")
        XCTAssertNil(msg.pageCount)
    }
}
