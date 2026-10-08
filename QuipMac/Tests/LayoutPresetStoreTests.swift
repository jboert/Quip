import XCTest
@testable import Quip

/// Layout presets live in one `@AppStorage("savedPresets")` blob that the main
/// window writes and the Layouts pane reads, renames and deletes. These pin the
/// blob's shape and the edits, so a preset saved in one place is the preset
/// the other place shows.
final class LayoutPresetStoreTests: XCTestCase {

    private func customPreset() -> SavedLayoutPreset {
        SavedLayoutPreset(
            name: "Work",
            mode: .custom,
            customFrames: [
                "win-a": NormalizedRect(x: 0, y: 0, width: 0.6, height: 1),
                "win-b": NormalizedRect(x: 0.6, y: 0, width: 0.4, height: 0.5),
            ],
            windowOrder: ["win-a", "win-b"]
        )
    }

    func test_roundTrip_keepsNameModeFramesOrderAndId() throws {
        let original = customPreset()
        let decoded = try LayoutPresetStore.decode(LayoutPresetStore.encode([original]))

        XCTAssertEqual(decoded.count, 1)
        let preset = try XCTUnwrap(decoded.first)
        XCTAssertEqual(preset.id, original.id)
        XCTAssertEqual(preset.name, "Work")
        XCTAssertEqual(preset.mode, .custom)
        XCTAssertEqual(preset.windowOrder, ["win-a", "win-b"])
        let frames = try XCTUnwrap(preset.customFrames)
        XCTAssertEqual(Set(frames.keys), ["win-a", "win-b"])
        for (key, rect) in try XCTUnwrap(original.customFrames) {
            let got = try XCTUnwrap(frames[key])
            XCTAssertEqual(got.id, rect.id)
            XCTAssertEqual(got.x, rect.x)
            XCTAssertEqual(got.y, rect.y)
            XCTAssertEqual(got.width, rect.width)
            XCTAssertEqual(got.height, rect.height)
        }
    }

    func test_roundTrip_customModeKeepsNonNilFrames() throws {
        let decoded = try LayoutPresetStore.decode(LayoutPresetStore.encode([customPreset()]))
        XCTAssertNotNil(decoded.first?.customFrames, "custom-mode preset lost its frames")
        XCTAssertEqual(decoded.first?.customFrames?.count, 2)
    }

    func test_adding_appendsNewName() {
        let first = SavedLayoutPreset(name: "Work", mode: .columns)
        let second = SavedLayoutPreset(name: "Home", mode: .rows)
        let result = LayoutPresetStore.adding(second, to: [first])
        XCTAssertEqual(result.map(\.name), ["Work", "Home"])
        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    func test_adding_duplicateNameReplacesInPlaceAndKeepsId() {
        let work = SavedLayoutPreset(name: "Work", mode: .columns)
        let home = SavedLayoutPreset(name: "Home", mode: .rows)
        let resaved = SavedLayoutPreset(name: "  work ", mode: .grid, windowOrder: ["x"])

        let result = LayoutPresetStore.adding(resaved, to: [work, home])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, work.id, "replacement must keep the original id")
        XCTAssertEqual(result[0].mode, .grid)
        XCTAssertEqual(result[0].windowOrder, ["x"])
        XCTAssertEqual(result[1].id, home.id)
        XCTAssertEqual(result[1].mode, .rows)
    }

    func test_renaming_changesOnlyTheNamedPreset() {
        let work = SavedLayoutPreset(name: "Work", mode: .columns)
        let home = SavedLayoutPreset(name: "Home", mode: .rows)

        let result = LayoutPresetStore.renaming(work.id, to: "Office", in: [work, home])

        XCTAssertEqual(result.map(\.name), ["Office", "Home"])
        XCTAssertEqual(result.map(\.id), [work.id, home.id])
        XCTAssertEqual(result[0].mode, .columns)
    }

    func test_removing_dropsOnlyTheGivenId() {
        let work = SavedLayoutPreset(name: "Work", mode: .columns)
        let home = SavedLayoutPreset(name: "Home", mode: .rows)
        let gym = SavedLayoutPreset(name: "Gym", mode: .grid)

        let result = LayoutPresetStore.removing(home.id, from: [work, home, gym])

        XCTAssertEqual(result.map(\.id), [work.id, gym.id])
    }

    func test_decode_emptyDataIsNoPresets() throws {
        XCTAssertEqual(try LayoutPresetStore.decode(Data()).count, 0)
    }

    /// Deliberately broken fixture: valid JSON, wrong shape. Must throw so the
    /// Layouts pane can say the blob is unreadable rather than show "none".
    func test_decode_nonArrayBlobThrows() {
        let broken = Data(#"{"not":"an array"}"#.utf8)
        XCTAssertThrowsError(try LayoutPresetStore.decode(broken))
    }
}
